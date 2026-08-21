import XCTest
@testable import Inoxity

final class BackendEnvironmentTests: XCTestCase {
    func testExplicitControlEnvironmentAndNamespaces() throws {
        let value = try InfoPlistBackendEnvironmentLoader(values: [
            "INOXITY_ENVIRONMENT":"Development",
            "INOXITY_CONTROL_SUPABASE_URL":"https://control.supabase.co",
            "INOXITY_CONTROL_SUPABASE_ANON_KEY":"public-control-test-key-12345"
        ]).load()
        XCTAssertEqual(value.name, .development)
        XCTAssertEqual(value.authStorageNamespace, "inoxity.control.development")
    }
    func testProductionDoesNotAcceptLegacyKeys() {
        XCTAssertThrowsError(try InfoPlistBackendEnvironmentLoader(values: [
            "INOXITY_ENVIRONMENT":"Production", "SUPABASE_URL":"https://legacy.supabase.co",
            "SUPABASE_ANON_KEY":"public-legacy-test-key-12345"
        ]).load())
    }
    func testMalformedValuesFail() {
        XCTAssertThrowsError(try BackendEnvironment(name: .development,
            supabaseURL: XCTUnwrap(URL(string: "http://bad")), supabaseAnonKey: "key"))
    }
}

final class MultiBackendDomainTests: XCTestCase {
    func testDescriptorNamespacesRemainIsolated() throws {
        let sleep = try descriptor(id: UUID(), environment: .development)
        let activity = try descriptor(id: UUID(), environment: .development)
        XCTAssertNotEqual(sleep.authStorageNamespace, activity.authStorageNamespace)
        XCTAssertNotEqual(sleep.authStorageNamespace, "inoxity.control.development")
    }
    func testMalformedAndCrossEnvironmentDescriptorsFail() throws {
        let value = StudyBackendDescriptor(backendID: UUID(), supabaseURL: try XCTUnwrap(URL(string: "http://bad")),
            supabaseAnonKey: "public-study-key-123456789", environment: .development, revision: 1, diagnosticName: nil)
        XCTAssertThrowsError(try value.validated(for: .development))
        XCTAssertThrowsError(try descriptor(id: UUID(), environment: .development).validated(for: .production))
    }
    private func descriptor(id: UUID, environment: BackendEnvironmentName) throws -> StudyBackendDescriptor {
        try StudyBackendDescriptor(backendID: id, supabaseURL: XCTUnwrap(URL(string: "https://study.supabase.co")),
            supabaseAnonKey: "public-study-key-123456789", environment: environment,
            revision: 1, diagnosticName: nil).validated(for: environment)
    }
}

final class BackendHardeningTests: XCTestCase {
    func testInactiveAndOwnershipRPCErrorsMapToParticipantSafeErrors() {
        XCTAssertEqual(SupabaseBackendErrorMapper.mapStudyBackend(RawRPCError("study_backend_inactive")), .inactiveBackend)
        XCTAssertEqual(SupabaseBackendErrorMapper.mapStudyBackend(RawRPCError("enrollment_ownership_denied")), .ownershipDenied)
        XCTAssertEqual(BackendError.inactiveBackend.localizedDescription,
                       "This study is not currently accepting new data. No participant data was sent.")
    }

    func testParticipantErrorsDoNotExposeRawRPCOrSQLDetails() {
        for error in [BackendError.inactiveBackend, .ownershipDenied, .backendIdentityMismatch, .unavailable] {
            let text = error.localizedDescription.lowercased()
            XCTAssertFalse(text.contains("sqlstate")); XCTAssertFalse(text.contains("study_backend_metadata"))
            XCTAssertFalse(text.contains("auth.uid")); XCTAssertFalse(text.contains("enrollment_ownership_denied"))
        }
    }

