import XCTest
@testable import Inoxity

final class SurveyCallbackParserTests: XCTestCase {
    func testValidCallback() throws {
        let url = try SurveyURLBuilder.callbackURL(studyID: "study", surveyID: "survey", occurrenceID: "inoxity.study.survey.20260724T0900")
        XCTAssertEqual(try SurveyCallbackParser.parse(url), .init(studyID: "study", surveyID: "survey", occurrenceID: "inoxity.study.survey.20260724T0900"))
    }
    func testMalformedWrongSchemeHostMissingAndDuplicateRejected() {
        for value in ["https://survey-complete?study_id=s&survey_id=q&occurrence_id=o", "inoxity://other?study_id=s&survey_id=q&occurrence_id=o", "inoxity://survey-complete?study_id=s&survey_id=q", "inoxity://survey-complete?study_id=s&study_id=x&survey_id=q&occurrence_id=o"] {
            XCTAssertThrowsError(try SurveyCallbackParser.parse(URL(string: value)!))
        }
    }
}
