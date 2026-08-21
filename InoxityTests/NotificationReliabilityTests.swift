import XCTest
import UserNotifications
@testable import Inoxity

@MainActor
final class NotificationReliabilityTests: XCTestCase {
    func testForegroundPresentationAndAuthorizationFalseResult() {
        let options = NotificationService.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner)); XCTAssertTrue(options.contains(.list)); XCTAssertTrue(options.contains(.sound))
        XCTAssertEqual(NotificationService.permissionResult(granted: false), .attentionNeeded("Notifications were not enabled. You can continue without them."))
    }

    // NotificationScheduleBuilder deliberately never reads the study's fixed `schedule.timeZone`
    // (see its doc comment) — wall-clock times always follow the participant's own current local
    // zone, via the injectable `timeZone:` override, so reminders follow them if they travel.
    // This pins that contract down directly rather than via `schedule.timeZone`, which the
    // builder ignores.
    func testInjectedTimeZoneDrivesRequestsAndFingerprint() throws {
        let study = try fixture("SleepStudy")
        let participant = ParticipantState(studyID: study.identity.id, enrollmentDate: Date(timeIntervalSince1970: 1_700_000_000))
        let now = Date(timeIntervalSince1970: 1_800_000_000), builder = NotificationScheduleBuilder()
        let laPlan = try builder.build(configuration: study, participant: participant, now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let nyPlan = try builder.build(configuration: study, participant: participant, now: now, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(laPlan.requests.first?.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(nyPlan.requests.first?.timeZoneIdentifier, "America/New_York")
        XCTAssertNotEqual(laPlan.fingerprint, nyPlan.fingerprint)
        XCTAssertNotEqual(laPlan.requests.first?.fireDate, nyPlan.requests.first?.fireDate)
    }

    func testUnsupportedSchemaAndWithdrawnParticipantScheduleNothing() throws {
        var root = try json("SleepStudy"); root["schemaVersion"] = 99
        let unsupported = try decode(root), enrolled = ParticipantState(studyID: unsupported.identity.id)
        XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: unsupported, participant: enrolled, now: Date()).requests.isEmpty)
        let study = try fixture("SleepStudy"), withdrawn = ParticipantState(studyID: study.identity.id, participationStatus: .withdrawn)
        XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: study, participant: withdrawn, now: Date()).requests.isEmpty)
    }

    func testDebugTestNotificationUsesDedicatedAction() async throws {
        let mock = MockNotificationService()
#if DEBUG
        try await mock.scheduleTestNotification(after: 10)
        XCTAssertEqual(mock.testNotificationDelays, [10])
#endif
    }

    private func fixture(_ name: String) throws -> StudyConfiguration { try decode(json(name)) }
    private func json(_ name: String) throws -> [String: Any] { let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")); return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
    private func decode(_ root: [String: Any]) throws -> StudyConfiguration { try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root)) }
}