    func testWithdrawalAndActiveBackendSQLContractsArePresent() throws {
        let migration = try repositoryText("supabase/study_backend_template/migrations/002_study_data_rls_and_rpcs.sql")
        XCTAssertTrue(migration.contains("e.id=enrollment_id::uuid and e.participant_id=p.id"))
        XCTAssertTrue(migration.contains("conflicting_idempotency_key"))
        XCTAssertTrue(migration.contains("study_backend_inactive"))
        let verification = try repositoryText("supabase/study_backend_template/tests/study_rls_verification.sql")
        for scenario in ["foreign enrollment withdrawal accepted", "missing enrollment withdrawal accepted",
                         "wrong study withdrawal accepted", "withdrawal retry not idempotent",
                         "conflicting withdrawal retry accepted", "inactive withdrawal accepted"] {
            XCTAssertTrue(verification.contains(scenario), "Missing SQL verification scenario: \(scenario)")
        }
    }

    func testHealthKitAndMediaDevelopmentWordingIsAccurate() throws {
        for name in ["SleepStudy", "ActivityStudy"] {
            let value = try fixture(name)
            XCTAssertTrue(value.healthKit.rationale.contains("verified Study Backend"))
            XCTAssertTrue(value.faqs.contains { $0.answer.contains("does not write to Apple Health") })
            XCTAssertTrue(value.faqs.contains { $0.answer.contains("deleted Apple Health samples are not yet mirrored remotely") })
            XCTAssertTrue(value.media.privacyText.localizedCaseInsensitiveContains("uploaded directly"))
        }
    }

