import Foundation

enum NotificationPermissionState: String, Codable, Equatable, Sendable {
    case notRequested, requestCompleted, attentionNeeded
}

enum NativeNotificationAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral, unavailable
}

enum NotificationRuntimeStatus: Equatable, Sendable {
    case notRequested, requesting, requestCompleted, unavailable, attentionNeeded(String)
    case scheduling, scheduled(Int), noEnabledReminders
    case reconciliationSucceeded(Int), reconciliationFailed(String)
}

enum NotificationPermissionRequestResult: Equatable, Sendable {
    case completed
    case attentionNeeded(String)
}

struct NotificationSchedulingPolicy: Equatable, Sendable {
    let rollingHorizonDays: Int
    let maximumPendingRequestsPerStudy: Int
    let replenishmentThresholdDays: Int

    static let `default` = NotificationSchedulingPolicy(
        rollingHorizonDays: 30,
        maximumPendingRequestsPerStudy: 60,
        replenishmentThresholdDays: 7
    )
}

struct NotificationPayload: Equatable, Sendable {
    let studyID: String
    let reminderID: String
    let notificationKind: ReminderKind
    let surveyID: String?
    let occurrenceID: String
    let destination: NotificationDestinationConfiguration

    var dictionary: [String: String] {
        var value = ["studyID": studyID, "reminderID": reminderID,
                     "notificationKind": notificationKind.rawValue, "occurrenceID": occurrenceID,
                     "destination": destination.rawValue]
        if let surveyID { value["surveyID"] = surveyID }
        return value
    }
}

struct ScheduledNotification: Equatable, Identifiable, Sendable {
    let identifier: String
    let fireDate: Date
    let title: String
    let body: String
    let payload: NotificationPayload
    let timeZoneIdentifier: String?
    var id: String { identifier }

    init(identifier: String, fireDate: Date, title: String, body: String, payload: NotificationPayload,
         timeZoneIdentifier: String? = nil) {
        self.identifier = identifier; self.fireDate = fireDate; self.title = title; self.body = body
        self.payload = payload; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

struct NotificationSchedulePlan: Equatable, Sendable {
    let requests: [ScheduledNotification]
    let generatedOccurrenceCount: Int
    let scheduledOccurrenceCount: Int
    let omittedOccurrenceCount: Int
    let wasTruncated: Bool
    let fingerprint: String
}

struct NotificationPendingSummary: Equatable, Sendable {
    let count: Int
    let nextDate: Date?
}

enum NotificationServiceError: Error, Equatable, LocalizedError {
    case unavailable, permissionDenied, duplicateIdentifier(String), invalidRequest(String), nativeFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Notifications are unavailable on this device."
        case .permissionDenied: "Notifications are turned off. You can enable them in System Settings."
        case .duplicateIdentifier(let id): "A duplicate reminder identifier was generated: \(id)."
        case .invalidRequest: "A configured reminder could not be scheduled."
        case .nativeFailure(let message): "Reminder scheduling failed: \(message)"
        }
    }
}
