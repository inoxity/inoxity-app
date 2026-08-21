import Foundation

enum SurveyURLBuilder {
    static let callbackScheme = "inoxity"
    static let callbackHost = "survey-complete"
    static let studyParameter = "inoxity_study_id"
    static let surveyParameter = "inoxity_survey_id"
    static let occurrenceParameter = "inoxity_occurrence_id"
    static let callbackParameter = "inoxity_callback_url"

    static func build(baseURL: String, studyID: String, surveyID: String, occurrenceID: String,
                      callbackEnabled: Bool) throws -> URL {
        guard var parts = URLComponents(string: baseURL), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false else { throw SurveyRuntimeError.invalidURL }
        let owned = Set([studyParameter, surveyParameter, occurrenceParameter, callbackParameter])
        var items = (parts.queryItems ?? []).filter { !owned.contains($0.name) }
        items.append(.init(name: studyParameter, value: studyID))
        items.append(.init(name: surveyParameter, value: surveyID))
        items.append(.init(name: occurrenceParameter, value: occurrenceID))
        if callbackEnabled {
            items.append(.init(name: callbackParameter, value: try callbackURL(studyID: studyID, surveyID: surveyID, occurrenceID: occurrenceID).absoluteString))
        }
        parts.queryItems = items
        guard let value = parts.url else { throw SurveyRuntimeError.invalidURL }
        return value
    }

    static func callbackURL(studyID: String, surveyID: String, occurrenceID: String) throws -> URL {
        var parts = URLComponents(); parts.scheme = callbackScheme; parts.host = callbackHost
        parts.queryItems = [.init(name: "study_id", value: studyID), .init(name: "survey_id", value: surveyID),
                            .init(name: "occurrence_id", value: occurrenceID)]
        guard let value = parts.url else { throw SurveyRuntimeError.invalidURL }
        return value
    }
}
