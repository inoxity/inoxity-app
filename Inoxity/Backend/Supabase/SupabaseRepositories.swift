import Foundation
import Supabase

enum SupabaseBackendErrorMapper {
    static func mapStudyBackend(_ error: Error) -> BackendError {
        let text = String(describing: error).lowercased()
        if text.contains("study_backend_inactive") { return .inactiveBackend }
        if text.contains("enrollment_ownership_denied") || text.contains("ownership_denied") { return .ownershipDenied }
        if text.contains("backend_identity_mismatch") { return .backendIdentityMismatch }
        if text.contains("unauthorized") || text.contains("authentication required") || text.contains("jwt") { return .unauthorized }
        return .unavailable
    }
    /// Matches the RPC's own `raise exception` messages (plus the per-row check constraints and
    /// casts in 005) — deliberately NOT a missing-table error, which is a whole-metric setup
    /// problem that stays retryable until the backend SQL is fixed.
    static func healthKitSampleRejection(_ error: Error) -> HealthKitUploadError? {
        let text = String(describing: error).lowercased()
        if text.contains("conflicting duplicate identity") || text.contains("conflicting_duplicate_identity") { return .conflictingDuplicate }
        let invalid = ["invalid quantity sample", "invalid category sample", "invalid sleep sample", "invalid workout sample",
                       "invalid correlation sample", "unsupported identifier", "invalid batch size",
                       "violates check constraint", "invalid input syntax"]
        return invalid.contains(where: text.contains) ? .invalidSample : nil
    }
}

enum SupabaseClientFactory {
    static func make(url: URL, key: String, storageNamespace: String) -> SupabaseClient {
        SupabaseClient(supabaseURL: url, supabaseKey: key, options: .init(auth: .init(
            storage: AuthClient.Configuration.defaultLocalStorage,
            storageKey: storageNamespace
        )))
    }
    static func make(control environment: BackendEnvironment) -> SupabaseClient {
        make(url: environment.supabaseURL, key: environment.supabaseAnonKey,
             storageNamespace: environment.authStorageNamespace)
    }
    static func make(study descriptor: StudyBackendDescriptor) -> SupabaseClient {
        make(url: descriptor.supabaseURL, key: descriptor.supabaseAnonKey,
             storageNamespace: descriptor.authStorageNamespace)
    }
}

