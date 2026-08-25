import XCTest
@testable import Inoxity

/// Property-based sweep across the space of study configurations the dashboard's wizard can
/// produce. Every other test in this target is example-based — one specific fixture, one
/// specific scenario. This generates many *different* configurations (varying survey/reminder
/// counts, schedule patterns including `randomWindow`, HealthKit identifier sets, wake/bed
/// anchors, media, date bounds, feature flags) and drives each through the same pipeline the app
/// itself runs — `StudyConfigurationValidator` → `SurveyOccurrenceBuilder` →
/// `NotificationScheduleBuilder` — asserting none of it throws or crashes.
///
/// This is meant as a fast, repeatable stand-in for "have a bunch of RAs each build a different
/// study and see if anything breaks" — it can't catch UX confusion or wizard-usability problems
/// (nothing but real humans can), but it explores far more *structural* combinations than a
/// handful of manually-built studies ever would, in seconds rather than hours.
///
/// Deterministically seeded — iteration `n` always generates the same configuration — so a
/// failure (or a crash; XCTest can't catch a Swift trap, but the printed line survives in the
/// log/crash report) is reproducible by re-running with that same seed via
/// `FuzzStudyConfigurationGenerator.generate(seed:)`.
final class StudyConfigurationFuzzTests: XCTestCase {
    /// How many distinct configurations to generate and drive through the full pipeline. A plain
    /// constant (not a launch argument) so `xcodebuild test` runs are reproducible without extra
    /// setup — bump it locally for a deeper sweep.
    private let iterationCount = 200

    /// Fixed so every generated study's [start, end] (years chosen 2020–2025 opening, ending
    /// 2030+) reliably contains it — keeps `StudyConfigurationValidator`'s notStarted/ended gate
    /// out of the way of the thing this test actually cares about.
    private let referenceNow = StudyConfigurationValidator.dateFormatter.date(from: "2026-08-24")!

    func testManyGeneratedStudyConfigurationsSurviveTheFullPipeline() throws {
        for seed in 0..<iterationCount {
            let generated = try FuzzStudyConfigurationGenerator.generate(seed: seed)
            // Printed before anything else runs so a crash (fatalError/force-unwrap — XCTest
            // cannot catch those as thrown errors, they just kill the process) still leaves the
            // offending seed as the last line in the test log / crash report.
            print("StudyConfigurationFuzzTests seed \(seed): \(generated.surveys.count) survey(s), " +
                  "\(generated.reminders.count) reminder(s), sleepSchedule=\(generated.sleepSchedule?.enabled ?? false), " +
                  "healthKit=\(generated.healthKit.identifiers), openEnded=\(generated.schedule.openEnded)")

            do {
                try StudyConfigurationValidator(now: referenceNow).validate(generated, expectedCode: generated.identity.code)
            } catch {
                XCTFail("seed \(seed): generator produced a configuration that failed validation: \(error)")
                continue
            }

            let timeZone = try XCTUnwrap(TimeZone(identifier: generated.schedule.timeZone), "seed \(seed)")
            let participant = ParticipantState(
                studyID: generated.identity.id, enrollmentDate: referenceNow.addingTimeInterval(-30 * 86_400),
                wakeTimeMinutes: generated.sleepSchedule?.enabled == true ? 420 : nil,
                bedTimeMinutes: generated.sleepSchedule?.enabled == true ? 1_380 : nil)

            // Sweep `now` across before/during/after the study window — the same three regimes a
            // human tester would try by hand — so a bug that only shows up right at the edges of
            // a study's active window doesn't slip through.
            for now in sampleDates(for: generated) {
                XCTAssertNoThrow(try SurveyOccurrenceBuilder().build(configuration: generated, participant: participant, now: now, timeZone: timeZone),
                                 "seed \(seed), now \(now)")
                XCTAssertNoThrow(try NotificationScheduleBuilder().build(configuration: generated, participant: participant, now: now, timeZone: timeZone),
                                 "seed \(seed), now \(now)")
            }
        }
    }

    private func sampleDates(for configuration: StudyConfiguration) -> [Date] {
        var dates = [referenceNow]
        let formatter = StudyConfigurationValidator.dateFormatter
        if let raw = configuration.schedule.startDate, let start = formatter.date(from: raw) {
            dates.append(start.addingTimeInterval(3_600))       // just after opening
            dates.append(start.addingTimeInterval(-86_400))     // just before opening
        }
        if let raw = configuration.schedule.endDate, let end = formatter.date(from: raw) {
            dates.append(end.addingTimeInterval(-3_600))        // just before closing
            dates.append(end.addingTimeInterval(86_400))        // just after closing
        }
        return dates
    }
}

