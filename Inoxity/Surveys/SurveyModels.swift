import Foundation

enum SurveyOccurrenceStatus: String, Equatable, Sendable {
    /// `late`: never opened and past the survey's `promptExpirationMinutes` deadline, but still
    /// before `closesAt`. That deadline is for adherence tracking only, so a late occurrence can
    /// still be opened. `missed` means past `closesAt` and no longer openable.
    case upcoming, available, late, opened, completed, missed, unavailable, outsideStudyWindow

    /// Whether the participant can open (or return to) the survey right now.
    var isOpenable: Bool { self == .available || self == .late || self == .opened }
}

struct SurveyOccurrence: Identifiable, Equatable, Sendable {
    let id: String
    let studyID: String
    let surveyID: String
    let name: String
    let summary: String
    let instructions: String?
    let privacyText: String?
    let presentationMode: SurveyPresentationMode
    let scheduledFor: Date
    let opensAt: Date
    let closesAt: Date
    let openedAt: Date?
    let completedAt: Date?
    let status: SurveyOccurrenceStatus
}

struct PersistedSurveyOccurrenceState: Codable, Equatable, Sendable {
    let occurrenceID: String
    let surveyID: String
    let scheduledFor: Date
    var openedAt: Date?
    var completedAt: Date?
}

struct SurveyRuntimeSummary: Equatable, Sendable {
    var occurrences: [SurveyOccurrence] = []
    var availableCount: Int { occurrences.filter { $0.status.isOpenable }.count }
    var completedCount: Int { occurrences.filter { $0.status == .completed }.count }
    var missedCount: Int { occurrences.filter { $0.status == .missed }.count }
    var lastCompletionDate: Date? { occurrences.compactMap(\.completedAt).max() }
}

struct SurveyPresentationRequest: Identifiable, Equatable, Sendable {
    let occurrenceID: String
    let url: URL
    let mode: SurveyPresentationMode
    var id: String { occurrenceID }
}

struct SurveyCallback: Equatable, Sendable {
    let studyID: String
    let surveyID: String
    let occurrenceID: String
}

enum SurveyRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier, invalidURL, unsupportedScheme, unavailableOccurrence
    case presentationFailed, malformedCallback, wrongStudy, unknownSurvey, unknownOccurrence
    case inconsistentPersistedState, callbackNotEnabled, occurrenceNotOpened, invalidOpenedTimeline
    case callbackBeforeOpen, callbackExpired, unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidURL, .unsupportedScheme: "This survey link is not available. Please contact the study team."
        case .unavailableOccurrence: "This survey is not currently available."
        case .presentationFailed: "The survey could not be opened. Please try again."
        case .malformedCallback: "The survey completion link was not valid."
        case .wrongStudy: "This survey completion belongs to a different study."
        case .unknownSurvey, .unknownOccurrence, .invalidIdentifier: "The survey completion could not be verified on this device."
        case .callbackExpired: "This survey completion link has expired."
        case .occurrenceNotOpened, .invalidOpenedTimeline, .callbackBeforeOpen: "This survey completion could not be verified."
        case .inconsistentPersistedState: "Saved survey progress could not be restored safely."
        case .callbackNotEnabled: "Survey completion callbacks are not enabled for this survey."
        case .unsupportedConfiguration: "This study requires a newer version of Inoxity."
        }
    }
}

enum SurveyEventType: String, Codable, Equatable, Sendable { case opened, completed }
enum SurveyEventSource: String, Codable, Equatable, Sendable { case presentation, completionCallback, restoration }
enum SurveyEventSyncStatus: String, Codable, Equatable, Sendable {
    case pending, syncing, acknowledged, retryableFailure, routingRequired, attentionRequired
}

struct SurveyEventUpload: Codable, Equatable, Identifiable, Sendable {
    var id: String { clientEventID }
    let clientEventID: String
    let stableStudyID: String
    let surveyID: String
    let occurrenceID: String
    let scheduledFor: Date
    let type: SurveyEventType
    let eventTimestamp: Date
    let openedAt: Date?
    let completedAt: Date?
    /// IANA identifier (e.g. "America/Los_Angeles") for the zone this event was captured in —
    /// see `HealthKitSampleUpload.sampleTimeZoneIdentifier` for the same rationale. Unlike
    /// HealthKit samples (which can be backfilled from a stale device zone), survey events are
    /// always captured live, so this is simply the device's zone at the moment of `enqueue`.
    let eventTimeZoneIdentifier: String
    let configurationSchemaVersion: Int
    let configurationRevision: Int
    let source: SurveyEventSource
    let appVersion: String
    let createdAt: Date
    var studyBackendID: UUID?
    var descriptorCacheKey: String?
    var descriptorRevision: Int?
    var remoteEnrollmentID: UUID?
    var syncStatus: SurveyEventSyncStatus
    var retryCount: Int
    var lastAttemptAt: Date?
    var failureCategory: BackendFailureCategory?
    var acknowledgedAt: Date?
    var remoteAcknowledgmentID: UUID?
}