private actor SupabaseAuthenticationCore {
    static let authTimeoutSeconds: Double = 12
    let client: SupabaseClient
    private var inFlight: Task<AuthenticatedParticipant, Error>?
    init(client: SupabaseClient) { self.client = client }
    func participant() async throws -> AuthenticatedParticipant {
        if let inFlight { return try await inFlight.value }
        let task = Task { [client] in
            do {
                let session = try await Self.withTimeout(seconds: Self.authTimeoutSeconds) { try await client.auth.session }
                return AuthenticatedParticipant(authUserID: session.user.id, isAnonymous: session.user.isAnonymous,
                                                createdAt: session.user.createdAt)
            } catch {
                do {
                    let session = try await Self.withTimeout(seconds: Self.authTimeoutSeconds) { try await client.auth.signInAnonymously() }
                    return AuthenticatedParticipant(authUserID: session.user.id, isAnonymous: true,
                                                    createdAt: session.user.createdAt)
                } catch { throw BackendError.unavailable }
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    // The Supabase SDK's session-refresh call has no built-in timeout and has a known internal
    // ordering bug that can leave it hanging indefinitely; racing it against a timeout keeps a
    // stuck refresh from permanently blocking this actor (previously required a force-quit).
    private static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BackendError.unavailable
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

actor SupabaseControlBackendAuthenticator: ControlBackendAuthenticating {
    private let core: SupabaseAuthenticationCore
    init(environment: BackendEnvironment) { core = SupabaseAuthenticationCore(client: SupabaseClientFactory.make(control: environment)) }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant { try await core.participant() }
}

actor SupabaseStudyBackendAuthenticator: StudyBackendAuthenticating {
    let backendID: UUID
    let storageNamespace: String
    private let core: SupabaseAuthenticationCore
    init(descriptor: StudyBackendDescriptor, client: SupabaseClient) {
        backendID = descriptor.backendID; storageNamespace = descriptor.authStorageNamespace
        core = SupabaseAuthenticationCore(client: client)
    }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant { try await core.participant() }
}

private struct BootstrapRPCRow: Decodable, Sendable {
    let controlStudyID, backendID: UUID
    let stableStudyID, studyCode: String
    let configurationSchemaVersion, configurationRevision, descriptorRevision: Int
    let configurationJSON: StudyConfiguration
    let backendURL: URL
    let backendAnonKey: String
    let backendEnvironment: BackendEnvironmentName
    let backendDiagnosticName: String?
    enum CodingKeys: String, CodingKey {
        case controlStudyID = "study_id", backendID = "backend_id", stableStudyID = "stable_study_id"
        case studyCode = "study_code", configurationSchemaVersion = "configuration_schema_version"
        case configurationRevision = "configuration_revision", configurationJSON = "configuration_json"
        case backendURL = "study_backend_url", backendAnonKey = "study_backend_anon_key"
        case backendEnvironment = "study_backend_environment", descriptorRevision = "descriptor_revision"
        case backendDiagnosticName = "backend_diagnostic_name"
    }
}

actor SupabaseControlStudyRepository: ControlBackendClientProviding {
    private let client: SupabaseClient
    private let authenticator: any ControlBackendAuthenticating
    private let environment: BackendEnvironmentName
    private let validator = StudyConfigurationValidator()
    private let now: @Sendable () -> Date
    init(environment: BackendEnvironment, authenticator: any ControlBackendAuthenticating,
         now: @escaping @Sendable () -> Date = { Date() }) {
        client = SupabaseClientFactory.make(control: environment); self.authenticator = authenticator
        self.environment = environment.name; self.now = now
    }
    func resolveStudyBootstrap(studyCode: String) async throws -> ControlStudyBootstrap {
        _ = try await authenticator.authenticatedParticipant()
        let code = StudyCodeNormalizer.normalize(studyCode)
        do {
            let rows: [BootstrapRPCRow] = try await client.rpc("resolve_study_bootstrap", params: ["requested_code": code]).execute().value
            guard let row = rows.first else { throw RemoteStudyError.notFound }
            try validator.validate(row.configurationJSON, expectedCode: code)
            guard row.stableStudyID == row.configurationJSON.identity.id,
                  row.studyCode == row.configurationJSON.identity.code,
                  row.configurationSchemaVersion == row.configurationJSON.schemaVersion,
                  row.configurationRevision > 0 else { throw RemoteStudyError.invalidConfiguration }
            let descriptor = try StudyBackendDescriptor(backendID: row.backendID, supabaseURL: row.backendURL,
                supabaseAnonKey: row.backendAnonKey, environment: row.backendEnvironment,
                revision: row.descriptorRevision, diagnosticName: row.backendDiagnosticName).validated(for: environment)
            return .init(controlStudyID: row.controlStudyID, configuration: row.configurationJSON,
                         stableStudyID: row.stableStudyID, normalizedStudyCode: row.studyCode,
                         configurationSchemaVersion: row.configurationSchemaVersion,
                         configurationRevision: row.configurationRevision, descriptor: descriptor, fetchedAt: now())
        } catch let error as RemoteStudyError { throw error }
        catch let error as BackendError { throw error }
        catch { throw Self.map(error) }
    }
    private static func map(_ error: Error) -> RemoteStudyError {
        let text = String(describing: error).lowercased()
        if text.contains("study_not_found") { return .notFound }
        if text.contains("study_inactive") { return .inactive }
        if text.contains("enrollment_not_open") { return .enrollmentNotOpen }
        if text.contains("enrollment_closed") { return .enrollmentClosed }
        if text.contains("study_backend_unavailable") { return .invalidConfiguration }
        if text.contains("permission") || text.contains("jwt") || text.contains("unauthorized") { return .unauthorized }
        return .unavailable
    }
}

private struct IdentityRow: Decodable, Sendable {
    let backendInstanceID: UUID; let stableStudyID, expectedStudyCode: String
    let supportedConfigurationSchemaVersion: Int; let isActive: Bool
    enum CodingKeys: String, CodingKey { case backendInstanceID = "backend_instance_id", stableStudyID = "stable_study_id", expectedStudyCode = "expected_study_code", supportedConfigurationSchemaVersion = "supported_configuration_schema_version", isActive = "is_active" }
}
private struct ParticipantRow: Decodable, Sendable { let participantID: UUID; let createdAt: Date; enum CodingKeys: String, CodingKey { case participantID = "participant_id", createdAt = "created_at" } }
private struct EnrollmentRow: Decodable, Sendable {
    let enrollmentID, participantID: UUID; let status: String; let enrolledAt: Date
    let configurationSchemaVersion, configurationRevision: Int
    enum CodingKeys: String, CodingKey { case enrollmentID = "enrollment_id", participantID = "participant_id", status, enrolledAt = "enrolled_at", configurationSchemaVersion = "enrolled_schema_version", configurationRevision = "enrolled_revision" }
}
private struct SleepScheduleRow: Decodable, Sendable {
    let participantID: UUID; let wakeTime, bedTime: String
    enum CodingKeys: String, CodingKey { case participantID = "participant_id", wakeTime = "wake_time", bedTime = "bed_time" }
}
private struct ParticipantIdentifierRow: Decodable, Sendable {
    let enrollmentID: UUID; let participantIdentifier: String
    enum CodingKeys: String, CodingKey { case enrollmentID = "enrollment_id", participantIdentifier = "participant_identifier" }
}
private struct ParticipantCharacteristicsRow: Decodable, Sendable {
    let participantID: UUID
    enum CodingKeys: String, CodingKey { case participantID = "participant_id" }
}
private struct WithdrawalRow: Decodable, Sendable {
    let requestID: UUID
    // Only non-empty for a 'deleteExistingData' choice that actually deleted media rows —
    // submit_withdrawal_request (009) returns the exact storage_paths it just removed from
    // media_uploads, so the client can delete the matching Storage objects too (Postgres has no
    // way to reach Supabase Storage directly from SQL).
    let deletedStoragePaths: [String]
    enum CodingKeys: String, CodingKey { case requestID = "request_id", deletedStoragePaths = "deleted_storage_paths" }
}
private struct SurveyEventAcknowledgmentRow: Decodable, Sendable {
    let acknowledgmentID: UUID; let receivedAt: Date; let idempotentExisting: Bool
    enum CodingKeys: String, CodingKey {
        case acknowledgmentID = "acknowledgment_id", receivedAt = "received_at", idempotentExisting = "idempotent_existing"
    }
}
private struct HealthKitAcknowledgmentRow: Decodable, Sendable {
    let clientSampleID: String; let acknowledgmentID: UUID; let receivedAt: Date; let idempotentExisting: Bool
    enum CodingKeys: String, CodingKey { case clientSampleID = "client_sample_id", acknowledgmentID = "acknowledgment_id", receivedAt = "received_at", idempotentExisting = "idempotent_existing" }
}
private struct MediaUploadRow: Decodable, Sendable {
    let id: UUID; let receivedAt: Date
    enum CodingKeys: String, CodingKey { case id, receivedAt = "received_at" }
}

private actor BoundSupabaseStudyRepository: StudyBackendClientProviding, StudyBackendAuthenticating, RemoteEnrollmentRepository, RemoteWithdrawalRepository, SurveyEventUploadRepository, HealthKitSampleUploadRepository, MediaUploadRepository {
    let descriptor: StudyBackendDescriptor
    nonisolated var backendID: UUID { descriptor.backendID }
    nonisolated var storageNamespace: String { descriptor.authStorageNamespace }
    private let client: SupabaseClient
    private let auth: SupabaseStudyBackendAuthenticator
    private let now: @Sendable () -> Date
    private var verified: ValidatedStudyBackendIdentity?
    init(descriptor: StudyBackendDescriptor, now: @escaping @Sendable () -> Date = { Date() }) {
        self.descriptor = descriptor; client = SupabaseClientFactory.make(study: descriptor)
        auth = SupabaseStudyBackendAuthenticator(descriptor: descriptor, client: client); self.now = now
    }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant { try await auth.authenticatedParticipant() }
    func validateIdentity(expectedStudyID: String, expectedCode: String, schemaVersion: Int) async throws -> ValidatedStudyBackendIdentity {
        _ = try await auth.authenticatedParticipant()
        do {
            let rows: [IdentityRow] = try await client.rpc("get_study_backend_identity").execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            let code = StudyCodeNormalizer.normalize(expectedCode)
            guard row.isActive else { throw BackendError.inactiveBackend }
            guard row.backendInstanceID == descriptor.backendID, row.stableStudyID == expectedStudyID,
                  row.expectedStudyCode == code,
                  row.supportedConfigurationSchemaVersion == schemaVersion else { throw BackendError.backendIdentityMismatch }
            let result = ValidatedStudyBackendIdentity(backendInstanceID: row.backendInstanceID,
                stableStudyID: row.stableStudyID, normalizedStudyCode: row.expectedStudyCode,
                supportedConfigurationSchemaVersion: row.supportedConfigurationSchemaVersion,
                isActive: row.isActive, validatedAt: now())
            verified = result; return result
        } catch let error as BackendError { throw error }
        catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    private func requireVerified() throws -> ValidatedStudyBackendIdentity {
        guard let verified, verified.backendInstanceID == descriptor.backendID else { throw BackendError.routingRequired }
        return verified
    }
    func ensureParticipant() async throws -> RemoteParticipant {
        _ = try requireVerified(); _ = try await auth.authenticatedParticipant()
        do {
            let rows: [ParticipantRow] = try await client.rpc("ensure_participant").execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            return .init(id: row.participantID, createdAt: row.createdAt)
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func register(_ value: EnrollmentRegistration) async throws -> RemoteEnrollment {
        let identity = try requireVerified(); guard identity.stableStudyID == value.stableStudyID else { throw BackendError.backendIdentityMismatch }
        struct Params: Encodable { let expected_backend_id, expected_stable_study_id, expected_study_code, participant_identifier, p_enrollment_attempt_id, installation_id: String; let configuration_schema_version, configuration_revision: Int }
        let p = Params(expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: value.stableStudyID,
            expected_study_code: identity.normalizedStudyCode, participant_identifier: value.participantIdentifier,
            p_enrollment_attempt_id: value.enrollmentAttemptID.uuidString, installation_id: value.installationID.uuidString,
            configuration_schema_version: value.configurationSchemaVersion, configuration_revision: value.configurationRevision)
        do {
            let rows: [EnrollmentRow] = try await client.rpc("register_study_enrollment", params: p).execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            guard row.status == "active" else { throw BackendError.withdrawnEnrollment }
            return .init(enrollmentID: row.enrollmentID, participantID: row.participantID,
                         remoteStudyID: descriptor.backendID, status: row.status, enrolledAt: row.enrolledAt,
                         configurationSchemaVersion: row.configurationSchemaVersion,
                         configurationRevision: row.configurationRevision)
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func updateSleepSchedule(wakeMinutes: Int, bedMinutes: Int) async throws {
        let identity = try requireVerified()
        struct Params: Encodable { let expected_backend_id, expected_stable_study_id, p_wake_time, p_bed_time: String }
        func format(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        let p = Params(expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: identity.stableStudyID,
            p_wake_time: format(wakeMinutes), p_bed_time: format(bedMinutes))
        do {
            let rows: [SleepScheduleRow] = try await client.rpc("update_sleep_schedule", params: p).execute().value
            guard rows.first != nil else { throw BackendError.invalidResponse }
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func updateParticipantIdentifier(_ value: String) async throws {
        let identity = try requireVerified()
        // p_-prefixed to match update_participant_identifier's renamed SQL parameter (011) — it
        // also names a column on study_enrollments, same collision update_sleep_schedule's
        // p_wake_time/p_bed_time above and submit_withdrawal_request's p_-prefixed params guard against.
        struct Params: Encodable { let expected_backend_id, expected_stable_study_id, p_participant_identifier: String }
        let p = Params(expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: identity.stableStudyID,
            p_participant_identifier: value)
        do {
            let rows: [ParticipantIdentifierRow] = try await client.rpc("update_participant_identifier", params: p).execute().value
            guard rows.first != nil else { throw BackendError.invalidResponse }
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func updateParticipantCharacteristics(_ value: HealthKitCharacteristics) async throws {
        let identity = try requireVerified()
        // p_-prefixed, same defensive pattern as update_sleep_schedule/update_participant_identifier
        // above — several of these names could otherwise collide with a column on the RPC's own
        // target table inside plpgsql.
        struct Params: Encodable {
            let expected_backend_id, expected_stable_study_id: String
            let p_biological_sex, p_blood_type, p_fitzpatrick_skin_type: String?
            let p_date_of_birth: String?
            let p_uses_wheelchair: Bool?
        }
        let p = Params(expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: identity.stableStudyID,
            p_biological_sex: value.biologicalSex, p_blood_type: value.bloodType, p_fitzpatrick_skin_type: value.fitzpatrickSkinType,
            p_date_of_birth: value.dateOfBirth.map(Self.dateOnlyString), p_uses_wheelchair: value.usesWheelchair)
        do {
            let rows: [ParticipantCharacteristicsRow] = try await client.rpc("submit_participant_characteristics", params: p).execute().value
            guard rows.first != nil else { throw BackendError.invalidResponse }
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    // HealthKitService.readCharacteristics() builds dateOfBirth via
    // Calendar(identifier: .gregorian).date(from: components) — the device's current-timezone
    // Gregorian calendar, not UTC — so this must extract year/month/day the same way rather than
    // through a UTC-anchored formatter, which could shift a birthdate near midnight by a day.
    private static func dateOnlyString(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    func submit(_ event: PendingWithdrawalEvent, remoteEnrollmentID: UUID?) async throws -> UUID {
        let identity = try requireVerified()
        guard event.studyBackendID == descriptor.backendID, event.studyID == identity.stableStudyID,
              event.routingStatus == .verified else { throw BackendError.routingRequired }
        // p_-prefixed to match submit_withdrawal_request's renamed SQL parameters (009) — each
        // one also names a column on withdrawal_requests, which made plpgsql treat a bare
        // occurrence as ambiguous (42702) once more than one statement in that function had the
        // table in scope. Same defensive pattern as update_sleep_schedule's p_wake_time/p_bed_time above.
        struct Params: Encodable { let p_client_event_id, expected_backend_id, expected_stable_study_id, p_withdrawal_choice, p_requested_at: String; let p_enrollment_id: String? }
        let p = Params(p_client_event_id: event.id, expected_backend_id: descriptor.backendID.uuidString,
            expected_stable_study_id: event.studyID, p_withdrawal_choice: event.choice.rawValue,
            p_requested_at: ISO8601DateFormatter().string(from: event.requestedAt),
            p_enrollment_id: (remoteEnrollmentID ?? event.remoteEnrollmentID)?.uuidString)
        do {
            let rows: [WithdrawalRow] = try await client.rpc("submit_withdrawal_request", params: p).execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            // Best-effort: the database deletion above is already the authoritative "did
            // withdrawal succeed" outcome and has already happened by this point — a failure
            // removing the Storage objects themselves (network hiccup, already-gone file, etc.)
            // shouldn't fail the whole withdrawal or block retirement of this pending event.
            if !row.deletedStoragePaths.isEmpty {
                _ = try? await client.storage.from("user-uploads").remove(paths: row.deletedStoragePaths)
            }
            return row.requestID
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func upload(_ event: SurveyEventUpload) async throws -> SurveyEventAcknowledgment {
        let identity = try requireVerified()
        guard event.studyBackendID == descriptor.backendID, event.stableStudyID == identity.stableStudyID,
              event.remoteEnrollmentID != nil else { throw BackendError.routingRequired }
        struct Params: Encodable {
            let client_event_id, expected_backend_id, expected_stable_study_id, enrollment_id: String
            let survey_id, occurrence_id, event_type, event_timestamp, scheduled_for: String
            let opened_at, completed_at: String?
            let configuration_schema_version, configuration_revision: Int
            let event_source, app_version: String
            // p_-prefixed to match submit_survey_event's renamed SQL parameter — same defensive
            // pattern as update_sleep_schedule/update_participant_identifier (see
            // SupabaseRepositories.swift's other RPC calls): avoids a bare-reference collision
            // with survey_events.event_time_zone inside the RPC's own plpgsql body.
            let p_event_time_zone: String
        }
        let formatter = ISO8601DateFormatter()
        let p = Params(client_event_id: event.clientEventID, expected_backend_id: descriptor.backendID.uuidString,
            expected_stable_study_id: event.stableStudyID, enrollment_id: event.remoteEnrollmentID!.uuidString,
            survey_id: event.surveyID, occurrence_id: event.occurrenceID, event_type: event.type.rawValue,
            event_timestamp: formatter.string(from: event.eventTimestamp), scheduled_for: formatter.string(from: event.scheduledFor),
            opened_at: event.openedAt.map(formatter.string), completed_at: event.completedAt.map(formatter.string),
            configuration_schema_version: event.configurationSchemaVersion,
            configuration_revision: event.configurationRevision, event_source: event.source.rawValue,
            app_version: event.appVersion, p_event_time_zone: event.eventTimeZoneIdentifier)
        do {
            let rows: [SurveyEventAcknowledgmentRow] = try await client.rpc("submit_survey_event", params: p).execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            return .init(acknowledgmentID: row.acknowledgmentID, receivedAt: row.receivedAt,
                         idempotentExisting: row.idempotentExisting)
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
    func submitHealthKitSamples(_ samples: [HealthKitSampleUpload]) async throws -> HealthKitBatchAcknowledgment {
        guard !samples.isEmpty, samples.count <= HealthKitUploadPolicy.phase3D.maximumUploadBatchSize else { throw HealthKitUploadError.invalidBatchSize }
        let identity = try requireVerified()
        guard samples.allSatisfy({ $0.studyBackendID == descriptor.backendID && $0.stableStudyID == identity.stableStudyID }) else { throw HealthKitUploadError.routingRequired }
        struct Sample: Encodable {
            let client_sample_id, sample_uuid, health_type_identifier, sample_kind, sample_start, sample_end: String
            // Not a plpgsql-visible bare identifier (read via `v_sample->>'sample_time_zone'` from
            // inside the batched jsonb payload) so this needs no p_-prefix — unlike
            // submit_survey_event's scalar param, there's no bare-reference ambiguity risk here.
            let sample_time_zone: String
            let numeric_value: Double?; let canonical_unit: String?; let category_value: Int?
            let workout_activity_type: UInt?; let workout_duration_seconds: Double?
            /// Second value for a correlation sample (blood pressure's diastolic reading,
            /// alongside `numeric_value` holding systolic) — nil for every other sample kind.
            let secondary_numeric_value: Double?
            let configuration_schema_version, configuration_revision: Int
        }
        struct Params: Encodable { let expected_backend_id, expected_stable_study_id, enrollment_id: String; let samples: [Sample] }
        guard let enrollment = samples.first?.remoteEnrollmentID, samples.allSatisfy({ $0.remoteEnrollmentID == enrollment }) else { throw HealthKitUploadError.routingRequired }
        let formatter = ISO8601DateFormatter()
        let values = samples.map { Sample(client_sample_id: $0.clientSampleID, sample_uuid: $0.sampleUUID.uuidString.lowercased(),
            health_type_identifier: $0.healthKitIdentifier, sample_kind: $0.sampleKind.rawValue,
            sample_start: formatter.string(from: $0.sampleStart), sample_end: formatter.string(from: $0.sampleEnd),
            sample_time_zone: $0.sampleTimeZoneIdentifier,
            numeric_value: $0.quantityValue, canonical_unit: $0.quantityUnit, category_value: $0.categoryValue,
            workout_activity_type: $0.workoutActivityType, workout_duration_seconds: $0.workoutDurationSeconds,
            secondary_numeric_value: $0.secondaryQuantityValue,
            configuration_schema_version: $0.configurationSchemaVersion, configuration_revision: $0.configurationRevision) }
        do {
            let rows: [HealthKitAcknowledgmentRow] = try await client.rpc("submit_healthkit_samples", params: Params(
                expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: identity.stableStudyID,
                enrollment_id: enrollment.uuidString, samples: values)).execute().value
            return .init(acknowledgments: rows.map { .init(clientSampleID: $0.clientSampleID, acknowledgmentID: $0.acknowledgmentID, receivedAt: $0.receivedAt, idempotentExisting: $0.idempotentExisting) })
        } catch let error as HealthKitUploadError { throw error }
        catch let error as BackendError { throw error }
        catch {
            // Sample-level rejections from submit_healthkit_samples (006) must not look retryable:
            // retrying the identical batch fails identically forever and stalls every metric's
            // cursor behind it. Surfacing them as non-retryable lets the coordinator bisect the
            // batch and set aside only the offending sample(s).
            if let rejection = SupabaseBackendErrorMapper.healthKitSampleRejection(error) { throw rejection }
            let mapped = SupabaseBackendErrorMapper.mapStudyBackend(error)
            if mapped == .inactiveBackend { throw mapped }
            throw HealthKitUploadError.unavailable
        }
    }
    // Two steps, matching the pre-dashboard app's pattern: the file goes straight to
    // Storage (governed by that bucket's own RLS, not this RPC), then this records
    // just the metadata row. storage_path is namespaced by the participant's own
    // auth.uid() so the bucket's RLS policies (007_media_uploads.sql) can scope
    // reads/writes to "your own files only" the same way it scopes every other table.
    func upload(_ media: MediaUploadDescriptor, data: Data) async throws -> MediaUploadAcknowledgment {
        let identity = try requireVerified()
        guard media.studyBackendID == descriptor.backendID, media.stableStudyID == identity.stableStudyID else { throw MediaUploadError.routingRequired }
        let participant: AuthenticatedParticipant
        do { participant = try await auth.authenticatedParticipant() }
        catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
        let storagePath = "\(participant.authUserID.uuidString.lowercased())/\(media.categoryID)/\(media.draftID).\(media.originalFilenameExtension)"
        do {
            _ = try await client.storage.from("user-uploads").upload(storagePath, data: data, options: FileOptions(contentType: media.mimeType))
        } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
        struct Params: Encodable {
            let expected_backend_id, expected_stable_study_id, enrollment_id, storage_path, mime_type, category_id: String
            let bytes: Int64; let duration_seconds: Double?; let represented_date: String?
            let configuration_schema_version, configuration_revision: Int
        }
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.calendar = Calendar(identifier: .gregorian); dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0); dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        let p = Params(expected_backend_id: descriptor.backendID.uuidString, expected_stable_study_id: identity.stableStudyID,
            enrollment_id: media.remoteEnrollmentID.uuidString, storage_path: storagePath, mime_type: media.mimeType,
            category_id: media.categoryID, bytes: media.byteCount, duration_seconds: media.durationSeconds,
            represented_date: media.representedDate.map(dateOnlyFormatter.string), configuration_schema_version: media.configurationSchemaVersion,
            configuration_revision: media.configurationRevision)
        do {
            let rows: [MediaUploadRow] = try await client.rpc("submit_media_upload", params: p).execute().value
            guard let row = rows.first else { throw BackendError.invalidResponse }
            return .init(id: row.id, receivedAt: row.receivedAt)
        } catch let error as BackendError { throw error } catch { throw SupabaseBackendErrorMapper.mapStudyBackend(error) }
    }
}

actor SupabaseStudyBackendClientFactory: StudyBackendClientFactory {
    private var clients: [String: BoundSupabaseStudyRepository] = [:]
    func context(for bootstrap: ControlStudyBootstrap) async throws -> StudyBackendContext {
        let key = "\(bootstrap.descriptor.backendID.uuidString)-\(bootstrap.descriptor.revision)-\(bootstrap.descriptor.supabaseURL.absoluteString)"
        let repository = clients[key] ?? BoundSupabaseStudyRepository(descriptor: bootstrap.descriptor)
        clients[key] = repository
        let identity = try await repository.validateIdentity(expectedStudyID: bootstrap.stableStudyID,
            expectedCode: bootstrap.normalizedStudyCode, schemaVersion: bootstrap.configurationSchemaVersion)
        return .init(descriptor: bootstrap.descriptor, identity: identity, authenticator: repository,
                     enrollments: repository, withdrawals: repository, surveyEvents: repository, healthKitSamples: repository,
                     media: repository)
    }
    func context(for resolved: ResolvedStudy) async throws -> StudyBackendContext {
        let bootstrap = ControlStudyBootstrap(controlStudyID: UUID(), configuration: resolved.configuration,
            stableStudyID: resolved.stableStudyID, normalizedStudyCode: resolved.normalizedStudyCode,
            configurationSchemaVersion: resolved.configurationSchemaVersion,
            configurationRevision: resolved.configurationRevision, descriptor: resolved.descriptor, fetchedAt: resolved.fetchedAt)
        return try await context(for: bootstrap)
    }
}