    private func repositoryText(_ relativePath: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(contentsOf: tests.deletingLastPathComponent().appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private struct RawRPCError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class StudyBootstrapCacheTests: XCTestCase {
    func testAtomicRoundTripExactRouteAndEnvironmentIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try await resolvedStudy()
        let cache = FileStudyBootstrapCache(root: root)
        try await cache.save(value)
        let restored = try await cache.bootstrap(cacheKey: value.bootstrapCacheKey, environment: .development,
                                                  studyID: value.stableStudyID, backendID: value.descriptor.backendID)
        XCTAssertEqual(restored?.descriptor, value.descriptor)
        let production = try await cache.bootstrap(cacheKey: value.bootstrapCacheKey, environment: .production,
                                                   studyID: value.stableStudyID, backendID: value.descriptor.backendID)
        XCTAssertNil(production)
        await XCTAssertThrowsErrorAsync {
            _ = try await cache.bootstrap(cacheKey: value.bootstrapCacheKey, environment: .development,
                                          studyID: value.stableStudyID, backendID: UUID())
        }
    }
    func testInvalidRefreshDoesNotOverwriteValidCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await resolvedStudy(), cache = FileStudyBootstrapCache(root: root)
        try await cache.save(valid)
        let badIdentity = ValidatedStudyBackendIdentity(backendInstanceID: UUID(), stableStudyID: valid.stableStudyID,
            normalizedStudyCode: valid.normalizedStudyCode, supportedConfigurationSchemaVersion: 5,
            isActive: true, validatedAt: Date())
        let invalid = ResolvedStudy(configuration: valid.configuration, stableStudyID: valid.stableStudyID,
            normalizedStudyCode: valid.normalizedStudyCode, configurationSchemaVersion: 5,
            configurationRevision: 1, source: .remote, descriptor: valid.descriptor,
            validatedIdentity: badIdentity, controlEnvironment: .development, fetchedAt: Date(),
            bootstrapCacheKey: valid.bootstrapCacheKey)
        await XCTAssertThrowsErrorAsync { try await cache.save(invalid) }
        let preserved = try await cache.bootstrap(cacheKey: valid.bootstrapCacheKey, environment: .development,
            studyID: valid.stableStudyID, backendID: valid.descriptor.backendID)
        XCTAssertNotNil(preserved)
    }
}

final class RemoteFirstResolutionTests: XCTestCase {
    func testIdentityVerifiedRemoteResultIsCached() async throws {
        let bootstrap = try await controlBootstrap(), cache = MemoryBootstrapCache()
        let provider = RemoteFirstStudyConfigurationProvider(remote: ControlRemote(result: .success(bootstrap)),
            cache: cache, studyClients: VerifyingFactory(), environment: try environment(.development))
        let value = try await provider.resolvedStudy(for: " sleep01 ")
        XCTAssertEqual(value.source, .remote); XCTAssertEqual(value.descriptor.backendID, bootstrap.descriptor.backendID)
        let savedCount = await cache.savedCount; XCTAssertEqual(savedCount, 1)
    }
    func testExplicitRejectionNeverFallsBack() async throws {
        for expected in [RemoteStudyError.inactive, .notFound, .enrollmentClosed] {
            let provider = RemoteFirstStudyConfigurationProvider(remote: ControlRemote(result: .failure(expected)),
                cache: MemoryBootstrapCache(cached: try await resolvedStudy()), studyClients: VerifyingFactory(),
                environment: try environment(.development))
            do { _ = try await provider.resolvedStudy(for: "SLEEP01"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? RemoteStudyError, expected) }
        }
    }
    func testUnavailableRestoresPreviouslyVerifiedCache() async throws {
        let cached = try await resolvedStudy()
        let provider = RemoteFirstStudyConfigurationProvider(remote: ControlRemote(result: .failure(.unavailable)),
            cache: MemoryBootstrapCache(cached: cached), studyClients: VerifyingFactory(), environment: try environment(.development))
        let value = try await provider.resolvedStudy(for: "SLEEP01"); XCTAssertEqual(value.source, .cache)
    }
    func testProductionUnavailableDoesNotCreateEnrollmentFromCache() async throws {
        let cached = try await resolvedStudy()
        let productionDescriptor = StudyBackendDescriptor(backendID: cached.descriptor.backendID,
            supabaseURL: cached.descriptor.supabaseURL, supabaseAnonKey: cached.descriptor.supabaseAnonKey,
            environment: .production, revision: 1, diagnosticName: nil)
        let productionCached = ResolvedStudy(configuration: cached.configuration, stableStudyID: cached.stableStudyID,
            normalizedStudyCode: cached.normalizedStudyCode, configurationSchemaVersion: 5,
            configurationRevision: 1, source: .cache, descriptor: productionDescriptor,
            validatedIdentity: cached.validatedIdentity, controlEnvironment: .production,
            fetchedAt: cached.fetchedAt, bootstrapCacheKey: cached.bootstrapCacheKey)
        let provider = RemoteFirstStudyConfigurationProvider(remote: ControlRemote(result: .failure(.unavailable)),
            cache: MemoryBootstrapCache(cached: productionCached), studyClients: VerifyingFactory(),
            environment: try environment(.production))
        do { _ = try await provider.resolvedStudy(for: "SLEEP01"); XCTFail("Expected authoritative route requirement") }
        catch { XCTAssertEqual(error as? RemoteStudyError, .unavailable) }
    }
}

final class WrongBackendProtectionTests: XCTestCase {
    func testSleepCannotUseActivityBackendAndCacheRemainsUntouched() async throws {
        let sleep = try await controlBootstrap(), cache = MemoryBootstrapCache()
        let factory = RejectingIdentityFactory()
        let provider = RemoteFirstStudyConfigurationProvider(remote: ControlRemote(result: .success(sleep)),
            cache: cache, studyClients: factory, environment: try environment(.development))
        do { _ = try await provider.resolvedStudy(for: "SLEEP01"); XCTFail("Expected identity mismatch") }
        catch { XCTAssertEqual(error as? BackendError, .backendIdentityMismatch) }
        let cacheWrites = await cache.count(), participantWrites = await factory.participantWrites
        XCTAssertEqual(cacheWrites, 0); XCTAssertEqual(participantWrites, 0)
    }