enum SurveyEventIdentityFactory {
    static func id(occurrenceID: String, type: SurveyEventType) -> String {
        "survey-event.\(occurrenceID).\(type.rawValue)"
    }
}

struct SurveyEventAcknowledgment: Equatable, Sendable {
    let acknowledgmentID: UUID
    let receivedAt: Date
    let idempotentExisting: Bool
}

struct SurveyEventQueueDiagnostics: Equatable, Sendable {
    let pending, acknowledged, retryableFailures, routingRequired, attentionRequired: Int
    let lastSyncAt: Date?
    static let empty = Self(pending: 0, acknowledged: 0, retryableFailures: 0,
                            routingRequired: 0, attentionRequired: 0, lastSyncAt: nil)
}

protocol SurveyEventQueueing: Sendable {
    func reconcile(_ state: ParticipantState, appVersion: String, now: Date, timeZone: TimeZone?) async throws
    func enqueueOpened(_ record: PersistedSurveyOccurrenceState, participant: ParticipantState,
                       source: SurveyEventSource, appVersion: String, now: Date, timeZone: TimeZone?) async throws
    func enqueueCompleted(_ record: PersistedSurveyOccurrenceState, participant: ParticipantState,
                          source: SurveyEventSource, appVersion: String, now: Date, timeZone: TimeZone?) async throws
    func events(for studyID: String) async throws -> [SurveyEventUpload]
    func allEvents() async throws -> [SurveyEventUpload]
    func update(_ event: SurveyEventUpload) async throws
    func reset(studyID: String) async throws
    func diagnostics(studyID: String) async -> SurveyEventQueueDiagnostics
    func recordSync(at date: Date) async
}

