import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "inoxity.study.activity"
    static let surveyCategoryIdentifier = "inoxity.study.survey"
    static let takeSurveyActionIdentifier = "TAKE_SURVEY"
    static let snoozeActionIdentifier = "SNOOZE_15"
    static let snoozeInterval: TimeInterval = 15 * 60
    static let testIdentifierPrefix = "inoxity.test."
    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]
    private let center: UNUserNotificationCenter
    private var responseHandler: (([String: String]) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        let surveyCategory = UNNotificationCategory(
            identifier: Self.surveyCategoryIdentifier,
            actions: [
                UNNotificationAction(identifier: Self.takeSurveyActionIdentifier, title: "Take Survey", options: [.foreground]),
                UNNotificationAction(identifier: Self.snoozeActionIdentifier, title: "Snooze 15 min", options: []),
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [], intentIdentifiers: []),
            surveyCategory,
        ])
    }

    var isAvailable: Bool { true }

    func authorizationStatus() async -> NativeNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> NotificationPermissionRequestResult {
        guard isAvailable else { throw NotificationServiceError.unavailable }
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        return Self.permissionResult(granted: granted)
    }

    static func permissionResult(granted: Bool) -> NotificationPermissionRequestResult {
        granted ? .completed : .attentionNeeded("Notifications were not enabled. You can continue without them.")
    }

    func pendingRequests() async -> [ScheduledNotification] {
        await center.pendingNotificationRequests().compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate(),
                  let payload = NotificationRouteParser.payload(from: request.content.userInfo) else { return nil }
            return ScheduledNotification(identifier: request.identifier, fireDate: date, title: request.content.title,
                                         body: request.content.body, payload: payload)
        }
    }

    func add(_ requests: [ScheduledNotification]) async throws {
        for value in requests {
            let content = UNMutableNotificationContent()
            content.title = value.title; content.body = value.body; content.sound = .default
            content.categoryIdentifier = value.payload.notificationKind == .survey
                ? Self.surveyCategoryIdentifier : Self.categoryIdentifier
            content.userInfo = value.payload.dictionary
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = value.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: value.fireDate)
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: value.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) }
            catch { throw NotificationServiceError.nativeFailure(error.localizedDescription) }
        }
    }

    func removePendingRequests(with identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removePendingRequests(forStudyID studyID: String) async {
        let identifiers = await center.pendingNotificationRequests().map(\.identifier)
            .filter { NotificationIdentifierFactory.owns($0, studyID: studyID) }
        removePendingRequests(with: identifiers)
    }
    func setResponseHandler(_ handler: @escaping ([String: String]) -> Void) { responseHandler = handler }

#if DEBUG
    func scheduleTestNotification(after delay: TimeInterval = 10) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Inoxity Test Notification"
        content.body = "This is a local notification delivery test."
        content.sound = .default; content.categoryIdentifier = Self.categoryIdentifier
        let identifier = Self.testIdentifierPrefix + UUID().uuidString.lowercased()
        try await center.add(.init(identifier: identifier, content: content,
                                   trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)))
    }
#endif

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == Self.snoozeActionIdentifier {
            let original = response.notification.request.content
            let snoozed = UNMutableNotificationContent()
            snoozed.title = original.title; snoozed.body = original.body; snoozed.sound = original.sound
            snoozed.categoryIdentifier = original.categoryIdentifier; snoozed.userInfo = original.userInfo
            let identifier = "\(response.notification.request.identifier).snoozed.\(UUID().uuidString.prefix(8))"
            let request = UNNotificationRequest(identifier: identifier, content: snoozed,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeInterval, repeats: false))
            try? await center.add(request)
            return
        }
        let dictionary = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[String(describing: pair.key)] = value }
        }
        await MainActor.run { responseHandler?(dictionary) }
    }
}
