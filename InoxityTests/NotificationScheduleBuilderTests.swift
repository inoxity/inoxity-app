import XCTest
@testable import Inoxity

final class NotificationScheduleBuilderTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    func testDailyAndWeekdaySchedulesAreBoundedAndUnique() throws {
        let now = date(2026, 7, 24, 8)
        let sleep = try fixture("SleepStudy"), activity = try fixture("ActivityStudy")
        let participant = ParticipantState(studyID: sleep.identity.id, enrollmentDate: date(2026, 7, 1))
        let daily = try NotificationScheduleBuilder().build(configuration: sleep, participant: participant, now: now, timeZone: zone)
        XCTAssertFalse(daily.requests.isEmpty); XCTAssertLessThanOrEqual(daily.requests.count, 60)
        XCTAssertEqual(Set(daily.requests.map(\.identifier)).count, daily.requests.count)
        let weekday = try NotificationScheduleBuilder().build(configuration: activity, participant: ParticipantState(studyID: activity.identity.id, enrollmentDate: date(2026,7,1)), now: now, timeZone: zone)
        XCTAssertTrue(weekday.requests.contains { $0.payload.reminderID == "evening-reminder" })
        XCTAssertTrue(weekday.requests.contains { $0.payload.reminderID == "weekly-message" })
    }

    func testOneTimePastAndBoundaryBehavior() throws {
        var root = try json("SleepStudy")
        mutateFirstReminder(&root) { reminder in
            reminder["schedule"] = ["pattern":"oneTime", "date":"2026-07-25", "hour":9, "minute":0, "weekdays":[]]
            reminder["activeStartDate"] = "2026-07-25"; reminder["activeEndDate"] = "2026-07-25"
        }
        let config = try decode(root), participant = ParticipantState(studyID: "sleep-cognition-v2", enrollmentDate: date(2026,7,24))
        XCTAssertEqual(try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026,7,24), timeZone: zone).requests.count, 1)
        XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026,7,26), timeZone: zone).requests.isEmpty)
    }

    func testEnrollmentAndParticipantCollectionBoundaries() throws {
        let config = try fixture("SleepStudy"), now = date(2026,7,24)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026,7,28,12))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone, participantCollectionStart: date(2026,7,29), participantCollectionEnd: date(2026,7,31,23))
        XCTAssertTrue(plan.requests.allSatisfy { $0.fireDate >= self.date(2026,7,29) && $0.fireDate <= self.date(2026,7,31,23) })
    }

    func testParticipantDurationStopsRemindersAfterTheParticipantsLastDay() throws {
        let config = try withParticipantDuration(3)
        // Enrollment start mode: days 1-3 are Jul 24-26, so nothing may fire from Jul 27 on.
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026,7,24,8))
        let active = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026,7,24,8), timeZone: zone)
        XCTAssertFalse(active.requests.isEmpty)
        XCTAssertTrue(active.requests.allSatisfy { $0.fireDate < self.date(2026,7,27) })
        let finished = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026,7,27,8), timeZone: zone)
        XCTAssertTrue(finished.requests.isEmpty, "reminders must stop once the participant's study is over")
    }

    func testChangingParticipantDurationChangesFingerprint() throws {
        let participant = ParticipantState(studyID: "sleep-cognition-v2", enrollmentDate: date(2026,7,24))
        let builder = NotificationScheduleBuilder()
        XCTAssertNotEqual(builder.fingerprint(configuration: try withParticipantDuration(3), participant: participant, timeZone: zone),
                          builder.fingerprint(configuration: try withParticipantDuration(14), participant: participant, timeZone: zone))
    }

    func testCompletedWithdrawnAndEmptyOrDisabledAreIneligible() throws {
        let config = try fixture("SleepStudy"), now = date(2026,7,24)
        for status in [ParticipationStatus.completed, .withdrawn] {
            let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026,7,1), participationStatus: status)
            XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone).requests.isEmpty)
        }
        var root = try json("SleepStudy"); root["status"] = ["state":"inactive", "message":"Closed"]
        let inactive = try decode(root)
        XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: inactive, participant: .init(studyID: inactive.identity.id, enrollmentDate: date(2026,7,1)), now: now, timeZone: zone).requests.isEmpty)
        XCTAssertTrue(try NotificationScheduleBuilder().build(configuration: config, participant: .init(studyID: config.identity.id, enrollmentDate: date(2026,7,1)), now: date(2036,1,1), timeZone: zone).requests.isEmpty)
    }

    func testPolicyReportsTruncationAndRollingHorizon() throws {
        let config = try fixture("SleepStudy"), now = date(2026,7,24)
        let policy = NotificationSchedulingPolicy(rollingHorizonDays: 30, maximumPendingRequestsPerStudy: 5, replenishmentThresholdDays: 7)
        let plan = try NotificationScheduleBuilder(policy: policy).build(configuration: config, participant: .init(studyID: config.identity.id, enrollmentDate: date(2026,7,1)), now: now, timeZone: zone)
        XCTAssertEqual(plan.scheduledOccurrenceCount, 5); XCTAssertTrue(plan.wasTruncated)
        XCTAssertEqual(plan.omittedOccurrenceCount, plan.generatedOccurrenceCount - 5)
        XCTAssertTrue(plan.requests.allSatisfy { $0.fireDate <= self.date(2026,8,24) })
    }

    func testDaylightSavingUsesLocalWallClock() throws {
        let config = try fixture("SleepStudy")
        let now = date(2026,10,31)
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: .init(studyID: config.identity.id, enrollmentDate: date(2026,10,1)), now: now, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        XCTAssertTrue(plan.requests.allSatisfy { calendar.component(.hour, from: $0.fireDate) == 9 })
    }

    func testWakeAndBedAnchoredSchedulesUseParticipantSleepTimes() throws {
        var root = try json("SleepStudy")
        root["schemaVersion"] = 6
        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your schedule", "wakeLabel": "Wake time", "bedLabel": "Bed time"]
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["schedule"] = ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "wakeTime", "offsetMinutes": 480]
        root["surveys"] = surveys
        var reminders = root["reminders"] as! [[String: Any]]
        reminders.append([
            "id": "bedtime-reminder", "title": "Bedtime Reminder", "body": "Don’t forget to prep for tonight.",
            "enabled": true, "kind": "message", "surveyID": NSNull(),
            "schedule": ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "bedTime", "offsetMinutes": -90],
            "destination": "home", "activeStartDate": "2025-01-01", "activeEndDate": "2035-12-31"
        ])
        root["reminders"] = reminders
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1), wakeTimeMinutes: 7 * 60, bedTimeMinutes: 23 * 60)
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone

        let morning = try XCTUnwrap(plan.requests.first { $0.payload.reminderID == "morning-reminder" })
        XCTAssertEqual(calendar.component(.hour, from: morning.fireDate), 15) // wake 07:00 + 8h
        XCTAssertEqual(calendar.component(.minute, from: morning.fireDate), 0)

        let bedtime = try XCTUnwrap(plan.requests.first { $0.payload.reminderID == "bedtime-reminder" })
        XCTAssertEqual(calendar.component(.hour, from: bedtime.fireDate), 21) // bed 23:00 - 90min = 21:30
        XCTAssertEqual(calendar.component(.minute, from: bedtime.fireDate), 30)
    }

    func testAnchoredScheduleProducesNoOccurrencesWithoutSleepScheduleSet() throws {
        var root = try json("SleepStudy")
        root["schemaVersion"] = 6
        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your schedule", "wakeLabel": "Wake time", "bedLabel": "Bed time"]
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["schedule"] = ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "wakeTime", "offsetMinutes": 480]
        root["surveys"] = surveys
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1)) // wake/bed time not yet set
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        XCTAssertFalse(plan.requests.contains { $0.payload.reminderID == "morning-reminder" })
    }

    // MARK: - randomWindow EMA scheduling (see NotificationScheduleBuilder.randomWindowOccurrences)

    private func randomWindowReminder(windowCount: Int, windowStartHour: Int, windowLengthHours: Int) -> [String: Any] {
        [
            "id": "ema-prompt", "title": "Quick check-in", "body": "Tap to answer.",
            "enabled": true, "kind": "message",
            "schedule": [
                "pattern": "randomWindow", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [Int](),
                "anchor": "clockTime", "offsetMinutes": NSNull(),
                "windowCount": windowCount, "windowStartHour": windowStartHour, "windowLengthHours": windowLengthHours,
            ] as [String: Any],
            "destination": "home",
        ]
    }

    func testRandomWindowProducesOneOccurrencePerWindowPerDayWithinRange() throws {
        var root = try json("SleepStudy")
        root["reminders"] = [randomWindowReminder(windowCount: 3, windowStartHour: 8, windowLengthHours: 4)]
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let now = date(2026, 7, 24, 8)
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.startOfDay(for: now), nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let todaysFires = plan.requests.filter { $0.fireDate >= day && $0.fireDate < nextDay }
        XCTAssertEqual(todaysFires.count, 3) // one per window
        for fire in todaysFires {
            XCTAssertTrue((8..<20).contains(calendar.component(.hour, from: fire.fireDate))) // 3 windows × 4h from hour 8
        }
    }

    // Determinism requirement: re-running build() for the same (studyID, reminderID, day) must
    // reproduce the exact same fire times, or reconciliation (on every app foreground) would
    // reshuffle an already-randomized day's schedule.
    func testRandomWindowIsDeterministicAcrossRepeatedBuilds() throws {
        var root = try json("SleepStudy")
        root["reminders"] = [randomWindowReminder(windowCount: 3, windowStartHour: 8, windowLengthHours: 4)]
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let now = date(2026, 7, 24, 8)
        let first = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone)
        let second = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone)
        XCTAssertEqual(first.requests.map(\.fireDate), second.requests.map(\.fireDate))
        XCTAssertEqual(first.requests.map(\.identifier), second.requests.map(\.identifier))
    }

    // A stuck/non-random generator would produce the exact same clock time every day; a working
    // one should vary across different days for the same reminder.
    func testRandomWindowDifferentDaysDiverge() throws {
        var root = try json("SleepStudy")
        root["reminders"] = [randomWindowReminder(windowCount: 1, windowStartHour: 0, windowLengthHours: 24)]
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let minutesOfDay = Set(plan.requests.map { calendar.component(.hour, from: $0.fireDate) * 60 + calendar.component(.minute, from: $0.fireDate) })
        XCTAssertGreaterThan(minutesOfDay.count, 1, "Expected different days to randomize to different times, not all the same clock time")
    }

    // Regression test for the dormant seed-key bug: resolving a SURVEY's own schedule (to
    // announce it via a linked reminder's notification) must seed RandomWindowScheduling
    // identically to what SurveyOccurrenceBuilder itself computes for that survey — seeding by
    // reminder.id instead of survey.id (the original bug) would make the notification's fire
    // time, and the occurrence ID embedded in its payload, disagree with the survey's actual
    // occurrence, producing an unknownOccurrence error the moment the participant taps it.
    func testRandomWindowSurveyAndItsLinkedReminderAgreeOnTheSameOccurrence() throws {
        var root = try json("SleepStudy")
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["schedule"] = [
            "pattern": "randomWindow", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [Int](),
            "anchor": "clockTime", "offsetMinutes": NSNull(),
            "windowCount": 2, "windowStartHour": 8, "windowLengthHours": 4,
        ]
        root["surveys"] = surveys
        // "morning-reminder" (already in the fixture) targets "morning-checkin" via
        // notifyMinutesBefore — the schemaVersion >= 4 survey-linked-reminder path.
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let now = date(2026, 7, 24, 6)

        let notificationPlan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: now, timeZone: zone)
        let surveyOccurrences = try SurveyOccurrenceBuilder(policy: .init(historyDays: 1, futureDays: 35))
            .build(configuration: config, participant: participant, now: now, timeZone: zone)

        let linkedNotifications = notificationPlan.requests.filter { $0.payload.reminderID == "morning-reminder" }
        XCTAssertFalse(linkedNotifications.isEmpty)
        let surveyOccurrenceIDs = Set(surveyOccurrences.map(\.id))
        for notification in linkedNotifications {
            XCTAssertTrue(surveyOccurrenceIDs.contains(notification.payload.occurrenceID),
                "Notification \(notification.identifier) references occurrence \(notification.payload.occurrenceID), which SurveyOccurrenceBuilder never generated")
        }
    }

    // Regression guard for the bug where `anchor`/`offsetMinutes` had inline default values
    // (`= nil`) on `let` properties, which Swift's synthesized Codable silently never decodes
    // regardless of what's in the JSON. If that pattern ever reappears, this round-trip fails.
    func testAnchorAndOffsetMinutesRoundTripThroughCodable() throws {
        let schedule = ReminderScheduleConfiguration(pattern: .daily, date: nil, hour: 0, minute: 0,
                                                      weekdays: [], anchor: .wakeTime, offsetMinutes: 480)
        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(ReminderScheduleConfiguration.self, from: data)
        XCTAssertEqual(decoded.anchor, .wakeTime)
        XCTAssertEqual(decoded.offsetMinutes, 480)
        XCTAssertEqual(decoded, schedule)
    }

    // Reminders must fire at the participant's own current local time, not a fixed study zone
    // — the same wake-anchored schedule should produce a different absolute instant (not just a
    // different local hour) depending on which timezone is passed in.
    func testWakeAnchoredScheduleUsesThePassedInTimeZoneNotAFixedOne() throws {
        var root = try json("SleepStudy")
        root["schemaVersion"] = 6
        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your schedule", "wakeLabel": "Wake time", "bedLabel": "Bed time"]
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["schedule"] = ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "wakeTime", "offsetMinutes": 480]
        root["surveys"] = surveys
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1), wakeTimeMinutes: 7 * 60, bedTimeMinutes: 23 * 60)
        let pacific = TimeZone(identifier: "America/Los_Angeles")!, eastern = TimeZone(identifier: "America/New_York")!
        let pacificPlan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: pacific)
        let easternPlan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: eastern)
        let pacificFire = try XCTUnwrap(pacificPlan.requests.first { $0.payload.reminderID == "morning-reminder" }).fireDate
        let easternFire = try XCTUnwrap(easternPlan.requests.first { $0.payload.reminderID == "morning-reminder" }).fireDate
        // Same local wall-clock hour (15:00) in both zones, but different absolute instants —
        // proves the anchor is resolved live against whatever zone is passed in, not baked in.
        XCTAssertNotEqual(pacificFire, easternFire)
        XCTAssertEqual(easternFire.timeIntervalSince(pacificFire), -3 * 3600, accuracy: 1)
    }

    // `sendNotificationOnOpen` with no linked ReminderConfiguration at all should still produce a
    // notification, scheduled at the survey's own schedule times, using the synthesized
    // "__survey_open__.<surveyID>" reminderID and a name-derived default title/body.
    func testSendNotificationOnOpenGeneratesNotificationWithoutAnyReminder() throws {
        var root = try json("SleepStudy")
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["sendNotificationOnOpen"] = true
        root["surveys"] = surveys
        root["reminders"] = [] // no ReminderConfiguration linked to this survey at all
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        let request = try XCTUnwrap(plan.requests.first { $0.payload.reminderID == "__survey_open__.morning-checkin" })
        XCTAssertEqual(request.payload.notificationKind, .survey)
        XCTAssertEqual(request.payload.surveyID, "morning-checkin")
        XCTAssertEqual(request.payload.destination, .surveys)
        XCTAssertEqual(request.title, "Morning check-in is available")
        XCTAssertEqual(request.body, "Tap to open it now.")
    }

    // Custom `notificationTitle`/`notificationBody` should override the name-derived default.
    func testSendNotificationOnOpenUsesCustomCopyWhenProvided() throws {
        var root = try json("SleepStudy")
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["sendNotificationOnOpen"] = true
        surveys[0]["notificationTitle"] = "Time for your check-in"
        surveys[0]["notificationBody"] = "It only takes a minute."
        root["surveys"] = surveys
        root["reminders"] = []
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        let request = try XCTUnwrap(plan.requests.first { $0.payload.reminderID == "__survey_open__.morning-checkin" })
        XCTAssertEqual(request.title, "Time for your check-in")
        XCTAssertEqual(request.body, "It only takes a minute.")
    }

    // A manually configured kind == .survey reminder already targeting this survey should win —
    // the auto-notification must not also fire, which would double-notify the same occurrence.
    func testExplicitSurveyReminderSuppressesAutoNotification() throws {
        var root = try json("SleepStudy") // already has "morning-reminder" linked to morning-checkin
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["sendNotificationOnOpen"] = true
        root["surveys"] = surveys
        let config = try decode(root)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        XCTAssertFalse(plan.requests.contains { $0.payload.reminderID == "__survey_open__.morning-checkin" })
        // The explicit reminder's own notification still fires as before, exactly once per occurrence.
        let occurrenceIDs = plan.requests.filter { $0.payload.reminderID == "morning-reminder" }.map(\.payload.occurrenceID)
        XCTAssertEqual(occurrenceIDs.count, Set(occurrenceIDs).count)
    }

    // Default (absent from JSON) must be `false` — existing surveys shouldn't silently start
    // notifying just because this feature shipped.
    func testSendNotificationOnOpenDefaultsToFalse() throws {
        var root = try json("SleepStudy")
        root["reminders"] = [] // remove the only reminder so no notification would come from elsewhere
        let config = try decode(root)
        XCTAssertFalse(config.surveys[0].sendNotificationOnOpen)
        let participant = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1))
        let plan = try NotificationScheduleBuilder().build(configuration: config, participant: participant, now: date(2026, 7, 24, 8), timeZone: zone)
        XCTAssertTrue(plan.requests.isEmpty)
    }

    func testFingerprintChangesWhenSendNotificationOnOpenToggles() throws {
        var root = try json("SleepStudy")
        root["reminders"] = []
        let off = try decode(root)
        var surveys = root["surveys"] as! [[String: Any]]
        surveys[0]["sendNotificationOnOpen"] = true
        root["surveys"] = surveys
        let on = try decode(root)
        let builder = NotificationScheduleBuilder()
        let participant = ParticipantState(studyID: off.identity.id, enrollmentDate: date(2026, 7, 1))
        XCTAssertNotEqual(builder.fingerprint(configuration: off, participant: participant, timeZone: zone),
                          builder.fingerprint(configuration: on, participant: participant, timeZone: zone))
    }

    func testFingerprintChangesWhenSleepScheduleChanges() throws {
        let config = try fixture("SleepStudy")
        let builder = NotificationScheduleBuilder()
        let a = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1), wakeTimeMinutes: 420, bedTimeMinutes: 1380)
        let b = ParticipantState(studyID: config.identity.id, enrollmentDate: date(2026, 7, 1), wakeTimeMinutes: 360, bedTimeMinutes: 1320)
        XCTAssertNotEqual(builder.fingerprint(configuration: config, participant: a, timeZone: zone),
                          builder.fingerprint(configuration: config, participant: b, timeZone: zone))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c.date(from: .init(year: year, month: month, day: day, hour: hour))! }
    private func fixture(_ name: String) throws -> StudyConfiguration { try decode(json(name)) }
    private func withParticipantDuration(_ days: Int) throws -> StudyConfiguration {
        var root = try json("SleepStudy"); var schedule = try XCTUnwrap(root["schedule"] as? [String: Any])
        schedule["participantDurationDays"] = days; root["schedule"] = schedule
        return try decode(root)
    }
    private func json(_ name: String) throws -> [String:Any] { let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")); return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any]) }
    private func decode(_ root: [String:Any]) throws -> StudyConfiguration { try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root)) }
    private func mutateFirstReminder(_ root: inout [String:Any], _ mutation: (inout [String:Any])->Void) { var reminders = root["reminders"] as! [[String:Any]]; mutation(&reminders[0]); root["reminders"] = reminders }
}
