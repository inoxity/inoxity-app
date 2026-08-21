import XCTest
@testable import Inoxity

final class StudyConfigurationTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }
    private func provider(now: Date = StudyConfigurationValidator.dateFormatter.date(from: "2026-07-23")!) -> BundledStudyConfigurationProvider {
        BundledStudyConfigurationProvider(bundle: bundle, validator: .init(now: now))
    }

    func testNormalization() {
        XCTAssertEqual(StudyCodeNormalizer.normalize("  sleep01\n"), "SLEEP01")
        XCTAssertEqual(StudyCodeNormalizer.normalize("activity02"), "ACTIVITY02")
        XCTAssertEqual(StudyCodeNormalizer.normalize("   "), "")
    }

    func testProviderLooksUpBothStudiesAndTheyDiffer() async throws {
        let sleep = try await provider().configuration(for: " sleep01 ")
        let activity = try await provider().configuration(for: "activity02")
        XCTAssertEqual(sleep.identity.code, "SLEEP01")
        XCTAssertEqual(activity.identity.code, "ACTIVITY02")
        XCTAssertNotEqual(sleep.identity.displayName, activity.identity.displayName)
        XCTAssertNotEqual(sleep.participantID.label, activity.participantID.label)
        XCTAssertNotEqual(sleep.onboarding, activity.onboarding)
        XCTAssertNotEqual(sleep.features, activity.features)
        XCTAssertNotEqual(sleep.healthKit.identifiers, activity.healthKit.identifiers)
    }

    // Regression test for the class of bug documented on ReminderScheduleConfiguration's
    // anchor/offsetMinutes: a `let` property with an inline literal default silently never
    // decodes the real JSON value. includeCharacteristics avoids that (decodeIfPresent, no
    // inline default) — this exercises both the absent-key default and an explicit round trip.
    func testHealthKitIncludeCharacteristicsDefaultsFalseAndRoundTrips() throws {
        let base = try fixture("SleepStudy") // fixture has no includeCharacteristics key at all
        XCTAssertEqual(base.healthKit.includeCharacteristics, false)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        try set(&json, section: "healthKit", key: "includeCharacteristics", value: true)
        let opted = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(opted.healthKit.includeCharacteristics, true)
    }

    func testUnknownCode() async {
        do { _ = try await provider().configuration(for: "INVALID"); XCTFail("Expected unknown code") }
        catch { XCTAssertEqual(error as? StudyConfigurationError, .unknownCode) }
    }

    func testMalformedJSON() async {
        let p = BundledStudyConfigurationProvider(bundle: bundle, validator: .init(), resources: ["BAD": "MalformedStudy"])
        do { _ = try await p.configuration(for: "BAD"); XCTFail("Expected malformed configuration") }
        catch { XCTAssertEqual(error as? StudyConfigurationError, .malformedConfiguration) }
    }

    func testMissingBundledResource() async {
        let p = BundledStudyConfigurationProvider(bundle: bundle, validator: .init(), resources: ["MISSING": "DoesNotExist"])
        do { _ = try await p.configuration(for: "MISSING"); XCTFail("Expected missing resource") }
        catch { XCTAssertEqual(error as? StudyConfigurationError, .missingResource) }
    }

    func testValidationFailures() throws {
        let base = try fixture("SleepStudy")
        XCTAssertThrowsError(try validate(base, change: { $0["schemaVersion"] = 1 }), equals: .unsupportedSchema(1))
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "identity", key: "id", value: "") }), equals: .missingStudyID)
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "identity", key: "code", value: "") }), equals: .missingStudyCode)
        XCTAssertThrowsError(try validator.validate(base, expectedCode: "OTHER"), equals: .studyCodeMismatch)
        for status in ["paused", "inactive"] { XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "status", key: "state", value: status) })) }
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "schedule", key: "timeZone", value: "Mars/Olympus") }), equals: .invalidTimeZone)
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "schedule", key: "startDate", value: "2030-01-01"); try set(&$0, section: "schedule", key: "endDate", value: "2020-01-01") }), equals: .invalidDateRange)
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "schedule", key: "startDate", value: "2030-01-01"); try set(&$0, section: "schedule", key: "endDate", value: "2035-01-01") }), equals: .notStarted)
        XCTAssertThrowsError(try validate(base, change: { try duplicateNestedArray(in: &$0, section: "onboarding", key: "pages") }))
        XCTAssertThrowsError(try validate(base, change: { try duplicateArray(in: &$0, key: "surveys") }))
        XCTAssertThrowsError(try validate(base, change: { try duplicateArray(in: &$0, key: "reminders") }))
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "healthKit", key: "identifiers", value: ["unknownType"]) }), equals: .unsupportedHealthIdentifier("unknownType"))
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "support", key: "website", value: "not a URL") }))
        XCTAssertThrowsError(try validate(base, change: { try set(&$0, section: "completion", key: "redirectURL", value: "ftp://invalid.example") }))
        XCTAssertThrowsError(try validate(base, change: {
            try set(&$0, section: "features", key: "mediaUploadsEnabled", value: true)
            try set(&$0, section: "media", key: "enabled", value: true)
            try set(&$0, section: "media", key: "acceptedTypes", value: [String]())
        }), equals: .inconsistentMediaConfiguration)
    }

    // status.message: a researcher's own explanation should reach participants instead of the
    // generic fallback string being used unconditionally (previously the message was decoded and
    // then discarded entirely — see StudyConfigurationError.unavailable's doc comment).
    func testPausedStudyUsesCustomStatusMessageWhenPresent() throws {
        let base = try fixture("SleepStudy")
        do {
            try validate(base, change: {
                try set(&$0, section: "status", key: "state", value: "paused")
                try set(&$0, section: "status", key: "message", value: "We're on a short break — check back next week.")
            })
            XCTFail("Expected an unavailable error")
        } catch {
            XCTAssertEqual((error as? StudyConfigurationError)?.errorDescription, "We're on a short break — check back next week.")
        }
    }

    func testPausedStudyFallsBackToGenericMessageWhenNoneSet() throws {
        let base = try fixture("SleepStudy") // fixture's status.message is null
        do {
            try validate(base, change: { try set(&$0, section: "status", key: "state", value: "paused") })
            XCTFail("Expected an unavailable error")
        } catch {
            XCTAssertEqual((error as? StudyConfigurationError)?.errorDescription, "This study is temporarily paused. Please contact the study team.")
        }
    }

    func testInactiveStudyWithBlankMessageFallsBackToGeneric() throws {
        let base = try fixture("SleepStudy")
        do {
            try validate(base, change: {
                try set(&$0, section: "status", key: "state", value: "inactive")
                try set(&$0, section: "status", key: "message", value: "   ") // whitespace-only, should not be treated as a real message
            })
            XCTFail("Expected an unavailable error")
        } catch {
            XCTAssertEqual((error as? StudyConfigurationError)?.errorDescription, "This study is not currently accepting participants.")
        }
    }

    // MARK: - startDateMode (see ParticipantStartDateResolver)

    func testFixedStartDateModeRequiresAStartDate() throws {
        let base = try fixture("SleepStudy")
        XCTAssertThrowsError(try validate(base, change: {
            try set(&$0, section: "schedule", key: "startDateMode", value: "fixed")
            try set(&$0, section: "schedule", key: "startDate", value: NSNull())
            try set(&$0, section: "schedule", key: "openEnded", value: true)
        }), equals: .invalidDateRange)
    }

    func testFixedStartDateModeWithAStartDateValidates() throws {
        let base = try fixture("SleepStudy") // already has a schedule.startDate ("2025-01-01")
        XCTAssertNoThrow(try validate(base, change: {
            try set(&$0, section: "schedule", key: "startDateMode", value: "fixed")
        }))
    }

    // SleepStudy.json has no startDateMode key at all (it predates schemaVersion 8) — resolving to
    // .enrollment is what makes decoding it safe: same plain-optional-no-inline-default pattern as
    // participantDurationDays, documented on StudySchedule.startDateMode.
    func testAbsentStartDateModeDefaultsToEnrollment() throws {
        let base = try fixture("SleepStudy")
        XCTAssertNil(base.schedule.startDateMode)
        XCTAssertEqual(base.schedule.resolvedStartDateMode, .enrollment)
    }

    // MARK: - randomWindow EMA scheduling (see NotificationScheduleBuilder.randomWindowOccurrences)

    private var randomWindowMessageReminder: [String: Any] {
        [
            "id": "ema-prompt", "title": "Quick check-in", "body": "Tap to answer a few questions.",
            "enabled": true, "kind": "message",
            "schedule": [
                "pattern": "randomWindow", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [Int](),
                "anchor": "clockTime", "offsetMinutes": NSNull(),
                "windowCount": 3, "windowStartHour": 8, "windowLengthHours": 4,
            ] as [String: Any],
        ]
    }

    func testRandomWindowMessageReminderValidates() throws {
        let base = try fixture("SleepStudy")
        XCTAssertNoThrow(try validate(base, change: { json in
            var reminders = try XCTUnwrap(json["reminders"] as? [[String: Any]])
            reminders.append(self.randomWindowMessageReminder)
            json["reminders"] = reminders
        }))
    }

    func testRandomWindowRejectsWindowCountTimesLengthOverADay() throws {
        let base = try fixture("SleepStudy")
        XCTAssertThrowsError(try validate(base, change: { json in
            var reminder = self.randomWindowMessageReminder
            var schedule = try XCTUnwrap(reminder["schedule"] as? [String: Any])
            schedule["windowCount"] = 10; schedule["windowLengthHours"] = 6
            reminder["schedule"] = schedule
            var reminders = try XCTUnwrap(json["reminders"] as? [[String: Any]])
            reminders.append(reminder)
            json["reminders"] = reminders
        }), equals: .invalidReminder("ema-prompt"))
    }

    // A survey's own schedule (its occurrence/availability-window timing) never allows
    // randomWindow is available on a survey's own schedule too (see
    // `SurveyOccurrenceBuilder`/`RandomWindowScheduling` and `allowsRandomWindow: true` at the
    // survey call site in `StudyConfigurationValidator`).
    func testRandomWindowValidatesOnASurveysOwnSchedule() throws {
        let base = try fixture("SleepStudy")
        XCTAssertNoThrow(try validate(base, change: { json in
            var surveys = try XCTUnwrap(json["surveys"] as? [[String: Any]])
            var survey = try XCTUnwrap(surveys.first)
            survey["schedule"] = [
                "pattern": "randomWindow", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [Int](),
                "anchor": "clockTime", "offsetMinutes": NSNull(),
                "windowCount": 2, "windowStartHour": 8, "windowLengthHours": 4,
            ] as [String: Any]
            surveys[0] = survey
            json["surveys"] = surveys
        }))
    }

    private var validator: StudyConfigurationValidator { .init(now: StudyConfigurationValidator.dateFormatter.date(from: "2026-07-23")!) }
    private func fixture(_ name: String) throws -> StudyConfiguration {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
    }
    private func validate(_ base: StudyConfiguration, change: (inout [String: Any]) throws -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]); try change(&json)
        try validator.validate(JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    private func set(_ root: inout [String: Any], section: String, key: String, value: Any) throws {
        var dictionary = try XCTUnwrap(root[section] as? [String: Any]); dictionary[key] = value; root[section] = dictionary
    }
    private func duplicateArray(in root: inout [String: Any], key: String) throws {
        var array = try XCTUnwrap(root[key] as? [[String: Any]]); array.append(try XCTUnwrap(array.first)); root[key] = array
    }
    private func duplicateNestedArray(in root: inout [String: Any], section: String, key: String) throws {
        var dictionary = try XCTUnwrap(root[section] as? [String: Any]); var array = try XCTUnwrap(dictionary[key] as? [[String: Any]])
        array.append(try XCTUnwrap(array.first)); dictionary[key] = array; root[section] = dictionary
    }
}

private extension XCTestCase {
    func XCTAssertThrowsError(_ expression: @autoclosure () throws -> Void, equals expected: StudyConfigurationError? = nil, file: StaticString = #filePath, line: UInt = #line) {
        do { try expression(); XCTFail("Expected error", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? StudyConfigurationError, expected, file: file, line: line) } }
    }
}
