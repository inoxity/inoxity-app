import XCTest
@testable import Inoxity

final class SurveyCompletionValidatorTests: XCTestCase {
    func testTimelineAndGraceRules() {
        let scheduled = Date(timeIntervalSince1970: 10_000), opens = scheduled.addingTimeInterval(-1_800), closes = scheduled.addingTimeInterval(1_800)
        let occurrence = SurveyOccurrence(id: "inoxity.study.survey.19700101T0246", studyID: "study", surveyID: "survey", name: "Survey", summary: "Summary", instructions: nil, privacyText: nil, presentationMode: .externalBrowser, scheduledFor: scheduled, opensAt: opens, closesAt: closes, openedAt: nil, completedAt: nil, status: .available)
        func record(opened: Date?, scheduledFor: Date = scheduled) -> PersistedSurveyOccurrenceState { .init(occurrenceID: occurrence.id, surveyID: occurrence.surveyID, scheduledFor: scheduledFor, openedAt: opened, completedAt: nil) }
        XCTAssertNoThrow(try SurveyCompletionValidator.validate(record: record(opened: scheduled), occurrence: occurrence, receivedAt: closes.addingTimeInterval(3_600), policy: .default))
        XCTAssertThrowsError(try SurveyCompletionValidator.validate(record: record(opened: opens.addingTimeInterval(-1)), occurrence: occurrence, receivedAt: scheduled, policy: .default))
        XCTAssertThrowsError(try SurveyCompletionValidator.validate(record: record(opened: closes.addingTimeInterval(1)), occurrence: occurrence, receivedAt: closes.addingTimeInterval(2), policy: .default))
        XCTAssertThrowsError(try SurveyCompletionValidator.validate(record: record(opened: scheduled), occurrence: occurrence, receivedAt: scheduled.addingTimeInterval(-1), policy: .default))
        XCTAssertThrowsError(try SurveyCompletionValidator.validate(record: record(opened: scheduled), occurrence: occurrence, receivedAt: closes.addingTimeInterval(3_601), policy: .default))
        XCTAssertThrowsError(try SurveyCompletionValidator.validate(record: record(opened: scheduled, scheduledFor: scheduled.addingTimeInterval(60)), occurrence: occurrence, receivedAt: scheduled, policy: .default))
    }
}