    func testWithdrawalWithoutTrustworthyRouteCannotBeRouted() async throws {
        let cache = MemoryBootstrapCache(cached: try await resolvedStudy())
        let router = CachedStudyBackendRouter(cache: cache, factory: VerifyingFactory(), environment: .development)
        let event = PendingWithdrawalEvent(id: UUID().uuidString, studyID: "sleep-cognition-v2",
            choice: .keepExistingData, requestedAt: Date())
        do { _ = try await router.context(for: event); XCTFail("Expected routing required") }
        catch { XCTAssertEqual(error as? BackendError, .routingRequired) }
    }
}

@MainActor final class Phase3BPersistenceTests: XCTestCase {
    // Named "SevenMigratesToEight" for the routing-status behavior this originally pinned down
    // (pre-dating persistenceVersion 9's start-date/characteristics fields) — the assertion below
    // checks against currentPersistenceVersion rather than a hardcoded 8 so a future version bump
    // doesn't silently go stale here the way it did when 8 became 9 without this test being
    // updated (see UserDefaultsParticipantStateStore's now-fixed 1...7 migration range).
    func testVersionSevenMigratesToEightAsLegacyUnrouted() throws {
        let suite = "Phase3B.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let old = ParticipantState(persistenceVersion: 7, studyID: "sleep-cognition-v2",
                                   enrollmentSyncStatus: .registered, remoteEnrollmentID: UUID())
        defaults.set(try encoder.encode(old), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + old.studyID)
        let migrated = try XCTUnwrap(UserDefaultsParticipantStateStore(defaults: defaults).loadState(for: old.studyID))
        XCTAssertEqual(migrated.persistenceVersion, ParticipantState.currentPersistenceVersion); XCTAssertEqual(migrated.backendRoutingStatus, .legacyUnrouted)
        XCTAssertNil(migrated.studyBackendID); XCTAssertNotNil(migrated.remoteEnrollmentID)
    }
    func testVersionEightRoundTripPreservesRoute() throws {
        let suite = "Phase3B.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backendID = UUID(), store = UserDefaultsParticipantStateStore(defaults: defaults)
        let state = ParticipantState(studyID: "sleep-cognition-v2", studyBackendID: backendID,
            studyBackendDescriptorCacheKey: "c1-d1.bootstrap", studyBackendDescriptorRevision: 1,
            backendRoutingStatus: .registered, studyAuthenticationNamespace: "inoxity.study.\(backendID).development")
        try store.saveState(state)
        XCTAssertEqual(try store.loadState(for: state.studyID)?.studyBackendID, backendID)
    }
}

@MainActor final class WithdrawalEventV3Tests: XCTestCase {
    func testVersionTwoMigratesAndPreservesIDAsRoutingRequired() throws {
        let suite = "WithdrawalV3.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = PendingWithdrawalEvent(id: UUID().uuidString.lowercased(), studyID: "sleep-cognition-v2",
            choice: .keepExistingData, requestedAt: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(WithdrawalEventEnvelope(persistenceVersion: 2,
            eventsByStudyID: [event.studyID:[event]])), forKey: UserDefaultsWithdrawalEventStore.key)
        let migrated = try XCTUnwrap(UserDefaultsWithdrawalEventStore(defaults: defaults).events(for: event.studyID).first)
        XCTAssertEqual(migrated.id, event.id); XCTAssertEqual(migrated.routingStatus, .routingRequired)
    }
    func testRoutedEventRoundTripRetainsBackendAndEnrollment() throws {
        let suite = "WithdrawalV3.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = UUID(), enrollment = UUID(), store = UserDefaultsWithdrawalEventStore(defaults: defaults)
        let event = PendingWithdrawalEvent(id: UUID().uuidString, studyID: "sleep-cognition-v2",
            choice: .deleteExistingData, requestedAt: Date(), studyBackendID: backend,
            descriptorCacheKey: "c1-d1.bootstrap", remoteEnrollmentID: enrollment, routingStatus: .verified)
        try store.save(event); let loaded = try XCTUnwrap(store.events(for: event.studyID).first)
        XCTAssertEqual(loaded.studyBackendID, backend); XCTAssertEqual(loaded.remoteEnrollmentID, enrollment)
    }
}

