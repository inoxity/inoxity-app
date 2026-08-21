import XCTest
@testable import Inoxity

final class SurveyConfigurationTests: XCTestCase {
    func testBundledSchemaFourSurveysDecodeAndValidate() throws {
        for name in ["SleepStudy", "ActivityStudy"] {
            let value = try fixture(name)
            XCTAssertEqual(value.schemaVersion, 5)
            XCTAssertNoThrow(try validator.validate(value))
            XCTAssertNotNil(value.surveys.first?.schedule)
            XCTAssertTrue(value.reminders.filter { $0.kind == .survey }.allSatisfy { $0.schedule == nil && $0.notifyMinutesBefore != nil })
        }
    }

    func testSchemaThreeSurveyMigratesAndLegacyParticipantParameterIsIgnored() throws {
        var root = try json("SleepStudy"); root["schemaVersion"] = 3
        root["surveys"] = [["id":"legacy", "title":"Legacy", "summary":"Summary", "instructions":"Instructions",
                            "enabled":true, "externalURL":"https://example.edu/form",
                            "availability":["startDate":"2025-01-01", "endDate":"2035-12-31", "weekdays":[1,2,3,4,5,6,7], "hour":9, "minute":0, "durationMinutes":60],
                            "queryParameters":["participantID":"sona", "studyID":"s", "surveyID":"q", "occurrenceDate":"d", "callbackURL":"c"],
                            "questions":[]]]
        root["reminders"] = []
        let survey = try decode(root).surveys[0]
        XCTAssertEqual(survey.name, "Legacy"); XCTAssertEqual(survey.presentationMode, .externalBrowser)
        XCTAssertEqual(survey.schedule.pattern, .daily); XCTAssertEqual(survey.availabilityWindow.closesMinutesAfter, 60)
        let url = try SurveyURLBuilder.build(baseURL: survey.url, studyID: "study", surveyID: "legacy", occurrenceID: "occ", callbackEnabled: true)
        XCTAssertFalse(url.absoluteString.contains("sona"))
    }

    func testInvalidSurveyDefinitionsAreRejected() throws {
        let changes: [(inout [String:Any]) -> Void] = [
            { self.mutateSurvey(&$0) { $0["id"] = "" } },
            { self.mutateSurvey(&$0) { $0["url"] = "http://example.edu" } },
            { self.mutateSurvey(&$0) { var w = $0["availabilityWindow"] as! [String:Any]; w["opensMinutesBefore"] = -1; $0["availabilityWindow"] = w } },
            { self.mutateSurvey(&$0) { var s = $0["schedule"] as! [String:Any]; s["weekdays"] = []; s["pattern"] = "selectedWeekdays"; $0["schedule"] = s } },
            { self.mutateSurvey(&$0) { var s = $0["schedule"] as! [String:Any]; s["hour"] = 25; $0["schedule"] = s } }
        ]
        for change in changes { var root = try json("SleepStudy"); change(&root); XCTAssertThrowsError(try validator.validate(decode(root))) }
    }

    // Existing surveys (bundled fixtures predate this field) must decode with the auto-notification
    // opted out by default, not silently start notifying just because the feature shipped.
    func testSendNotificationOnOpenDefaultsToFalseWhenAbsent() throws {
        let survey = try fixture("SleepStudy").surveys[0]
        XCTAssertFalse(survey.sendNotificationOnOpen)
        XCTAssertNil(survey.notificationTitle)
        XCTAssertNil(survey.notificationBody)
    }

    func testSendNotificationOnOpenDecodesAndRoundTripsWhenPresent() throws {
        var root = try json("SleepStudy")
        mutateSurvey(&root) {
            $0["sendNotificationOnOpen"] = true
            $0["notificationTitle"] = "Time for your check-in"
            $0["notificationBody"] = "It only takes a minute."
        }
        let survey = try decode(root).surveys[0]
        XCTAssertTrue(survey.sendNotificationOnOpen)
        XCTAssertEqual(survey.notificationTitle, "Time for your check-in")
        XCTAssertEqual(survey.notificationBody, "It only takes a minute.")

        let reencoded = try JSONDecoder().decode(StudyConfiguration.self, from: JSONEncoder().encode(decode(root)))
        XCTAssertEqual(reencoded.surveys[0], survey)
    }

    func testFutureVersionRejected() throws {
        var root = try json("SleepStudy"); root["schemaVersion"] = 99
        XCTAssertThrowsError(try validator.validate(decode(root))) { XCTAssertEqual($0 as? StudyConfigurationError, .unsupportedSchema(99)) }
    }

    private var validator: StudyConfigurationValidator { .init(now: StudyConfigurationValidator.dateFormatter.date(from: "2026-07-24")!) }
    private func fixture(_ name: String) throws -> StudyConfiguration { try decode(json(name)) }
    private func json(_ name: String) throws -> [String:Any] { let u = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")); return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String:Any]) }
    private func decode(_ root: [String:Any]) throws -> StudyConfiguration { try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root)) }
    private func mutateSurvey(_ root: inout [String:Any], _ change: (inout [String:Any]) -> Void) { var values = root["surveys"] as! [[String:Any]]; change(&values[0]); root["surveys"] = values }
}
