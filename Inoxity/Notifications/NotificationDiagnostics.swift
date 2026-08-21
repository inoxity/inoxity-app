import Foundation

struct NotificationDiagnostics: Equatable, Sendable {
    let authorizationStatus: NativeNotificationAuthorizationStatus
    let permissionRequestCompleted: Bool
    let configuredReminderCount: Int
    let pendingRequestCount: Int
    let nextFireDate: Date?
    let lastReconciliationDate: Date?
    let lastReconciliationResult: String
    let fingerprintMatches: Bool
    let surveyRemindersEnabled: Bool
    let messageRemindersEnabled: Bool

    static let empty = NotificationDiagnostics(authorizationStatus: .notDetermined, permissionRequestCompleted: false,
        configuredReminderCount: 0, pendingRequestCount: 0, nextFireDate: nil, lastReconciliationDate: nil,
        lastReconciliationResult: "Never", fingerprintMatches: false, surveyRemindersEnabled: false, messageRemindersEnabled: false)
}