/// A tiny deterministic PRNG (SplitMix64) so a given seed always reproduces the same
/// configuration — `SystemRandomNumberGenerator` would make failures unreproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds a `StudyConfiguration` by generating a JSON dictionary and decoding it — the same
/// technique `StudyConfigurationTests`' `validate(_:change:)` uses — rather than constructing the
/// model types directly, since several of them (`StudyConfiguration`, `SurveyConfiguration`) only
/// have a decoder `init`, no memberwise one. Every choice below is made *by construction* to
/// satisfy `StudyConfigurationValidator`'s cross-field rules (e.g. a survey-kind reminder's
/// `notifyMinutesBefore` never exceeds its survey's `opensMinutesBefore`) rather than generating
/// freely and discarding invalid results — that keeps every one of `iterationCount` generations
/// actually exercising the pipeline instead of being thrown away.
///
/// Scoped to `schemaVersion` 8 (current) and `features.surveysEnabled == true` with `surveys`
/// always in `visibleTabs` — legacy schema-migration paths and the surveys-disabled path each
/// already have dedicated example-based tests elsewhere in this target; this generator's job is
/// breadth across the *current* config shape, not re-covering those.
private enum FuzzStudyConfigurationGenerator {
    static func generate(seed: Int) throws -> StudyConfiguration {
        var rng = SplitMix64(seed: UInt64(seed))
        let studyID = "sim-study-\(seed)"

        let openEnded = Double.random(in: 0...1, using: &rng) < 0.3
        let startYear = Int.random(in: 2020...2025, using: &rng)
        // +10...20 (not +5...15): with the earliest possible startYear (2020), a +5 duration
        // would put endYear at 2025 — before `referenceNow` (2026-08-24) — which trips
        // `StudyConfigurationValidator`'s `.ended` gate on a config this generator should never
        // produce. Caught by this exact test at seed 134 before this fix.
        let endYear = startYear + Int.random(in: 10...20, using: &rng)
        let startDate = openEnded ? nil : "\(startYear)-01-01"
        let endDate = openEnded ? nil : "\(endYear)-12-31"

        let sleepEnabled = Bool.random(using: &rng)
        let identifiers = Array(HealthKitTypeRegistry.supportedIdentifiers).shuffled(using: &rng)
            .prefix(Int.random(in: 0...5, using: &rng))
        let healthKitEnabled = !identifiers.isEmpty

        let mediaEnabled = Bool.random(using: &rng)
        let mediaTypes: [String] = mediaEnabled
            ? (Bool.random(using: &rng) ? ["photo"] : (Bool.random(using: &rng) ? ["video"] : ["photo", "video"]))
            : []

        var visibleTabs = ["home", "surveys", "settings", "about"]
        if healthKitEnabled { visibleTabs.append("sleep") }
        if mediaEnabled { visibleTabs.append("media") }

        var surveys = [[String: Any]]()
        var enabledSurveyIDs = [String]()
        let surveyCount = Int.random(in: 0...4, using: &rng)
        for index in 0..<surveyCount {
            let survey = buildSurvey(studyID: studyID, index: index, startDate: startDate, endDate: endDate,
                                     sleepEnabled: sleepEnabled, using: &rng)
            surveys.append(survey)
            if survey["enabled"] as? Bool == true { enabledSurveyIDs.append(survey["id"] as! String) }
        }

        var reminders = [[String: Any]]()
        let reminderCount = Int.random(in: 0...4, using: &rng)
        for index in 0..<reminderCount {
            reminders.append(buildReminder(index: index, startDate: startDate, endDate: endDate,
                                           sleepEnabled: sleepEnabled, enabledSurveyIDs: enabledSurveyIDs,
                                           surveys: surveys, using: &rng))
        }

        let json: [String: Any] = [
            "schemaVersion": 8,
            "identity": ["id": studyID, "code": "SIM\(seed)", "displayName": "Simulated Study \(seed)",
                        "shortName": "Sim \(seed)", "welcomeTitle": "Welcome", "welcomeMessage": "Thanks for participating."],
            "status": ["state": "active", "message": NSNull()],
            "schedule": ["startDate": nilOr(startDate), "endDate": nilOr(endDate), "timeZone": randomTimeZone(using: &rng),
                        "openEnded": openEnded,
                        "participantDurationDays": Bool.random(using: &rng) ? Int.random(in: 7...180, using: &rng) as Any : NSNull() as Any,
                        "startDateMode": openEnded ? ["enrollment", "participantSelected"].randomElement(using: &rng)!
                                                    : ["enrollment", "fixed", "participantSelected"].randomElement(using: &rng)!],
            "participantID": ["label": "Participant ID", "prompt": "Enter your participant ID", "placeholder": "e.g. 12345",
                              "helpText": "Provided by the study team.", "required": true, "minimumLength": 1,
                              "maximumLength": 64, "allowedPattern": NSNull()],
            "onboarding": ["pages": buildOnboardingPages(using: &rng)],
            "healthKit": ["enabled": healthKitEnabled, "rationale": "Reads the configured Apple Health data types.",
                         "identifiers": Array(identifiers),
                         "backfillDays": Bool.random(using: &rng) ? Int.random(in: 1...365, using: &rng) as Any : NSNull() as Any,
                         "includeCharacteristics": Bool.random(using: &rng)],
            "notifications": ["enabled": Double.random(in: 0...1, using: &rng) < 0.8, "rationale": "Optional reminders."],
            "sleepSchedule": ["enabled": sleepEnabled, "promptTitle": "When do you usually sleep?",
                              "wakeLabel": "Wake time", "bedLabel": "Bed time"],
            "surveys": surveys,
            "reminders": reminders,
            "features": ["surveysEnabled": true, "sleepSummaryEnabled": Bool.random(using: &rng),
                        "mediaUploadsEnabled": mediaEnabled, "streaksEnabled": Bool.random(using: &rng),
                        "visibleTabs": visibleTabs],
            "media": ["enabled": mediaEnabled, "instructions": "Upload what's requested.",
                     "privacyText": "Uploaded directly to this study's server.", "acceptedTypes": mediaTypes,
                     "maximumTotalItems": Int.random(in: 1...10, using: &rng), "maximumFileSizeMB": Int.random(in: 1...100, using: &rng),
                     "maximumVideoLengthSeconds": mediaTypes.contains("video") ? Int.random(in: 30...600, using: &rng) as Any : NSNull() as Any,
                     "required": Bool.random(using: &rng), "activeStartDate": NSNull(), "activeEndDate": NSNull(),
                     "categories": mediaEnabled ? [["id": "sim-category", "displayName": "Category", "description": "General uploads.",
                                                     "acceptedTypes": mediaTypes, "required": false,
                                                     "maximumItems": Int.random(in: 1...5, using: &rng),
                                                     "representedDateRequired": Bool.random(using: &rng)]] : []],
            "support": ["name": "Simulated Study Team", "email": "sim\(seed)@example.edu", "phone": NSNull(), "website": NSNull()],
            "faqs": (0..<Int.random(in: 0...2, using: &rng)).map { i in
                ["id": "sim-faq-\(i)", "question": "Question \(i)?", "answer": "Answer \(i)."]
            },
            "completion": ["title": "All done", "message": "Thanks for participating.", "redirectURL": NSNull(),
                          "appAccessRemainsAvailable": Bool.random(using: &rng)],
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(StudyConfiguration.self, from: data)
    }

    private static func buildSurvey(studyID: String, index: Int, startDate: String?, endDate: String?,
                                    sleepEnabled: Bool, using rng: inout SplitMix64) -> [String: Any] {
        let id = "sim-survey-\(index)"
        let opensBefore = Int.random(in: 0...720, using: &rng)
        let closesAfter = Int.random(in: 1...720, using: &rng)
        let bounded = startDate != nil && endDate != nil
        let useBounds = bounded && Bool.random(using: &rng)
        return [
            "id": id, "enabled": Double.random(in: 0...1, using: &rng) < 0.8,
            "name": "Survey \(index)", "description": "A short simulated survey.",
            "url": "https://example.edu/sim/survey-\(index)", "presentationMode": ["externalBrowser", "inAppBrowser"].randomElement(using: &rng)!,
            "schedule": buildSchedule(sleepEnabled: sleepEnabled, allowRandomWindow: true, using: &rng),
            "availabilityWindow": ["opensMinutesBefore": opensBefore, "closesMinutesAfter": closesAfter],
            "completionCallback": ["enabled": Bool.random(using: &rng)],
            "instructions": "Open during the availability window.", "privacyText": "Responses are not stored by Inoxity.",
            "activeStartDate": useBounds ? startDate! as Any : NSNull() as Any, "activeEndDate": useBounds ? endDate! as Any : NSNull() as Any,
            "sendNotificationOnOpen": false, "notificationTitle": NSNull(), "notificationBody": NSNull(),
            "promptExpirationMinutes": Bool.random(using: &rng) ? Int.random(in: 1...2_880, using: &rng) as Any : NSNull() as Any,
        ]
    }

    private static func buildReminder(index: Int, startDate: String?, endDate: String?, sleepEnabled: Bool,
                                      enabledSurveyIDs: [String], surveys: [[String: Any]], using rng: inout SplitMix64) -> [String: Any] {
        let id = "sim-reminder-\(index)"
        let bounded = startDate != nil && endDate != nil
        let useBounds = bounded && Bool.random(using: &rng)
        let enabled = Double.random(in: 0...1, using: &rng) < 0.8

        if let surveyID = enabledSurveyIDs.randomElement(using: &rng), Bool.random(using: &rng) {
            let survey = surveys.first { $0["id"] as! String == surveyID }!
            let opensBefore = (survey["availabilityWindow"] as! [String: Any])["opensMinutesBefore"] as! Int
            return [
                "id": id, "title": "Reminder \(index)", "body": "An activity is available.", "enabled": enabled,
                "kind": "survey", "surveyID": surveyID, "schedule": NSNull(),
                "notifyMinutesBefore": Int.random(in: 0...opensBefore, using: &rng), "destination": "surveys",
                "activeStartDate": useBounds ? startDate! as Any : NSNull() as Any, "activeEndDate": useBounds ? endDate! as Any : NSNull() as Any,
            ]
        }
        return [
            "id": id, "title": "Reminder \(index)", "body": "Don't forget to check in.", "enabled": enabled,
            "kind": "message", "surveyID": NSNull(),
            "schedule": buildSchedule(sleepEnabled: sleepEnabled, allowRandomWindow: true, using: &rng),
            "notifyMinutesBefore": NSNull(), "destination": ["home", "surveys", "settings", "aboutStudy"].randomElement(using: &rng)!,
            "activeStartDate": useBounds ? startDate! as Any : NSNull() as Any, "activeEndDate": useBounds ? endDate! as Any : NSNull() as Any,
        ]
    }

    private static func buildSchedule(sleepEnabled: Bool, allowRandomWindow: Bool, using rng: inout SplitMix64) -> [String: Any] {
        var patterns = ["daily", "selectedWeekdays", "oneTime"]
        if allowRandomWindow { patterns.append("randomWindow") }
        let pattern = patterns.randomElement(using: &rng)!
        var json: [String: Any] = ["pattern": pattern, "hour": Int.random(in: 0...23, using: &rng),
                                   "minute": Int.random(in: 0...59, using: &rng), "date": NSNull(), "weekdays": []]
        switch pattern {
        case "selectedWeekdays":
            json["weekdays"] = Array(1...7).shuffled(using: &rng).prefix(Int.random(in: 1...7, using: &rng)).sorted()
        case "oneTime":
            json["date"] = "2025-06-15"
        case "randomWindow":
            let windowCount = Int.random(in: 1...10, using: &rng)
            let windowLengthHours = Int.random(in: 1...max(1, 24 / windowCount), using: &rng)
            json["windowCount"] = windowCount; json["windowStartHour"] = Int.random(in: 0...23, using: &rng)
            json["windowLengthHours"] = windowLengthHours
        default: break
        }
        if sleepEnabled, Bool.random(using: &rng) {
            json["anchor"] = ["wakeTime", "bedTime"].randomElement(using: &rng)!
            json["offsetMinutes"] = Int.random(in: -1_440...1_440, using: &rng)
        } else {
            json["anchor"] = "clockTime"
        }
        return json
    }

    private static func buildOnboardingPages(using rng: inout SplitMix64) -> [[String: Any]] {
        (0..<Int.random(in: 0...3, using: &rng)).map { i in
            ["id": "sim-onboarding-\(i)", "title": "Page \(i)", "body": "Onboarding content.",
             "symbol": "info.circle", "enabled": true]
        }
    }

    private static func randomTimeZone(using rng: inout SplitMix64) -> String {
        ["UTC", "America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"].randomElement(using: &rng)!
    }

    private static func nilOr(_ value: String?) -> Any { value ?? NSNull() }
}
