import Foundation

enum StudyConfigurationError: Error, Equatable, LocalizedError {
    case unknownCode, missingResource, malformedConfiguration
    case unsupportedSchema(Int), missingStudyID, missingStudyCode, studyCodeMismatch
    // Carries the researcher's own StudyAvailability.message (set in the dashboard's Basics step,
    // shown there as "Status message") alongside the state, so a custom explanation can actually
    // reach participants instead of always falling back to the two generic strings below —
    // previously `status.message` was decoded but silently discarded here.
    case unavailable(StudyStatus, message: String?), invalidTimeZone, invalidDateRange, notStarted, ended
    case duplicateID(String), unsupportedHealthIdentifier(String), malformedURL(String)
    case inconsistentMediaConfiguration, missingContent(String), invalidReminder(String)
    case inconsistentHealthKitConfiguration

    var errorDescription: String? {
        switch self {
        case .unknownCode: "We couldn’t find that study code. Check the code and try again."
        case .unsupportedSchema: "This study requires a newer version of Inoxity."
        case .unavailable(let state, let message): Self.unavailableMessage(state: state, custom: message)
        case .notStarted: "This study has not started yet."
        case .ended: "This study has ended."
        default: "This study is not available right now. Please contact the study team."
        }
    }

    private static func unavailableMessage(state: StudyStatus, custom: String?) -> String {
        if let custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return custom }
        switch state {
        case .paused: return "This study is temporarily paused. Please contact the study team."
        default: return "This study is not currently accepting participants."
        }
    }
}

struct StudyConfigurationValidator: Sendable {
    static let supportedSchemaVersion = 8
    static let supportedSchemaVersions: Set<Int> = [2, 3, 4, 5, 6, 7, 8]
    static let supportedHealthIdentifiers = HealthKitTypeRegistry.supportedIdentifiers
    private let now: Date

    init(now: Date = Date()) { self.now = now }

