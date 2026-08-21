import XCTest
@testable import Inoxity

final class NotificationConfigurationTests: XCTestCase {
    func testBundledSchemaThreeMessageAndSurveyRemindersAreValid() throws {
        let sleep = try fixture("SleepStudy"), activity = try fixture("ActivityStudy")
        XCTAssertEqual(sleep.schemaVersion, 5); XCTAssertEqual(activity.schemaVersion, 5)
        XCTAssertTrue(sleep.reminders.contains { $0.kind == .survey })
        XCTAssertTrue(activity.reminders.contains { $0.kind == .message })
        XCTAssertNoThrow(try validator.validate(sleep)); XCTAssertNoThrow(try validator.validate(activity))
    }

    func testSchemaTwoFlatReminderMigratesInMemory() throws {
        var root = try json("SleepStudy")
        root["schemaVersion"] = 2; root.removeValue(forKey: "notifications")
        var reminders = try XCTUnwrap(root["reminders"] as? [[String: Any]])
        reminders[0].removeValue(forKey: "schedule"); reminders[0].removeValue(forKey: "destination")
        reminders[0]["hour"] = 9; reminders[0]["minute"] = 0; reminders[0]["weekdays"] = [1,2,3,4,5,6,7]
        root["reminders"] = reminders
        let decoded = try decode(root)
        XCTAssertEqual(decoded.reminders[0].schedule?.pattern, .daily)
        XCTAssertEqual(decoded.reminders[0].destination, .surveys)
    }

    func testInvalidReminderDefinitionsAreRejected() throws {
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { try self.mutateReminder(&$0) { $0["id"] = "" } },
            { root in var r = try XCTUnwrap(root["reminders"] as? [[String: Any]]); r.append(r[0]); root["reminders"] = r },
            { try self.mutateSchedule(&$0) { $0["hour"] = 25 } },
            { try self.mutateSchedule(&$0) { $0["weekdays"] = [0,8]; $0["pattern"] = "selectedWeekdays" } },
            { try self.mutateReminder(&$0) { $0["surveyID"] = NSNull() } },
            { try self.mutateReminder(&$0) { $0["surveyID"] = "unknown" } },
            { try self.mutateSchedule(&$0) { $0["pattern"] = "oneTime"; $0["date"] = NSNull() } }
        ]
        for mutation in mutations {
            var root = try json("SleepStudy")
            root["schemaVersion"] = 3
            var reminders = try XCTUnwrap(root["reminders"] as? [[String: Any]])
            reminders[0]["schedule"] = ["pattern":"daily", "date":NSNull(), "hour":9, "minute":0, "weekdays":[]]
            reminders[0].removeValue(forKey: "notifyMinutesBefore")
            root["reminders"] = reminders
            try mutation(&root)
            XCTAssertThrowsError(try validator.validate(decode(root)))
        }
    }

    func testInvalidKindFailsDecodingAndFutureSchemaIsRejected() throws {
        var root = try json("SleepStudy"); try mutateReminder(&root) { $0["kind"] = "unknown" }
        XCTAssertThrowsError(try decode(root))
        root = try json("SleepStudy"); root["schemaVersion"] = 99
        XCTAssertThrowsError(try validator.validate(decode(root))) { XCTAssertEqual($0 as? StudyConfigurationError, .unsupportedSchema(99)) }
    }

    private var validator: StudyConfigurationValidator { .init(now: StudyConfigurationValidator.dateFormatter.date(from: "2026-07-24")!) }
    private func fixture(_ name: String) throws -> StudyConfiguration { try decode(json(name)) }
    private func json(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func decode(_ root: [String: Any]) throws -> StudyConfiguration { try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root)) }
    private func mutateReminder(_ root: inout [String: Any], _ change: (inout [String: Any]) -> Void) throws {
        var reminders = try XCTUnwrap(root["reminders"] as? [[String: Any]]); change(&reminders[0]); root["reminders"] = reminders
    }
    private func mutateSchedule(_ root: inout [String: Any], _ change: (inout [String: Any]) -> Void) throws {
        try mutateReminder(&root) { reminder in var schedule = reminder["schedule"] as! [String: Any]; change(&schedule); reminder["schedule"] = schedule }
    }
}
