import XCTest
@testable import Inoxity

final class SurveyOccurrenceBuilderTests: XCTestCase {
    func testDailyGenerationAndAvailabilityStates() throws {
        let study = try fixture("SleepStudy"), zone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(2026, 7, 24, 9, 30, zone), participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        let values = try SurveyOccurrenceBuilder(policy: .init(historyDays: 1, futureDays: 1)).build(configuration: study, participant: participant, now: now, timeZone: zone)
        XCTAssertEqual(values.filter { $0.status == .available }.count, 1)
        XCTAssertTrue(values.contains { $0.status == .upcoming }); XCTAssertFalse(Set(values.map(\.id)).count != values.count)
    }

    func testOpenedCompletedAndCompletionPrecedesMissed() throws {
        let study = try fixture("SleepStudy"), zone = TimeZone(identifier: "America/Los_Angeles")!, scheduled = date(2026, 7, 24, 9, 0, zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let id = try SurveyOccurrenceIdentifierFactory.identifier(studyID: study.identity.id, surveyID: "morning-checkin", occurrence: scheduled, calendar: calendar)
        var participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        participant.surveyOccurrenceStates[id] = .init(occurrenceID: id, surveyID: "morning-checkin", scheduledFor: scheduled, openedAt: date(2026,7,24,9,0,zone), completedAt: nil)
        var value = try builder.build(configuration: study, participant: participant, now: date(2026,7,24,10,0,zone), timeZone: zone).first { $0.id == id }
        XCTAssertEqual(value?.status, .opened)
        participant.surveyOccurrenceStates[id]?.completedAt = date(2026,7,24,10,5,zone)
        value = try builder.build(configuration: study, participant: participant, now: date(2026,7,25,10,0,zone), timeZone: zone).first { $0.id == id }
        XCTAssertEqual(value?.status, .completed)
    }

    func testWithdrawnExcludedFromActionAndPersistedMismatchFails() throws {
        let study = try fixture("SleepStudy"), zone = TimeZone(identifier: "America/Los_Angeles")!
        var participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026,7,1,0,0,zone), participationStatus: .withdrawn)
        let values = try builder.build(configuration: study, participant: participant, now: date(2026,7,24,9,0,zone), timeZone: zone)
        XCTAssertTrue(values.allSatisfy { $0.status == .unavailable })
        if let occurrence = values.first {
            participant.surveyOccurrenceStates[occurrence.id] = .init(occurrenceID: occurrence.id, surveyID: occurrence.surveyID, scheduledFor: occurrence.scheduledFor.addingTimeInterval(60), openedAt: nil, completedAt: nil)
            XCTAssertThrowsError(try builder.build(configuration: study, participant: participant, now: date(2026,7,24,9,0,zone), timeZone: zone))
        }
    }

    func testDSTTransitionsRemainUnique() throws {
        let study = try fixture("SleepStudy"), zone = TimeZone(identifier: "America/Los_Angeles")!
        for now in [date(2026,3,8,9,0,zone), date(2026,11,1,9,0,zone)] {
            let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026,1,1,0,0,zone))
            let values = try builder.build(configuration: study, participant: participant, now: now, timeZone: zone)
            XCTAssertEqual(Set(values.map(\.id)).count, values.count)
        }
    }

    // MARK: - promptExpirationMinutes (soft "missed" deadline, distinct from the hard
    // availabilityWindow.closesMinutesAfter cutoff — see SurveyOccurrenceBuilder.status)

    func testMissedViaPromptExpirationWhenNeverOpened() throws {
        let study = try surveyWithPromptExpiration(30), zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = date(2026, 7, 24, 9, 0, zone)
        let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        // Survey opens 180 minutes before `scheduled` (per the fixture's availabilityWindow) — the
        // 30-minute expiration counts from that opening moment, not from `scheduled` itself.
        let opens = scheduled.addingTimeInterval(-180 * 60)
        // Filtered on the exact scheduledFor, not just surveyID — the fixture's schedule is
        // "daily", so build() returns one occurrence per day in the window and `.first` alone
        // could pick a different day's occurrence than the one under test.
        let justBeforeDeadline = try builder.build(configuration: study, participant: participant, now: opens.addingTimeInterval(29 * 60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(justBeforeDeadline?.status, .available)
        let justAfterDeadline = try builder.build(configuration: study, participant: participant, now: opens.addingTimeInterval(31 * 60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(justAfterDeadline?.status, .missed)
    }

    func testOpenedBeforeDeadlineNeverReadsAsMissed() throws {
        let study = try surveyWithPromptExpiration(30), zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = date(2026, 7, 24, 9, 0, zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let id = try SurveyOccurrenceIdentifierFactory.identifier(studyID: study.identity.id, surveyID: "morning-checkin", occurrence: scheduled, calendar: calendar)
        var participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        let opens = scheduled.addingTimeInterval(-180 * 60)
        // Opened at minute 10 — well before the 30-minute soft deadline. Doesn't matter whether
        // that came from tapping a notification or the Surveys tab directly; both stamp openedAt
        // identically (AppState.persistSurveyOpened), so this is representative of either.
        participant.surveyOccurrenceStates[id] = .init(occurrenceID: id, surveyID: "morning-checkin", scheduledFor: scheduled, openedAt: opens.addingTimeInterval(10 * 60), completedAt: nil)
        // Now well past the 30-minute soft deadline, but still well within the hard closing window.
        let value = try builder.build(configuration: study, participant: participant, now: opens.addingTimeInterval(60 * 60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(value?.status, .opened)
    }

    func testPromptExpirationNeverExtendsPastTheHardCloseDeadline() throws {
        // A generous 10,000-minute expiration must still be clamped to `closes`, not push the
        // deadline out past it.
        let study = try surveyWithPromptExpiration(10_000), zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = date(2026, 7, 24, 9, 0, zone)
        let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        // closesMinutesAfter is 180 in the fixture — well past that, unopened, must already be missed.
        let closes = scheduled.addingTimeInterval(180 * 60)
        let value = try builder.build(configuration: study, participant: participant, now: closes.addingTimeInterval(60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(value?.status, .missed)
    }

    private func surveyWithPromptExpiration(_ minutes: Int) throws -> StudyConfiguration {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SleepStudy", withExtension: "json"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var surveys = try XCTUnwrap(root["surveys"] as? [[String: Any]])
        surveys[0]["promptExpirationMinutes"] = minutes
        root["surveys"] = surveys
        return try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
    }

    private let builder = SurveyOccurrenceBuilder(policy: .init(historyDays: 2, futureDays: 2))
    private func fixture(_ name: String) throws -> StudyConfiguration { let u = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")); return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: u)) }
    private func date(_ y:Int,_ m:Int,_ d:Int,_ h:Int,_ min:Int,_ z:TimeZone)->Date { var c=Calendar(identifier:.gregorian); c.timeZone=z; return c.date(from:.init(year:y,month:m,day:d,hour:h,minute:min))! }
}