    func validate(_ value: StudyConfiguration, expectedCode: String? = nil) throws {
        guard Self.supportedSchemaVersions.contains(value.schemaVersion) else { throw StudyConfigurationError.unsupportedSchema(value.schemaVersion) }
        guard !clean(value.identity.id).isEmpty else { throw StudyConfigurationError.missingStudyID }
        guard SurveyOccurrenceIdentifierFactory.isValidComponent(value.identity.id) else { throw StudyConfigurationError.missingStudyID }
        let code = StudyCodeNormalizer.normalize(value.identity.code)
        guard !code.isEmpty else { throw StudyConfigurationError.missingStudyCode }
        if let expectedCode, code != StudyCodeNormalizer.normalize(expectedCode) { throw StudyConfigurationError.studyCodeMismatch }
        guard value.status.state == .active else { throw StudyConfigurationError.unavailable(value.status.state, message: value.status.message) }
        guard TimeZone(identifier: value.schedule.timeZone) != nil else { throw StudyConfigurationError.invalidTimeZone }

        let start = try parsed(value.schedule.startDate)
        let end = try parsed(value.schedule.endDate)
        if let start, let end, start > end { throw StudyConfigurationError.invalidDateRange }
        if !value.schedule.openEnded && (start == nil || end == nil) { throw StudyConfigurationError.invalidDateRange }
        let today = Self.calendar.startOfDay(for: now)
        if let start, today < start { throw StudyConfigurationError.notStarted }
        if let end, today > end { throw StudyConfigurationError.ended }
        // "fixed" start-date mode anchors every participant's day 1 to schedule.startDate, so it
        // needs one even for an open-ended study (which otherwise doesn't require startDate at
        // all) — mirrors the dashboard's own superRefine rule in study-schema.ts.
        if value.schedule.resolvedStartDateMode == .fixed, start == nil { throw StudyConfigurationError.invalidDateRange }

        for required in [value.identity.displayName, value.identity.welcomeTitle, value.identity.welcomeMessage,
                         value.participantID.label, value.participantID.prompt] where clean(required).isEmpty {
            throw StudyConfigurationError.missingContent("participant-facing content")
        }
        if let sleepSchedule = value.sleepSchedule, sleepSchedule.enabled {
            for required in [sleepSchedule.promptTitle, sleepSchedule.wakeLabel, sleepSchedule.bedLabel] where clean(required).isEmpty {
                throw StudyConfigurationError.missingContent("sleep schedule")
            }
        }
        try unique(value.onboarding.pages.map(\.id))
        try unique(value.surveys.map(\.id))
        guard value.reminders.allSatisfy({ !clean($0.id).isEmpty }) else { throw StudyConfigurationError.invalidReminder("Reminder IDs cannot be blank.") }
        try unique(value.reminders.map(\.id))
        for survey in value.surveys {
            guard SurveyOccurrenceIdentifierFactory.isValidComponent(survey.id),
                  !clean(survey.name).isEmpty, !clean(survey.description).isEmpty else {
                throw StudyConfigurationError.missingContent("survey")
            }
            try validHTTPSURL(survey.url)
            try validate(schedule: survey.schedule, context: survey.id, sleepScheduleEnabled: value.sleepSchedule?.enabled == true, allowsRandomWindow: true)
            try validOptionalDate(survey.activeStartDate)
            try validOptionalDate(survey.activeEndDate)
            if let surveyStart = try parsed(survey.activeStartDate),
               let surveyEnd = try parsed(survey.activeEndDate), surveyStart > surveyEnd {
                throw StudyConfigurationError.invalidDateRange
            }
            if let surveyStart = try parsed(survey.activeStartDate), let start, surveyStart < start { throw StudyConfigurationError.invalidDateRange }
            if let surveyEnd = try parsed(survey.activeEndDate), let end, surveyEnd > end { throw StudyConfigurationError.invalidDateRange }
            let limits = SurveyConfigurationPolicy.default
            guard (0...limits.maximumOpensMinutesBefore).contains(survey.availabilityWindow.opensMinutesBefore),
                  (0...limits.maximumClosesMinutesAfter).contains(survey.availabilityWindow.closesMinutesAfter),
                  survey.availabilityWindow.opensMinutesBefore + survey.availabilityWindow.closesMinutesAfter > 0 else {
                throw StudyConfigurationError.missingContent("survey availability")
            }
            if let expiration = survey.promptExpirationMinutes, expiration < 1 {
                throw StudyConfigurationError.missingContent("survey availability")
            }
        }
        for reminder in value.reminders {
            guard !clean(reminder.title).isEmpty, !clean(reminder.body).isEmpty else { throw StudyConfigurationError.invalidReminder(reminder.id) }
            let reminderStart = try parsed(reminder.activeStartDate)
            let reminderEnd = try parsed(reminder.activeEndDate)
            if let reminderStart, let reminderEnd, reminderStart > reminderEnd { throw StudyConfigurationError.invalidReminder(reminder.id) }
            if let reminderStart, let start, reminderStart < start { throw StudyConfigurationError.invalidReminder(reminder.id) }
            if let reminderEnd, let end, reminderEnd > end { throw StudyConfigurationError.invalidReminder(reminder.id) }
            if let oneTime = try parsed(reminder.schedule?.date) {
                if let start, oneTime < start { throw StudyConfigurationError.invalidReminder(reminder.id) }
                if let end, oneTime > end { throw StudyConfigurationError.invalidReminder(reminder.id) }
            }
            if reminder.kind == .survey {
                guard let surveyID = reminder.surveyID,
                      let survey = value.surveys.first(where: { $0.id == surveyID }), survey.enabled,
                      reminder.destination == .surveys, value.features.surveysEnabled,
                      value.features.visibleTabs.contains(.surveys) else {
                    throw StudyConfigurationError.missingContent("survey reminder target")
                }
                if value.schemaVersion >= 4 {
                    guard reminder.schedule == nil, let offset = reminder.notifyMinutesBefore,
                          (0...SurveyConfigurationPolicy.default.maximumNotificationOffsetMinutes).contains(offset),
                          offset <= survey.availabilityWindow.opensMinutesBefore else {
                        throw StudyConfigurationError.invalidReminder(reminder.id)
                    }
                } else {
                    guard let schedule = reminder.schedule else { throw StudyConfigurationError.invalidReminder(reminder.id) }
                    try validate(schedule: schedule, context: reminder.id, sleepScheduleEnabled: value.sleepSchedule?.enabled == true)
                    guard legacySurveySchedule(schedule, mapsTo: survey.schedule) else {
                        throw StudyConfigurationError.invalidReminder(reminder.id)
                    }
                }
            } else if reminder.destination == .surveys,
                      (!value.features.surveysEnabled || !value.features.visibleTabs.contains(.surveys)) {
                throw StudyConfigurationError.invalidReminder(reminder.id)
            } else {
                guard let schedule = reminder.schedule, reminder.notifyMinutesBefore == nil else { throw StudyConfigurationError.invalidReminder(reminder.id) }
                // allowsRandomWindow: true — the EMA-style pattern only makes sense for a message
                // reminder's own notification schedule, not (see the survey-loop call site above,
                // and the legacy branch just above this one) a survey's own occurrence timing.
                try validate(schedule: schedule, context: reminder.id, sleepScheduleEnabled: value.sleepSchedule?.enabled == true, allowsRandomWindow: true)
            }
        }
        for identifier in value.healthKit.identifiers where !Self.supportedHealthIdentifiers.contains(identifier) {
            throw StudyConfigurationError.unsupportedHealthIdentifier(identifier)
        }
        if let backfillDays = value.healthKit.backfillDays, backfillDays <= 0 {
            throw StudyConfigurationError.inconsistentHealthKitConfiguration
        }
        guard Self.validEmail(value.support.email) else { throw StudyConfigurationError.malformedURL(value.support.email) }
        try validURL(value.support.website)
        try validURL(value.completion.redirectURL)
        if value.features.mediaUploadsEnabled && (!value.media.enabled || value.media.acceptedTypes.isEmpty) {
            throw StudyConfigurationError.inconsistentMediaConfiguration
        }
        try validateMedia(value.media, studyStart: start, studyEnd: end)
    }

