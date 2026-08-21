import XCTest
@testable import Inoxity

final class SurveyNotificationRoutingIntegrationTests: XCTestCase {
    func testSurveyReminderDateAndPayloadDeriveFromSurveyOccurrence() throws {
        let study = try fixture(), zone = TimeZone(identifier: "America/Los_Angeles")!, now = date(2026,7,24,8,0,zone)
        let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: date(2026,7,1,0,0,zone))
        let plan = try NotificationScheduleBuilder(policy: .init(rollingHorizonDays: 2, maximumPendingRequestsPerStudy: 60, replenishmentThresholdDays: 1)).build(configuration: study, participant: participant, now: now, timeZone: zone)
        let request = try XCTUnwrap(plan.requests.first)
        XCTAssertEqual(Calendar.current.component(.minute, from: request.fireDate), 0)
        XCTAssertTrue(request.payload.occurrenceID.hasPrefix("inoxity.sleep-cognition-v2.morning-checkin."))
    }
    private func fixture() throws -> StudyConfiguration { let u = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SleepStudy", withExtension: "json")); return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: u)) }
    private func date(_ y:Int,_ m:Int,_ d:Int,_ h:Int,_ min:Int,_ z:TimeZone)->Date { var c=Calendar(identifier:.gregorian); c.timeZone=z; return c.date(from:.init(year:y,month:m,day:d,hour:h,minute:min))! }
}
