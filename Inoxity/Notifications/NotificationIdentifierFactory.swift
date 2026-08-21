import Foundation

enum NotificationIdentifierFactory {
    static func studyPrefix(studyID: String) -> String { "inoxity.\(studyID)." }

    static func identifier(studyID: String, reminderID: String, occurrence: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence)
        let key = String(format: "%04d%02d%02dT%02d%02d", components.year ?? 0, components.month ?? 0,
                         components.day ?? 0, components.hour ?? 0, components.minute ?? 0)
        return "\(studyPrefix(studyID: studyID))\(reminderID).\(key)"
    }

    static func owns(_ identifier: String, studyID: String) -> Bool {
        identifier.hasPrefix(studyPrefix(studyID: studyID))
    }
}
