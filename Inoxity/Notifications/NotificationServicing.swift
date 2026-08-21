import Foundation

@MainActor
protocol NotificationServicing: AnyObject {
    var isAvailable: Bool { get }
    func authorizationStatus() async -> NativeNotificationAuthorizationStatus
    func requestAuthorization() async throws -> NotificationPermissionRequestResult
    func pendingRequests() async -> [ScheduledNotification]
    func add(_ requests: [ScheduledNotification]) async throws
    func removePendingRequests(with identifiers: [String])
    func removePendingRequests(forStudyID studyID: String) async
    func setResponseHandler(_ handler: @escaping ([String: String]) -> Void)
#if DEBUG
    func scheduleTestNotification(after delay: TimeInterval) async throws
#endif
}