@MainActor final class InstallationIDStoreTests: XCTestCase {
    func testGenerationRestorationMalformedAndReinstall() async throws {
        let secure = MemorySecureStore(), marker = MemoryMarker(), firstStore = KeychainInstallationIDStore(secureStore: secure, marker: marker)
        let first = try await firstStore.installationID(); let same = try await firstStore.installationID(); XCTAssertEqual(same, first)
        let restored = try await KeychainInstallationIDStore(secureStore: secure, marker: marker).installationID(); XCTAssertEqual(restored, first)
        await secure.set("malformed"); let replacement = try await KeychainInstallationIDStore(secureStore: secure, marker: marker).installationID()
        XCTAssertNotEqual(replacement, first); marker.exists = false
        let reinstalled = try await KeychainInstallationIDStore(secureStore: secure, marker: marker).installationID(); XCTAssertNotEqual(reinstalled, replacement)
    }
}

private actor ControlRemote: RemoteStudyRepository {
    let result: Result<ControlStudyBootstrap, RemoteStudyError>
    init(result: Result<ControlStudyBootstrap, RemoteStudyError>) { self.result = result }
    func resolveStudyBootstrap(studyCode: String) async throws -> ControlStudyBootstrap { try result.get() }
}
private actor MemoryBootstrapCache: StudyBootstrapCaching {
    var cached: ResolvedStudy?; var savedCount = 0
    init(cached: ResolvedStudy? = nil) { self.cached = cached }
    func save(_ value: ResolvedStudy) { cached = value; savedCount += 1 }
    func bootstrap(cacheKey: String, environment: BackendEnvironmentName, studyID: String, backendID: UUID) -> ResolvedStudy? {
        guard cached?.bootstrapCacheKey == cacheKey, cached?.controlEnvironment == environment,
              cached?.stableStudyID == studyID, cached?.descriptor.backendID == backendID else { return nil }; return cached
    }
    func latest(code: String, environment: BackendEnvironmentName) -> ResolvedStudy? {
        guard cached?.normalizedStudyCode == StudyCodeNormalizer.normalize(code), cached?.controlEnvironment == environment else { return nil }
        guard let value = cached else { return nil }
        return ResolvedStudy(configuration: value.configuration, stableStudyID: value.stableStudyID,
            normalizedStudyCode: value.normalizedStudyCode, configurationSchemaVersion: value.configurationSchemaVersion,
            configurationRevision: value.configurationRevision, source: .cache, descriptor: value.descriptor,
            validatedIdentity: value.validatedIdentity, controlEnvironment: value.controlEnvironment,
            fetchedAt: value.fetchedAt, bootstrapCacheKey: value.bootstrapCacheKey)
    }
    func count() -> Int { savedCount }
}
private actor RejectingIdentityFactory: StudyBackendClientFactory {
    private(set) var participantWrites = 0
    func context(for bootstrap: ControlStudyBootstrap) async throws -> StudyBackendContext { throw BackendError.backendIdentityMismatch }
    func context(for resolved: ResolvedStudy) async throws -> StudyBackendContext { throw BackendError.backendIdentityMismatch }
}
private actor VerifyingFactory: StudyBackendClientFactory {
    func context(for bootstrap: ControlStudyBootstrap) async throws -> StudyBackendContext {
        let identity = ValidatedStudyBackendIdentity(backendInstanceID: bootstrap.descriptor.backendID,
            stableStudyID: bootstrap.stableStudyID, normalizedStudyCode: bootstrap.normalizedStudyCode,
            supportedConfigurationSchemaVersion: bootstrap.configurationSchemaVersion, isActive: true, validatedAt: Date())
        let services = NoopStudyServices(backendID: bootstrap.descriptor.backendID, namespace: bootstrap.descriptor.authStorageNamespace)
        return .init(descriptor: bootstrap.descriptor, identity: identity, authenticator: services,
                     enrollments: services, withdrawals: services, surveyEvents: services,
                     healthKitSamples: UnavailableHealthKitSampleUploadRepository(),
                     media: UnavailableMediaUploadRepository())
    }
    func context(for resolved: ResolvedStudy) async throws -> StudyBackendContext {
        try await context(for: .init(controlStudyID: UUID(), configuration: resolved.configuration,
            stableStudyID: resolved.stableStudyID, normalizedStudyCode: resolved.normalizedStudyCode,
            configurationSchemaVersion: resolved.configurationSchemaVersion,
            configurationRevision: resolved.configurationRevision, descriptor: resolved.descriptor, fetchedAt: resolved.fetchedAt))
    }
}
private actor NoopStudyServices: StudyBackendAuthenticating, RemoteEnrollmentRepository, RemoteWithdrawalRepository, SurveyEventUploadRepository {
    let backendID: UUID; let storageNamespace: String
    init(backendID: UUID, namespace: String) { self.backendID = backendID; storageNamespace = namespace }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant { .init(authUserID: UUID(), isAnonymous: true, createdAt: nil) }
    func ensureParticipant() async throws -> RemoteParticipant { .init(id: UUID(), createdAt: Date()) }
    func register(_ registration: EnrollmentRegistration) async throws -> RemoteEnrollment { throw BackendError.unavailable }
    func updateSleepSchedule(wakeMinutes: Int, bedMinutes: Int) async throws { throw BackendError.unavailable }
    func updateParticipantIdentifier(_ value: String) async throws { throw BackendError.unavailable }
    func updateParticipantCharacteristics(_ value: HealthKitCharacteristics) async throws { throw BackendError.unavailable }
    func submit(_ event: PendingWithdrawalEvent, remoteEnrollmentID: UUID?) async throws -> UUID { throw BackendError.unavailable }
    func upload(_ event: SurveyEventUpload) async throws -> SurveyEventAcknowledgment { throw BackendError.unavailable }
}
private actor MemorySecureStore: InstallationIDSecureStoring {
    var value: String?; func read() async throws -> String? { value }; func write(_ value: String) async throws { self.value = value }
    func remove() async throws { value = nil }; func set(_ value: String?) { self.value = value }
}
private final class MemoryMarker: InstallationMarkerStoring { var exists = false }