    private func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func parsed(_ string: String?) throws -> Date? {
        guard let string else { return nil }
        guard let date = Self.dateFormatter.date(from: string) else { throw StudyConfigurationError.invalidDateRange }
        return date
    }
    private func unique(_ values: [String]) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted { throw StudyConfigurationError.duplicateID(value) }
    }
    private func validURL(_ value: String?) throws {
        guard let value, !value.isEmpty else { return }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), parts.host != nil else { throw StudyConfigurationError.malformedURL(value) }
    }
    private func validHTTPSURL(_ value: String) throws {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false else {
            throw StudyConfigurationError.malformedURL(value)
        }
    }
    // allowsRandomWindow: the EMA-style `.randomWindow` pattern is available for both a survey's
    // own schedule and a message reminder's schedule — both call sites in `validate(_:expectedCode:)`
    // above pass `true`. Defaults to `false` only so a future schedule-validating call site that
    // genuinely shouldn't allow it (none exists today) doesn't have to opt out explicitly. Mirrors
    // the dashboard's `ScheduleFields`' `allowRandomWindow` prop, which is likewise `true` for both.
    private func validate(schedule: ReminderScheduleConfiguration, context: String, sleepScheduleEnabled: Bool, allowsRandomWindow: Bool = false) throws {
        guard (0...23).contains(schedule.hour), (0...59).contains(schedule.minute),
              schedule.weekdays.allSatisfy((1...7).contains) else { throw StudyConfigurationError.invalidReminder(context) }
        switch schedule.pattern {
        case .oneTime:
            guard schedule.date != nil else { throw StudyConfigurationError.invalidReminder(context) }
            try validOptionalDate(schedule.date)
        case .daily:
            guard schedule.weekdays.isEmpty, schedule.date == nil else { throw StudyConfigurationError.invalidReminder(context) }
        case .selectedWeekdays:
            guard !schedule.weekdays.isEmpty, schedule.date == nil else { throw StudyConfigurationError.invalidReminder(context) }
        case .randomWindow:
            guard allowsRandomWindow else { throw StudyConfigurationError.invalidReminder(context) }
            guard schedule.weekdays.isEmpty, schedule.date == nil,
                  let windowCount = schedule.windowCount, let windowStartHour = schedule.windowStartHour,
                  let windowLengthHours = schedule.windowLengthHours,
                  (1...10).contains(windowCount), (0...23).contains(windowStartHour), (1...24).contains(windowLengthHours),
                  windowCount * windowLengthHours <= 24
            else { throw StudyConfigurationError.invalidReminder(context) }
        }
        if schedule.resolvedAnchor != .clockTime {
            // A wake/bed-relative schedule only makes sense if the study actually collects a sleep
            // schedule from the participant (see `SleepScheduleView`/`AppState.saveSleepSchedule`).
            guard sleepScheduleEnabled else { throw StudyConfigurationError.invalidReminder(context) }
            guard let offset = schedule.offsetMinutes, (-1440...1440).contains(offset) else {
                throw StudyConfigurationError.invalidReminder(context)
            }
        }
    }
    private func legacySurveySchedule(_ reminder: ReminderScheduleConfiguration,
                                      mapsTo survey: ReminderScheduleConfiguration) -> Bool {
        guard reminder.pattern == survey.pattern else { return false }
        switch survey.pattern {
        case .oneTime: return reminder.date == survey.date
        case .daily: return true
        case .selectedWeekdays: return Set(reminder.weekdays) == Set(survey.weekdays)
        // Unreachable in practice: this legacy path only ever runs for schemaVersion < 4 configs
        // (see the `else` branch above requiring a reminder's schedule to structurally match its
        // linked survey's), and `.randomWindow` was introduced at schemaVersion 8 — a config this
        // old can't contain it regardless of whether surveys are now allowed to use it going
        // forward. Kept `false` purely for switch exhaustiveness.
        case .randomWindow: return false
        }
    }
    private func validateMedia(_ media: MediaConfiguration, studyStart: Date?, studyEnd: Date?) throws {
        guard media.maximumTotalItems > 0, media.maximumFileSizeMB > 0,
              media.maximumVideoLengthSeconds.map({ $0 > 0 }) ?? true else { throw StudyConfigurationError.inconsistentMediaConfiguration }
        try unique(media.categories.map(\.id))
        for category in media.categories {
            guard SurveyOccurrenceIdentifierFactory.isValidComponent(category.id), !clean(category.displayName).isEmpty,
                  category.maximumItems > 0, !category.acceptedTypes.isEmpty,
                  Set(category.acceptedTypes).isSubset(of: Set(media.acceptedTypes)) else { throw StudyConfigurationError.inconsistentMediaConfiguration }
        }
        let activeStart = try parsed(media.activeStartDate), activeEnd = try parsed(media.activeEndDate)
        if let activeStart, let activeEnd, activeStart > activeEnd { throw StudyConfigurationError.invalidDateRange }
        if let activeStart, let studyStart, activeStart < studyStart { throw StudyConfigurationError.invalidDateRange }
        if let activeEnd, let studyEnd, activeEnd > studyEnd { throw StudyConfigurationError.invalidDateRange }
    }
    private func validOptionalDate(_ value: String?) throws { _ = try parsed(value) }
    private static func validEmail(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
