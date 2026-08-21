import Foundation

@MainActor
final class MockHealthKitService: HealthKitServicing {
    var isHealthDataAvailable: Bool
    var authorizationResult: Result<HealthKitAuthorizationRequestResult, Error>
    var requestStatusResult: Result<HealthKitAuthorizationPreCheck, Error>
    var syncResult: Result<HealthKitLocalSyncSummary, Error>
    var characteristicsResult: HealthKitCharacteristics
    private(set) var authorizationRequests: [Set<String>] = []
    private(set) var requestStatusRequests: [Set<String>] = []
    private(set) var syncRequests: [(Set<String>, DateInterval)] = []
    private(set) var characteristicsReadCount = 0
    /// Whether each call to `requestReadAuthorization`/`requestStatus` (in that order, interleaved)
    /// was asked to include characteristics — kept separate from `authorizationRequests`/
    /// `requestStatusRequests` so existing call sites asserting just the identifier set don't need
    /// to change.
    private(set) var includeCharacteristicsRequests: [Bool] = []

    init(
        isHealthDataAvailable: Bool = true,
        authorizationResult: Result<HealthKitAuthorizationRequestResult, Error> = .success(.completed),
        requestStatusResult: Result<HealthKitAuthorizationPreCheck, Error> = .success(.shouldRequest),
        syncResult: Result<HealthKitLocalSyncSummary, Error> = .success(.init(completedAt: Date(timeIntervalSince1970: 1_700_000_000), metrics: [])),
        characteristicsResult: HealthKitCharacteristics = HealthKitCharacteristics()
    ) {
        self.isHealthDataAvailable = isHealthDataAvailable
        self.authorizationResult = authorizationResult
        self.requestStatusResult = requestStatusResult
        self.syncResult = syncResult
        self.characteristicsResult = characteristicsResult
    }

    func requestReadAuthorization(for identifiers: Set<String>, includeCharacteristics: Bool = false) async throws -> HealthKitAuthorizationRequestResult {
        authorizationRequests.append(identifiers)
        includeCharacteristicsRequests.append(includeCharacteristics)
        return try authorizationResult.get()
    }

    func requestStatus(for identifiers: Set<String>, includeCharacteristics: Bool = false) async throws -> HealthKitAuthorizationPreCheck {
        requestStatusRequests.append(identifiers)
        includeCharacteristicsRequests.append(includeCharacteristics)
        return try requestStatusResult.get()
    }

    func syncLocalData(for identifiers: Set<String>, interval: DateInterval) async throws -> HealthKitLocalSyncSummary {
        syncRequests.append((identifiers, interval))
        return try syncResult.get()
    }

    func readCharacteristics() -> HealthKitCharacteristics {
        characteristicsReadCount += 1
        return characteristicsResult
    }
}