private func fixture(_ name: String = "SleepStudy") throws -> StudyConfiguration {
    let url = try XCTUnwrap(Bundle(for: BackendEnvironmentTests.self).url(forResource: name, withExtension: "json"))
    return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
}
private func environment(_ name: BackendEnvironmentName) throws -> BackendEnvironment {
    try .init(name: name, supabaseURL: XCTUnwrap(URL(string: "https://control.supabase.co")),
              supabaseAnonKey: "public-control-key-123456789")
}
private func controlBootstrap() async throws -> ControlStudyBootstrap {
    let config = try fixture(), descriptor = try StudyBackendDescriptor(backendID: UUID(),
        supabaseURL: XCTUnwrap(URL(string: "https://sleep.supabase.co")),
        supabaseAnonKey: "public-sleep-key-123456789", environment: .development,
        revision: 1, diagnosticName: "Sleep Development").validated(for: .development)
    return .init(controlStudyID: UUID(), configuration: config, stableStudyID: config.identity.id,
        normalizedStudyCode: config.identity.code, configurationSchemaVersion: config.schemaVersion,
        configurationRevision: 1, descriptor: descriptor, fetchedAt: Date())
}
private func resolvedStudy() async throws -> ResolvedStudy {
    let bootstrap = try await controlBootstrap()
    let identity = ValidatedStudyBackendIdentity(backendInstanceID: bootstrap.descriptor.backendID,
        stableStudyID: bootstrap.stableStudyID, normalizedStudyCode: bootstrap.normalizedStudyCode,
        supportedConfigurationSchemaVersion: bootstrap.configurationSchemaVersion, isActive: true, validatedAt: Date())
    return .init(configuration: bootstrap.configuration, stableStudyID: bootstrap.stableStudyID,
        normalizedStudyCode: bootstrap.normalizedStudyCode,
        configurationSchemaVersion: bootstrap.configurationSchemaVersion,
        configurationRevision: bootstrap.configurationRevision, source: .cache,
        descriptor: bootstrap.descriptor, validatedIdentity: identity, controlEnvironment: .development,
        fetchedAt: bootstrap.fetchedAt, bootstrapCacheKey: "c1-d1.bootstrap")
}
private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}
