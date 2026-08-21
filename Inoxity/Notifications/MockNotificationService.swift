import Foundation

@MainActor
final class MockNotificationService: NotificationServicing {
    var isAvailable: Bool
    var nativeStatus: NativeNotificationAuthorizationStatus
    var requestResult: Result<NotificationPermissionRequestResult, Error>
    var addError: Error?
    private(set) var requests: [String: ScheduledNotification]
    private(set) var requestAuthorizationCallCount = 0
    private(set) var addedBatches: [[ScheduledNotification]] = []
    private(set) var removedBatches: [[String]] = []
    private var responseHandler: (([String: String]) -> Void)?
    private(set) var testNotificationDelays: [TimeInterval] = []

    init(isAvailable: Bool = true, nativeStatus: NativeNotificationAuthorizationStatus = .authorized,
         requestResult: Result<NotificationPermissionRequestResult, Error> = .success(.completed),
         requests: [ScheduledNotification] = []) {
        self.isAvailable = isAvailable; self.nativeStatus = nativeStatus; self.requestResult = requestResult
        self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
    }

    func authorizationStatus() async -> NativeNotificationAuthorizationStatus { isAvailable ? nativeStatus : .unavailable }
    func requestAuthorization() async throws -> NotificationPermissionRequestResult {
        requestAuthorizationCallCount += 1
        return try requestResult.get()
    }
    func pendingRequests() async -> [ScheduledNotification] { Array(requests.values) }
    func add(_ values: [ScheduledNotification]) async throws {
        if let addError { throw addError }
        addedBatches.append(values)
        values.forEach { requests[$0.identifier] = $0 }
    }
    func removePendingRequests(with identifiers: [String]) {
        removedBatches.append(identifiers)
        identifiers.forEach { requests.removeValue(forKey: $0) }
    }
    func removePendingRequests(forStudyID studyID: String) async {
        removePendingRequests(with: requests.keys.filter { NotificationIdentifierFactory.owns($0, studyID: studyID) })
    }
    func setResponseHandler(_ handler: @escaping ([String: String]) -> Void) { responseHandler = handler }
    func simulateResponse(_ payload: [String: String]) { responseHandler?(payload) }
    func clearPendingRequestsForTesting() { requests.removeAll() }
#if DEBUG
    func scheduleTestNotification(after delay: TimeInterval) async throws { testNotificationDelays.append(delay) }
#endif
}
