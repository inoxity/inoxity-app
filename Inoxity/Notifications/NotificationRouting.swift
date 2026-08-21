import Foundation

enum NotificationDestination: Equatable, Sendable {
    case home, surveys, survey(surveyID: String, occurrenceID: String?), settings, aboutStudy
}

struct PendingNotificationRoute: Equatable, Sendable {
    let studyID: String
    let destination: NotificationDestination
}

enum NotificationRouteParser {
    static func payload(from userInfo: [AnyHashable: Any]) -> NotificationPayload? {
        var values = [String: String]()
        for (key, value) in userInfo { if let value = value as? String { values[String(describing: key)] = value } }
        return payload(from: values)
    }

    static func payload(from values: [String: String]) -> NotificationPayload? {
        guard let studyID = values["studyID"], let reminderID = values["reminderID"],
              let kindRaw = values["notificationKind"], let kind = ReminderKind(rawValue: kindRaw),
              let occurrenceID = values["occurrenceID"],
              let destinationRaw = values["destination"],
              let destination = NotificationDestinationConfiguration(rawValue: destinationRaw) else { return nil }
        return NotificationPayload(studyID: studyID, reminderID: reminderID, notificationKind: kind,
                                   surveyID: values["surveyID"], occurrenceID: occurrenceID, destination: destination)
    }

    static func route(from values: [String: String]) -> PendingNotificationRoute? {
        guard let payload = payload(from: values) else { return nil }
        let destination: NotificationDestination
        if payload.notificationKind == .survey, let surveyID = payload.surveyID {
            destination = .survey(surveyID: surveyID, occurrenceID: payload.occurrenceID)
        } else {
            switch payload.destination {
            case .home: destination = .home
            case .surveys: destination = .surveys
            case .settings: destination = .settings
            case .aboutStudy: destination = .aboutStudy
            }
        }
        return PendingNotificationRoute(studyID: payload.studyID, destination: destination)
    }
}
