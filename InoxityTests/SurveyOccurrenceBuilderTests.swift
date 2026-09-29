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

    // MARK: - The availability window is the only rule

    func testPromptExpirationIsIgnoredSurveyStaysAvailableForItsWholeWindow() throws {
        // The fixture's window opens 180 minutes before `scheduled` and closes 180 after. A 14-
        // minute promptExpirationMinutes used to mark it missed (and unopenable) long before its
        // notification at `scheduled` arrived.
        let study = try surveyWithPromptExpiration(14), zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = date(2026, 7, 24, 9, 0, zone)
        let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        // Filtered on the exact scheduledFor: the schedule is daily, so there's one occurrence per day.
        func status(at now: Date) throws -> SurveyOccurrenceStatus? {
            try builder.build(configuration: study, participant: participant, now: now, timeZone: zone).first { $0.scheduledFor == scheduled }?.status
        }
        XCTAssertEqual(try status(at: scheduled.addingTimeInterval(-179 * 60)), .available)
        XCTAssertEqual(try status(at: scheduled.addingTimeInterval(60)), .available)
        XCTAssertEqual(try status(at: scheduled.addingTimeInterval(179 * 60)), .available)
        XCTAssertEqual(try status(at: scheduled.addingTimeInterval(181 * 60)), .missed)
    }

    func testOpenedSurveyStaysOpenedUntilTheWindowCloses() throws {
        let study = try surveyWithPromptExpiration(14), zone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduled = date(2026, 7, 24, 9, 0, zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let id = try SurveyOccurrenceIdentifierFactory.identifier(studyID: study.identity.id, surveyID: "morning-checkin", occurrence: scheduled, calendar: calendar)
        var participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026, 7, 1, 0, 0, zone))
        participant.surveyOccurrenceStates[id] = .init(occurrenceID: id, surveyID: "morning-checkin", scheduledFor: scheduled, openedAt: scheduled, completedAt: nil)
        let opened = try builder.build(configuration: study, participant: participant, now: scheduled.addingTimeInterval(120 * 60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(opened?.status, .opened)
        let closed = try builder.build(configuration: study, participant: participant, now: scheduled.addingTimeInterval(181 * 60), timeZone: zone).first { $0.scheduledFor == scheduled }
        XCTAssertEqual(closed?.status, .missed)
    }

    func testNoOccurrencesAfterTheParticipantsLastDay() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SleepStudy", withExtension: "json"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var schedule = try XCTUnwrap(root["schedule"] as? [String: Any]); schedule["participantDurationDays"] = 3; root["schedule"] = schedule
        let config = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026,7,24,8,0,zone))
        let occurrences = try SurveyOccurrenceBuilder().build(configuration: config, participant: participant, now: date(2026,7,30,8,0,zone), timeZone: zone)
        XCTAssertFalse(occurrences.isEmpty)
        XCTAssertTrue(occurrences.allSatisfy { $0.scheduledFor < self.date(2026,7,27,0,0,zone) })
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
