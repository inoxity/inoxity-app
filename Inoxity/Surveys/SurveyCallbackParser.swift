import Foundation

enum SurveyCallbackParser {
    static func isCandidate(_ url: URL) -> Bool { url.scheme?.lowercased() == SurveyURLBuilder.callbackScheme }

    static func parse(_ url: URL) throws -> SurveyCallback {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == SurveyURLBuilder.callbackScheme,
              parts.host?.lowercased() == SurveyURLBuilder.callbackHost else { throw SurveyRuntimeError.malformedCallback }
        func exactlyOne(_ name: String) throws -> String {
            let values = (parts.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
            guard values.count == 1, let value = values.first, !value.isEmpty else { throw SurveyRuntimeError.malformedCallback }
            return value
        }
        return .init(studyID: try exactlyOne("study_id"), surveyID: try exactlyOne("survey_id"),
                     occurrenceID: try exactlyOne("occurrence_id"))
    }
}
