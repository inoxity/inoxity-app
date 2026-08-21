import Foundation

enum WithdrawalChoice: String, Codable, Equatable, Sendable {
    case keepExistingData
    case deleteExistingData
}

enum WithdrawalSyncStatus: String, Codable, Equatable, Sendable { case pending, acknowledged, retryNeeded }
enum WithdrawalRoutingStatus: String, Codable, Equatable, Sendable { case verified, routingRequired }

struct PendingWithdrawalEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let studyID: String
    let choice: WithdrawalChoice
    let requestedAt: Date
    var syncStatus: WithdrawalSyncStatus
    var lastAttemptAt: Date?
    var retryCount: Int
    var failureCategory: BackendFailureCategory?
    var remoteRequestID: UUID?
    // var, not let: SyncCoordinator's promotion pass refreshes these from the latest
    // ParticipantState once routing reaches .registered, for an event created before that (see
    // SyncCoordinator.run()'s withdrawal loop) — mirrors SurveyEventUpload's identical fields,
    // which are `var` for the same reason.
    var studyBackendID: UUID?
    var descriptorCacheKey: String?
    var remoteEnrollmentID: UUID?
    var routingStatus: WithdrawalRoutingStatus

    init(id: String, studyID: String, choice: WithdrawalChoice, requestedAt: Date,
         syncStatus: WithdrawalSyncStatus = .pending, lastAttemptAt: Date? = nil,
         retryCount: Int = 0, failureCategory: BackendFailureCategory? = nil,
         remoteRequestID: UUID? = nil, studyBackendID: UUID? = nil,
         descriptorCacheKey: String? = nil, remoteEnrollmentID: UUID? = nil,
         routingStatus: WithdrawalRoutingStatus? = nil) {
        self.id = id; self.studyID = studyID; self.choice = choice; self.requestedAt = requestedAt
        self.syncStatus = syncStatus; self.lastAttemptAt = lastAttemptAt; self.retryCount = retryCount
        self.failureCategory = failureCategory; self.remoteRequestID = remoteRequestID
        self.studyBackendID = studyBackendID; self.descriptorCacheKey = descriptorCacheKey
        self.remoteEnrollmentID = remoteEnrollmentID
        self.routingStatus = routingStatus ?? ((studyBackendID != nil && descriptorCacheKey != nil) ? .verified : .routingRequired)
    }

    private enum CodingKeys: String, CodingKey { case id, studyID, choice, requestedAt, syncStatus, lastAttemptAt, retryCount, failureCategory, remoteRequestID, studyBackendID, descriptorCacheKey, remoteEnrollmentID, routingStatus }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); studyID = try c.decode(String.self, forKey: .studyID)
        choice = try c.decode(WithdrawalChoice.self, forKey: .choice); requestedAt = try c.decode(Date.self, forKey: .requestedAt)
        syncStatus = try c.decodeIfPresent(WithdrawalSyncStatus.self, forKey: .syncStatus) ?? .pending
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        failureCategory = try c.decodeIfPresent(BackendFailureCategory.self, forKey: .failureCategory)
        remoteRequestID = try c.decodeIfPresent(UUID.self, forKey: .remoteRequestID)
        studyBackendID = try c.decodeIfPresent(UUID.self, forKey: .studyBackendID)
        descriptorCacheKey = try c.decodeIfPresent(String.self, forKey: .descriptorCacheKey)
        remoteEnrollmentID = try c.decodeIfPresent(UUID.self, forKey: .remoteEnrollmentID)
        routingStatus = try c.decodeIfPresent(WithdrawalRoutingStatus.self, forKey: .routingStatus)
            ?? ((studyBackendID != nil && descriptorCacheKey != nil) ? .verified : .routingRequired)
    }
}

struct WithdrawalEventEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 3
    let persistenceVersion: Int
    var eventsByStudyID: [String: [PendingWithdrawalEvent]]
}

enum WithdrawalError: Error, Equatable, LocalizedError, Sendable {
    case invalidStudyID, persistenceFailed, retainedDataRequiresDecision

    var errorDescription: String? {
        switch self {
        case .invalidStudyID: "The study’s local data could not be safely identified."
        case .persistenceFailed: "Your withdrawal choice could not be saved. Please try again."
        case .retainedDataRequiresDecision: "This study has retained local data from a previous withdrawal."
        }
    }
}

struct RetainedEnrollmentConflict: Identifiable, Equatable, Sendable {
    let configuration: StudyConfiguration
    var id: String { configuration.identity.id }
}
