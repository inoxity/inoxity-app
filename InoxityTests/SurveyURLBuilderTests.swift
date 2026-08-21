import XCTest
@testable import Inoxity

final class SurveyURLBuilderTests: XCTestCase {
    func testFixedContextPreservesExistingAndOverridesOwnedKeys() throws {
        let url = try SurveyURLBuilder.build(baseURL: "https://example.edu/form?existing=yes&inoxity_study_id=old", studyID: "study-a", surveyID: "daily", occurrenceID: "inoxity.study-a.daily.20260724T0900", callbackEnabled: true)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)), items = parts.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "existing" }?.value, "yes")
        XCTAssertEqual(items.filter { $0.name == SurveyURLBuilder.studyParameter }.map(\.value), ["study-a"])
        XCTAssertNotNil(items.first { $0.name == SurveyURLBuilder.callbackParameter })
        XCTAssertFalse(url.absoluteString.contains("participant")); XCTAssertFalse(url.absoluteString.contains("SONA"))
    }

    func testRejectsUnsupportedAndMalformedURLs() {
        for value in ["http://example.edu", "javascript:alert(1)", "data:text/plain,x", "file:///tmp/x", "not a url"] {
            XCTAssertThrowsError(try SurveyURLBuilder.build(baseURL: value, studyID: "s", surveyID: "q", occurrenceID: "o", callbackEnabled: true))
        }
    }

    func testCallbackRouteIsAppOwned() throws {
        let callback = try SurveyURLBuilder.callbackURL(studyID: "s", surveyID: "q", occurrenceID: "o")
        XCTAssertEqual(callback.scheme, "inoxity"); XCTAssertEqual(callback.host, "survey-complete")
    }
}
