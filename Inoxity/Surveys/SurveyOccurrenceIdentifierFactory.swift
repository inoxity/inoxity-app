import Foundation

enum SurveyOccurrenceIdentifierFactory {
    private static let componentPattern = #"^[a-z0-9][a-z0-9-]*$"#

    static func isValidComponent(_ value: String) -> Bool {
        value.range(of: componentPattern, options: .regularExpression) != nil
    }

    static func identifier(studyID: String, surveyID: String, occurrence: Date, calendar: Calendar) throws -> String {
        guard isValidComponent(studyID), isValidComponent(surveyID) else { throw SurveyRuntimeError.invalidIdentifier }
        let values = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence)
        let key = String(format: "%04d%02d%02dT%02d%02d", values.year ?? 0, values.month ?? 0,
                         values.day ?? 0, values.hour ?? 0, values.minute ?? 0)
        return "inoxity.\(studyID).\(surveyID).\(key)"
    }

    static func belongs(_ identifier: String, studyID: String, surveyID: String) -> Bool {
        identifier.hasPrefix("inoxity.\(studyID).\(surveyID).")
    }
}
