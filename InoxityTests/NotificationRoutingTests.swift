import XCTest
@testable import Inoxity

final class NotificationRoutingTests: XCTestCase {
    func testSurveyAndMessageRoutes() {
        let survey = values(kind: "survey", destination: "surveys", surveyID: "daily")
        XCTAssertEqual(NotificationRouteParser.route(from: survey), .init(studyID: "study", destination: .survey(surveyID: "daily", occurrenceID: "20260801")))
        XCTAssertEqual(NotificationRouteParser.route(from: values(kind: "message", destination: "settings")), .init(studyID: "study", destination: .settings))
    }
    func testMalformedPayloadFailsSafely() { XCTAssertNil(NotificationRouteParser.route(from: ["studyID": "study"])) }
    private func values(kind: String, destination: String, surveyID: String? = nil) -> [String:String] {
        var value = ["studyID":"study", "reminderID":"r", "notificationKind":kind, "occurrenceID":"20260801", "destination":destination]
        value["surveyID"] = surveyID; return value
    }
}
