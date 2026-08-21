import XCTest
@testable import Inoxity

final class NotificationIdentifierFactoryTests: XCTestCase {
    func testIdentifiersAreDeterministicAndScoped() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: .init(year: 2026, month: 8, day: 1, hour: 9))!
        let first = NotificationIdentifierFactory.identifier(studyID: "study-a", reminderID: "morning", occurrence: date, calendar: calendar)
        XCTAssertEqual(first, NotificationIdentifierFactory.identifier(studyID: "study-a", reminderID: "morning", occurrence: date, calendar: calendar))
        XCTAssertNotEqual(first, NotificationIdentifierFactory.identifier(studyID: "study-b", reminderID: "morning", occurrence: date, calendar: calendar))
        XCTAssertNotEqual(first, NotificationIdentifierFactory.identifier(studyID: "study-a", reminderID: "evening", occurrence: date, calendar: calendar))
        XCTAssertFalse(first.contains("SONA")); XCTAssertFalse(first.contains("participant"))
        XCTAssertTrue(NotificationIdentifierFactory.owns(first, studyID: "study-a"))
    }
}
