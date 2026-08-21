import XCTest
@testable import Inoxity

final class SurveyOccurrenceIdentifierFactoryTests: XCTestCase {
    func testDeterministicSafeAndIsolatedIdentifiers() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: .init(year: 2026, month: 7, day: 25, hour: 9))!
        let first = try SurveyOccurrenceIdentifierFactory.identifier(studyID: "sleep-cognition-v2", surveyID: "morning-checkin", occurrence: date, calendar: calendar)
        XCTAssertEqual(first, "inoxity.sleep-cognition-v2.morning-checkin.20260725T0900")
        XCTAssertEqual(first, try SurveyOccurrenceIdentifierFactory.identifier(studyID: "sleep-cognition-v2", surveyID: "morning-checkin", occurrence: date, calendar: calendar))
        XCTAssertNotEqual(first, try SurveyOccurrenceIdentifierFactory.identifier(studyID: "other-study", surveyID: "morning-checkin", occurrence: date, calendar: calendar))
        XCTAssertFalse(first.contains("SONA")); XCTAssertThrowsError(try SurveyOccurrenceIdentifierFactory.identifier(studyID: "Bad.ID", surveyID: "survey", occurrence: date, calendar: calendar))
    }
}