actor UserDefaultsSurveyEventQueue: SurveyEventQueueing {
    private struct Envelope: Codable { var version = 1; var studies: [String: [SurveyEventUpload]] = [:]; var lastSyncAt: Date? }
    private let defaults: UserDefaults
    private let key: String
    private var envelope: Envelope

    init(defaults: UserDefaults = .standard, key: String = "inoxity.survey-event-queue.v1") {
        self.defaults = defaults; self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Envelope.self, from: data), decoded.version == 1 {
            var recovered = decoded
            for studyID in recovered.studies.keys {
                recovered.studies[studyID] = recovered.studies[studyID]?.map {
                    var value = $0
                    if value.syncStatus == .syncing { value.syncStatus = .pending }
                    return value
                }
            }
            envelope = recovered
        } else { envelope = Envelope() }
        if let data = try? JSONEncoder().encode(envelope) { defaults.set(data, forKey: key) }
    }

    // timeZone defaults to nil (→ .current inside `enqueue`) here even though the protocol
    // requirement above can't itself carry a default (Swift disallows default arguments in
    // protocol requirements) — callers going through the concrete type directly (most existing
    // tests) keep compiling unchanged; callers going through `any SurveyEventQueueing`
    // (AppState/SyncCoordinator) must pass it explicitly, which they do with `.current`.
    func reconcile(_ state: ParticipantState, appVersion: String, now: Date, timeZone: TimeZone? = nil) throws {
        guard state.participationStatus == .enrolled else { return }
        for record in state.surveyOccurrenceStates.values {
            if record.openedAt != nil { try enqueue(.opened, record: record, participant: state, source: .restoration, appVersion: appVersion, now: now, timeZone: timeZone) }
            if record.completedAt != nil { try enqueue(.completed, record: record, participant: state, source: .restoration, appVersion: appVersion, now: now, timeZone: timeZone) }
        }
    }
    func enqueueOpened(_ record: PersistedSurveyOccurrenceState, participant: ParticipantState,
                       source: SurveyEventSource, appVersion: String, now: Date, timeZone: TimeZone? = nil) throws {
        try enqueue(.opened, record: record, participant: participant, source: source, appVersion: appVersion, now: now, timeZone: timeZone)
    }
    func enqueueCompleted(_ record: PersistedSurveyOccurrenceState, participant: ParticipantState,
                          source: SurveyEventSource, appVersion: String, now: Date, timeZone: TimeZone? = nil) throws {
        try enqueue(.opened, record: record, participant: participant, source: source, appVersion: appVersion, now: now, timeZone: timeZone)
        try enqueue(.completed, record: record, participant: participant, source: source, appVersion: appVersion, now: now, timeZone: timeZone)
    }
    func events(for studyID: String) -> [SurveyEventUpload] { envelope.studies[studyID] ?? [] }
    func allEvents() -> [SurveyEventUpload] { envelope.studies.values.flatMap { $0 } }
    func update(_ event: SurveyEventUpload) throws {
        guard var values = envelope.studies[event.stableStudyID], let index = values.firstIndex(where: { $0.id == event.id }) else { return }
        values[index] = event; envelope.studies[event.stableStudyID] = values; try save()
    }
    func reset(studyID: String) throws { envelope.studies.removeValue(forKey: studyID); try save() }
    func diagnostics(studyID: String) -> SurveyEventQueueDiagnostics {
        let values = envelope.studies[studyID] ?? []
        return .init(pending: values.filter { $0.syncStatus == .pending || $0.syncStatus == .syncing }.count,
                     acknowledged: values.filter { $0.syncStatus == .acknowledged }.count,
                     retryableFailures: values.filter { $0.syncStatus == .retryableFailure }.count,
                     routingRequired: values.filter { $0.syncStatus == .routingRequired }.count,
                     attentionRequired: values.filter { $0.syncStatus == .attentionRequired }.count,
                     lastSyncAt: envelope.lastSyncAt)
    }
    func recordSync(at date: Date) { envelope.lastSyncAt = date; persist() }

    private func enqueue(_ type: SurveyEventType, record: PersistedSurveyOccurrenceState, participant: ParticipantState,
                         source: SurveyEventSource, appVersion: String, now: Date, timeZone: TimeZone?) throws {
        let id = SurveyEventIdentityFactory.id(occurrenceID: record.occurrenceID, type: type)
        var values = envelope.studies[participant.studyID] ?? []
        if let index = values.firstIndex(where: { $0.id == id }) {
            if values[index].syncStatus == .routingRequired,
               (participant.backendRoutingStatus == .identityVerified || participant.backendRoutingStatus == .registered),
               let backendID = participant.studyBackendID,
               let cacheKey = participant.studyBackendDescriptorCacheKey,
               let enrollmentID = participant.remoteEnrollmentID {
                values[index].studyBackendID = backendID; values[index].descriptorCacheKey = cacheKey
                values[index].descriptorRevision = participant.studyBackendDescriptorRevision
                values[index].remoteEnrollmentID = enrollmentID; values[index].syncStatus = .pending
                envelope.studies[participant.studyID] = values; try save()
            }
            return
        }
        guard let timestamp = type == .opened ? record.openedAt : record.completedAt else { return }
        let routed = (participant.backendRoutingStatus == .identityVerified || participant.backendRoutingStatus == .registered)
            && participant.studyBackendID != nil && participant.studyBackendDescriptorCacheKey != nil
            && participant.remoteEnrollmentID != nil
        values.append(.init(clientEventID: id, stableStudyID: participant.studyID, surveyID: record.surveyID,
            occurrenceID: record.occurrenceID, scheduledFor: record.scheduledFor, type: type,
            eventTimestamp: timestamp, openedAt: record.openedAt, completedAt: record.completedAt,
            eventTimeZoneIdentifier: (timeZone ?? .current).identifier,
            configurationSchemaVersion: participant.enrolledConfigurationSchemaVersion ?? 0,
            configurationRevision: participant.enrolledConfigurationRevision ?? 0, source: source,
            appVersion: appVersion, createdAt: now, studyBackendID: participant.studyBackendID,
            descriptorCacheKey: participant.studyBackendDescriptorCacheKey,
            descriptorRevision: participant.studyBackendDescriptorRevision,
            remoteEnrollmentID: participant.remoteEnrollmentID,
            syncStatus: routed ? .pending : .routingRequired, retryCount: 0, lastAttemptAt: nil,
            failureCategory: nil, acknowledgedAt: nil, remoteAcknowledgmentID: nil))
        envelope.studies[participant.studyID] = values; try save()
    }
    private func save() throws { defaults.set(try JSONEncoder().encode(envelope), forKey: key) }
    private func persist() { try? save() }
}
