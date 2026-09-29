import Foundation

struct StudyConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identity: StudyIdentity
    let status: StudyAvailability
    let schedule: StudySchedule
    let participantID: ParticipantIDConfiguration
    let onboarding: OnboardingConfiguration
    let healthKit: HealthKitConfiguration
    let notifications: NotificationConfiguration
    let sleepSchedule: SleepScheduleConfiguration?
    let surveys: [SurveyConfiguration]
    let reminders: [ReminderConfiguration]
    let features: AppFeatureFlags
    let media: MediaConfiguration
    let support: SupportContact
    let faqs: [FAQItem]
    let completion: CompletionConfiguration

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, status, schedule, participantID, onboarding, healthKit
        case notifications, sleepSchedule, surveys, reminders, features, media, mediaUploads, support, faqs, completion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        identity = try values.decode(StudyIdentity.self, forKey: .identity)
        status = try values.decode(StudyAvailability.self, forKey: .status)
        schedule = try values.decode(StudySchedule.self, forKey: .schedule)
        participantID = try values.decode(ParticipantIDConfiguration.self, forKey: .participantID)
        onboarding = try values.decode(OnboardingConfiguration.self, forKey: .onboarding)
        healthKit = try values.decode(HealthKitConfiguration.self, forKey: .healthKit)
        sleepSchedule = try values.decodeIfPresent(SleepScheduleConfiguration.self, forKey: .sleepSchedule)
        surveys = try values.decode([SurveyConfiguration].self, forKey: .surveys)
        reminders = try values.decode([ReminderConfiguration].self, forKey: .reminders)
        notifications = try values.decodeIfPresent(NotificationConfiguration.self, forKey: .notifications)
            ?? NotificationConfiguration(enabled: reminders.contains(where: \.enabled), rationale: "Study reminders are optional.")
        features = try values.decode(AppFeatureFlags.self, forKey: .features)
        media = try values.decodeIfPresent(MediaConfiguration.self, forKey: .media)
            ?? values.decode(MediaConfiguration.self, forKey: .mediaUploads)
        support = try values.decode(SupportContact.self, forKey: .support)
        faqs = try values.decode([FAQItem].self, forKey: .faqs)
        completion = try values.decode(CompletionConfiguration.self, forKey: .completion)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(identity, forKey: .identity)
        try values.encode(status, forKey: .status); try values.encode(schedule, forKey: .schedule)
        try values.encode(participantID, forKey: .participantID); try values.encode(onboarding, forKey: .onboarding)
        try values.encode(healthKit, forKey: .healthKit); try values.encode(notifications, forKey: .notifications)
        try values.encodeIfPresent(sleepSchedule, forKey: .sleepSchedule)
        try values.encode(surveys, forKey: .surveys); try values.encode(reminders, forKey: .reminders)
        try values.encode(features, forKey: .features); try values.encode(media, forKey: .media)
        try values.encode(support, forKey: .support); try values.encode(faqs, forKey: .faqs)
        try values.encode(completion, forKey: .completion)
    }
}

struct StudyIdentity: Codable, Equatable, Sendable {
    let id: String
    let code: String
    let displayName: String
    let shortName: String
    let welcomeTitle: String
    let welcomeMessage: String
}

struct StudyAvailability: Codable, Equatable, Sendable {
    let state: StudyStatus
    /// Shown to participants in place of the generic paused/inactive message when the researcher
    /// has written one — see StudyConfigurationValidator's `unavailableMessage(state:custom:)`.
    let message: String?
}

enum StudyStatus: String, Codable, Equatable, Sendable { case active, paused, inactive }

struct StudySchedule: Codable, Equatable, Sendable {
    let startDate: String?
    let endDate: String?
    let timeZone: String
    let openEnded: Bool
    /// Participant-relative study duration in days, counted from that participant's own
    /// `ParticipantState.enrollmentDate` — NOT from `startDate`/`endDate` above, which describe the
    /// study-wide calendar window and may not align with any individual participant's enrollment
    /// under rolling enrollment. `nil` (absent in JSON) means no fixed per-participant duration is
    /// configured; see `StudyProgress` for the resulting Home-screen display. A plain optional with
    /// no inline default value, so synthesized `Codable` decodes existing configs (which omit this
    /// key) safely as `nil` — this struct has no custom `init(from:)`/`encode(to:)`, so unlike
    /// `ReminderScheduleConfiguration`'s documented `anchor`/`offsetMinutes` pattern, there's no
    /// inline `= nil` default on the stored property to trigger that decode bug.
    let participantDurationDays: Int?
    /// What "day 1" is measured from for `StudyProgress`'s day-in-study count — see
    /// `StartDateMode`. `nil` (absent on schemaVersion < 8 configs) is equivalent to `.enrollment`,
    /// today's only-ever-possible behavior — see `resolvedStartDateMode`. Same safe plain-optional
    /// pattern as `participantDurationDays` above: no inline default, no custom decoder needed.
    let startDateMode: StartDateMode?

    var resolvedStartDateMode: StartDateMode { startDateMode ?? .enrollment }
}

/// What a participant's day 1 is measured from — see `ParticipantStartDateResolver`. Mirrors
/// `START_DATE_MODES` in the dashboard's study-schema.ts.
enum StartDateMode: String, Codable, Equatable, Sendable {
    /// Today's original/default behavior: day 1 is whenever this participant enters their
    /// participant ID during onboarding (`ParticipantState.enrollmentDate`) — can be well after
    /// they actually started the study if onboarding happens ahead of time.
    case enrollment
    /// Every participant in the study shares the same day 1: `StudySchedule.startDate`.
    case fixed
    /// This participant confirmed/picked their own real start date during onboarding
    /// (`ParticipantState.participantSelectedStartDate`), which may be in the future.
    case participantSelected
}

struct ParticipantIDConfiguration: Codable, Equatable, Sendable {
    let label: String
    let prompt: String
    let placeholder: String
    let helpText: String
    let required: Bool
    let minimumLength: Int
    let maximumLength: Int
    let allowedPattern: String?
}

/// Governs whether this study collects a participant-set wake time / bed time during onboarding
/// (editable later in Settings), which schedules using `ScheduleAnchor.wakeTime`/`.bedTime` are
/// resolved against. Absent or `enabled == false` means no survey/reminder schedule in this study
/// may use a non-`.clockTime` anchor (enforced by `StudyConfigurationValidator`).
struct SleepScheduleConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
    let promptTitle: String
    let wakeLabel: String
    let bedLabel: String
}

struct OnboardingConfiguration: Codable, Equatable, Sendable { let pages: [OnboardingPage] }

struct OnboardingPage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let symbol: String
    let enabled: Bool
}

struct HealthKitConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
    let rationale: String
    let identifiers: [String]
    /// How many days of EXISTING Apple Health data to collect on first sync, counting back from
    /// enrollment. `nil` means full history (as far back as HealthKit has data, bounded by
    /// `StudySchedule.startDate` when set). Absent on schemaVersion < 7 configs — see
    /// `HealthKitUploadCoordinator.collectionStart` for the legacy fallback. A plain optional
    /// with no inline default, so it decodes correctly (unlike `ReminderScheduleConfiguration`'s
    /// former `anchor`/`offsetMinutes` bug — see that struct's comment for why that pattern is unsafe).
    let backfillDays: Int?
    /// Whether this study also requests HealthKit's five static characteristic types (biological
    /// sex, blood type, date of birth, Fitzpatrick skin type, wheelchair use) — see
    /// `HealthKitService.characteristicTypes`. Previously these were unioned into every
    /// authorization request unconditionally, so participants were prompted for them even when a
    /// study never selected them here; now they're only requested when a study explicitly opts
    /// in. Absent on older configs is equivalent to `false` — decoded via `decodeIfPresent`
    /// rather than an inline default, for the same reason `backfillDays` above avoids one.
    let includeCharacteristics: Bool

    private enum CodingKeys: String, CodingKey { case enabled, rationale, identifiers, backfillDays, includeCharacteristics }

    init(enabled: Bool, rationale: String, identifiers: [String], backfillDays: Int? = nil, includeCharacteristics: Bool = false) {
        self.enabled = enabled; self.rationale = rationale; self.identifiers = identifiers
        self.backfillDays = backfillDays; self.includeCharacteristics = includeCharacteristics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        rationale = try values.decode(String.self, forKey: .rationale)
        identifiers = try values.decode([String].self, forKey: .identifiers)
        backfillDays = try values.decodeIfPresent(Int.self, forKey: .backfillDays)
        includeCharacteristics = try values.decodeIfPresent(Bool.self, forKey: .includeCharacteristics) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(rationale, forKey: .rationale)
        try values.encode(identifiers, forKey: .identifiers)
        try values.encodeIfPresent(backfillDays, forKey: .backfillDays)
        try values.encode(includeCharacteristics, forKey: .includeCharacteristics)
    }
}

struct SurveyConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let enabled: Bool
    let name: String
    let description: String
    let url: String
    let presentationMode: SurveyPresentationMode
    let schedule: ReminderScheduleConfiguration
    let availabilityWindow: SurveyAvailabilityWindowConfiguration
    let completionCallback: SurveyCompletionCallbackConfiguration
    let instructions: String?
    let privacyText: String?
    let activeStartDate: String?
    let activeEndDate: String?
    /// When true, `NotificationScheduleBuilder` schedules a local notification for this survey's
    /// own opening time automatically — no separate `ReminderConfiguration` entry needs to
    /// reference it via `surveyID`. Defaults to `false` (opt-in) so existing surveys don't
    /// silently start notifying. If a `ReminderConfiguration` with `kind == .survey` already
    /// targets this survey, that explicit reminder wins and this auto-notification is skipped,
    /// to avoid double-notifying the same occurrence.
    let sendNotificationOnOpen: Bool
    /// Overrides for the auto-notification's copy; `nil` falls back to a default derived from
    /// `name` (see `NotificationScheduleBuilder`). Ignored when `sendNotificationOnOpen` is false.
    let notificationTitle: String?
    let notificationBody: String?
    /// If set, an occurrence is marked `.late` (see `SurveyOccurrenceBuilder.status`) once this
    /// many minutes pass after the participant is first prompted without them opening it — a
    /// softer, adherence-tracking deadline that can be shorter than
    /// `availabilityWindow.closesMinutesAfter`, which alone still governs whether the occurrence
    /// can actually still be opened/completed (a late occurrence still can). "Prompted" is the
    /// first notification for the occurrence, or `opensAt` when nothing notifies — see
    /// `SurveyOccurrenceBuilder.promptLeadMinutes`.
    /// `nil` means only `closesMinutesAfter` governs "missed" (today's only-ever-possible
    /// behavior before this field existed). Lived on `ReminderConfiguration` before schemaVersion
    /// 8 — moved here since it's fundamentally about a survey occurrence's own deadline, not any
    /// particular reminder announcing it. Mirrors `promptExpirationMinutes` on `surveySchema` in
    /// the dashboard's study-schema.ts.
    let promptExpirationMinutes: Int?

    private enum CodingKeys: String, CodingKey {
        case id, enabled, name, description, url, presentationMode, schedule, availabilityWindow
        case completionCallback, instructions, privacyText, activeStartDate, activeEndDate
        case title, summary, externalURL, availability
        case sendNotificationOnOpen, notificationTitle, notificationBody, promptExpirationMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? values.decode(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? values.decode(String.self, forKey: .summary)
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? values.decode(String.self, forKey: .externalURL)
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions)
        privacyText = try values.decodeIfPresent(String.self, forKey: .privacyText)
        sendNotificationOnOpen = try values.decodeIfPresent(Bool.self, forKey: .sendNotificationOnOpen) ?? false
        notificationTitle = try values.decodeIfPresent(String.self, forKey: .notificationTitle)
        notificationBody = try values.decodeIfPresent(String.self, forKey: .notificationBody)
        promptExpirationMinutes = try values.decodeIfPresent(Int.self, forKey: .promptExpirationMinutes)
        completionCallback = try values.decodeIfPresent(SurveyCompletionCallbackConfiguration.self, forKey: .completionCallback)
            ?? .init(enabled: true)
        if let explicit = try values.decodeIfPresent(ReminderScheduleConfiguration.self, forKey: .schedule) {
            schedule = explicit
            availabilityWindow = try values.decode(SurveyAvailabilityWindowConfiguration.self, forKey: .availabilityWindow)
            presentationMode = try values.decode(SurveyPresentationMode.self, forKey: .presentationMode)
            activeStartDate = try values.decodeIfPresent(String.self, forKey: .activeStartDate)
            activeEndDate = try values.decodeIfPresent(String.self, forKey: .activeEndDate)
        } else {
            let legacy = try values.decode(LegacySurveyAvailabilityConfiguration.self, forKey: .availability)
            schedule = .init(pattern: legacy.weekdays.count == 7 ? .daily : .selectedWeekdays,
                             date: nil, hour: legacy.hour, minute: legacy.minute,
                             weekdays: legacy.weekdays.count == 7 ? [] : legacy.weekdays)
            availabilityWindow = .init(opensMinutesBefore: 0, closesMinutesAfter: legacy.durationMinutes)
            presentationMode = .externalBrowser
            activeStartDate = legacy.startDate
            activeEndDate = legacy.endDate
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(enabled, forKey: .enabled)
        try values.encode(name, forKey: .name); try values.encode(description, forKey: .description)
        try values.encode(url, forKey: .url); try values.encode(presentationMode, forKey: .presentationMode)
        try values.encode(schedule, forKey: .schedule); try values.encode(availabilityWindow, forKey: .availabilityWindow)
        try values.encode(completionCallback, forKey: .completionCallback)
        try values.encodeIfPresent(instructions, forKey: .instructions); try values.encodeIfPresent(privacyText, forKey: .privacyText)
        try values.encodeIfPresent(activeStartDate, forKey: .activeStartDate); try values.encodeIfPresent(activeEndDate, forKey: .activeEndDate)
        try values.encode(sendNotificationOnOpen, forKey: .sendNotificationOnOpen)
        try values.encodeIfPresent(notificationTitle, forKey: .notificationTitle)
        try values.encodeIfPresent(notificationBody, forKey: .notificationBody)
        try values.encodeIfPresent(promptExpirationMinutes, forKey: .promptExpirationMinutes)
    }
}

private struct LegacySurveyAvailabilityConfiguration: Codable {
    let startDate: String?
    let endDate: String?
    let weekdays: [Int]
    let hour: Int
    let minute: Int
    let durationMinutes: Int
}

enum SurveyPresentationMode: String, Codable, Equatable, Sendable {
    case externalBrowser, inAppBrowser
}

struct SurveyAvailabilityWindowConfiguration: Codable, Equatable, Sendable {
    let opensMinutesBefore: Int
    let closesMinutesAfter: Int
}

struct SurveyCompletionCallbackConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
}

struct NotificationConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
    let rationale: String
}

struct ReminderConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let enabled: Bool
    let kind: ReminderKind
    let surveyID: String?
    let schedule: ReminderScheduleConfiguration?
    let notifyMinutesBefore: Int?
    let destination: NotificationDestinationConfiguration
    let activeStartDate: String?
    let activeEndDate: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, body, enabled, kind, surveyID, schedule, notifyMinutesBefore, destination, activeStartDate, activeEndDate
        case hour, minute, weekdays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        kind = try values.decode(ReminderKind.self, forKey: .kind)
        surveyID = try values.decodeIfPresent(String.self, forKey: .surveyID)
        notifyMinutesBefore = try values.decodeIfPresent(Int.self, forKey: .notifyMinutesBefore)
        activeStartDate = try values.decodeIfPresent(String.self, forKey: .activeStartDate)
        activeEndDate = try values.decodeIfPresent(String.self, forKey: .activeEndDate)
        if let explicit = try values.decodeIfPresent(ReminderScheduleConfiguration.self, forKey: .schedule) {
            schedule = explicit
        } else if values.contains(.hour) {
            let hour = try values.decode(Int.self, forKey: .hour)
            let minute = try values.decode(Int.self, forKey: .minute)
            let weekdays = try values.decode([Int].self, forKey: .weekdays)
            schedule = ReminderScheduleConfiguration(pattern: weekdays.count == 7 ? .daily : .selectedWeekdays, date: nil, hour: hour, minute: minute, weekdays: weekdays.count == 7 ? [] : weekdays)
        } else if kind == .survey, notifyMinutesBefore != nil {
            schedule = nil
        } else {
            schedule = nil
        }
        destination = try values.decodeIfPresent(NotificationDestinationConfiguration.self, forKey: .destination)
            ?? (kind == .survey ? .surveys : .home)
    }

    init(id: String, title: String, body: String, enabled: Bool, kind: ReminderKind, surveyID: String?, schedule: ReminderScheduleConfiguration?, notifyMinutesBefore: Int? = nil, destination: NotificationDestinationConfiguration, activeStartDate: String? = nil, activeEndDate: String? = nil) {
        self.id = id; self.title = title; self.body = body; self.enabled = enabled; self.kind = kind
        self.surveyID = surveyID; self.schedule = schedule; self.destination = destination
        self.notifyMinutesBefore = notifyMinutesBefore
        self.activeStartDate = activeStartDate; self.activeEndDate = activeEndDate
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(title, forKey: .title)
        try values.encode(body, forKey: .body); try values.encode(enabled, forKey: .enabled)
        try values.encode(kind, forKey: .kind); try values.encodeIfPresent(surveyID, forKey: .surveyID)
        try values.encodeIfPresent(schedule, forKey: .schedule)
        try values.encodeIfPresent(notifyMinutesBefore, forKey: .notifyMinutesBefore)
        try values.encode(destination, forKey: .destination)
        try values.encodeIfPresent(activeStartDate, forKey: .activeStartDate)
        try values.encodeIfPresent(activeEndDate, forKey: .activeEndDate)
    }
}

enum ReminderKind: String, Codable, Equatable, Sendable { case survey, message }

enum ReminderSchedulePattern: String, Codable, Equatable, Sendable { case oneTime, daily, selectedWeekdays, randomWindow }

/// What a schedule's time-of-day is computed relative to. `.clockTime` (the default, and the only
/// option prior to schemaVersion 6) uses `hour`/`minute` directly. `.wakeTime`/`.bedTime` instead derive
/// the day's base time from the participant's `sleepSchedule` (see `ParticipantState`) and add `offsetMinutes`.
enum ScheduleAnchor: String, Codable, Equatable, Sendable { case clockTime, wakeTime, bedTime }

struct ReminderScheduleConfiguration: Codable, Equatable, Sendable {
    let pattern: ReminderSchedulePattern
    let date: String?
    let hour: Int
    let minute: Int
    let weekdays: [Int]
    /// Absent (nil) is equivalent to `.clockTime` — see `resolvedAnchor`. Kept optional so schema 2-5
    /// configs that never mention this key continue decoding unchanged.
    let anchor: ScheduleAnchor?
    /// Minutes relative to `anchor`'s time (positive = after, negative = before). Only meaningful when
    /// `resolvedAnchor != .clockTime`; ignored otherwise.
    let offsetMinutes: Int?
    /// Only meaningful when `pattern == .randomWindow` — see `NotificationScheduleBuilder`'s
    /// randomWindow branch for the actual algorithm (every day split into `windowCount` windows of
    /// `windowLengthHours` starting at `windowStartHour`, one fire time picked at random within
    /// each). All three are non-nil together whenever `pattern == .randomWindow`; nil for every
    /// other pattern. Mirrors `reminderScheduleSchema`'s `randomWindow` member in study-schema.ts.
    let windowCount: Int?
    let windowStartHour: Int?
    let windowLengthHours: Int?

    var resolvedAnchor: ScheduleAnchor { anchor ?? .clockTime }

    init(pattern: ReminderSchedulePattern, date: String?, hour: Int, minute: Int, weekdays: [Int],
         anchor: ScheduleAnchor? = nil, offsetMinutes: Int? = nil,
         windowCount: Int? = nil, windowStartHour: Int? = nil, windowLengthHours: Int? = nil) {
        self.pattern = pattern; self.date = date; self.hour = hour; self.minute = minute
        self.weekdays = weekdays; self.anchor = anchor; self.offsetMinutes = offsetMinutes
        self.windowCount = windowCount; self.windowStartHour = windowStartHour; self.windowLengthHours = windowLengthHours
    }

    // `anchor`/`offsetMinutes` previously had inline default values (`= nil`) on these `let`
    // properties and relied on synthesized Codable — but Swift's synthesized decoder silently
    // NEVER decodes a `let` property that has an inline literal default, regardless of what's
    // actually present in the JSON. That made every wake/bed-anchored schedule silently decode
    // as `anchor: nil` → `.clockTime`, always falling back to the literal `hour`/`minute`
    // placeholder instead of the configured anchor. This explicit init/CodingKeys/encode fixes
    // that by decoding both fields via `decodeIfPresent` instead of relying on defaults. The three
    // window* fields added later follow the same rule: decodeIfPresent only, never an inline default.
    private enum CodingKeys: String, CodingKey {
        case pattern, date, hour, minute, weekdays, anchor, offsetMinutes
        case windowCount, windowStartHour, windowLengthHours
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try values.decode(ReminderSchedulePattern.self, forKey: .pattern)
        date = try values.decodeIfPresent(String.self, forKey: .date)
        hour = try values.decode(Int.self, forKey: .hour)
        minute = try values.decode(Int.self, forKey: .minute)
        weekdays = try values.decode([Int].self, forKey: .weekdays)
        anchor = try values.decodeIfPresent(ScheduleAnchor.self, forKey: .anchor)
        offsetMinutes = try values.decodeIfPresent(Int.self, forKey: .offsetMinutes)
        windowCount = try values.decodeIfPresent(Int.self, forKey: .windowCount)
        windowStartHour = try values.decodeIfPresent(Int.self, forKey: .windowStartHour)
        windowLengthHours = try values.decodeIfPresent(Int.self, forKey: .windowLengthHours)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pattern, forKey: .pattern)
        try values.encodeIfPresent(date, forKey: .date)
        try values.encode(hour, forKey: .hour)
        try values.encode(minute, forKey: .minute)
        try values.encode(weekdays, forKey: .weekdays)
        try values.encodeIfPresent(anchor, forKey: .anchor)
        try values.encodeIfPresent(offsetMinutes, forKey: .offsetMinutes)
        try values.encodeIfPresent(windowCount, forKey: .windowCount)
        try values.encodeIfPresent(windowStartHour, forKey: .windowStartHour)
        try values.encodeIfPresent(windowLengthHours, forKey: .windowLengthHours)
    }
}

enum NotificationDestinationConfiguration: String, Codable, Equatable, Sendable {
    case home, surveys, settings, aboutStudy
}

enum AppTab: String, Codable, Equatable, Sendable, CaseIterable {
    case home, surveys, sleep, media, about, settings
    var title: String { rawValue == "sleep" ? "See My Data" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .surveys: "checklist"
        case .sleep: "heart.text.square"
        case .media: "square.and.arrow.up"
        case .about: "info.circle"
        case .settings: "gearshape"
        }
    }

}

struct AppFeatureFlags: Codable, Equatable, Sendable {
    let surveysEnabled: Bool
    /// Deprecated — decoded for backward JSON compatibility only. The "See My Data" tab's real
    /// visibility is gated on `healthKit.enabled && !healthKit.identifiers.isEmpty` (MainTabView),
    /// never on this flag; removed from the dashboard wizard for the same reason.
    let sleepSummaryEnabled: Bool
    let mediaUploadsEnabled: Bool
    /// Deprecated — decoded for backward JSON compatibility only. No streaks feature exists
    /// anywhere in this app; removed from the dashboard wizard for the same reason.
    let streaksEnabled: Bool
    let visibleTabs: [AppTab]
}

struct MediaConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
    let instructions: String
    let privacyText: String
    let acceptedTypes: [MediaType]
    let maximumTotalItems: Int
    let maximumFileSizeMB: Int
    let maximumVideoLengthSeconds: Int?
    /// Deprecated — decoded for backward JSON compatibility only; never enforced (no blocking UI
    /// or completion gate reads it). Not exposed in the dashboard wizard for the same reason.
    let required: Bool
    let activeStartDate: String?
    let activeEndDate: String?
    let categories: [MediaCategoryConfiguration]

    private enum CodingKeys: String, CodingKey {
        case enabled, instructions, privacyText, acceptedTypes, maximumTotalItems, maximumFileSizeMB
        case maximumVideoLengthSeconds, required, activeStartDate, activeEndDate, categories
        case photoEnabled, videoEnabled, maximumItems, maximumSizeMB, submissionCategory, representedDateRequired
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        instructions = try values.decode(String.self, forKey: .instructions)
        if let explicit = try values.decodeIfPresent([MediaType].self, forKey: .acceptedTypes) {
            privacyText = try values.decode(String.self, forKey: .privacyText)
            acceptedTypes = explicit
            maximumTotalItems = try values.decode(Int.self, forKey: .maximumTotalItems)
            maximumFileSizeMB = try values.decode(Int.self, forKey: .maximumFileSizeMB)
            maximumVideoLengthSeconds = try values.decodeIfPresent(Int.self, forKey: .maximumVideoLengthSeconds)
            required = try values.decode(Bool.self, forKey: .required)
            activeStartDate = try values.decodeIfPresent(String.self, forKey: .activeStartDate)
            activeEndDate = try values.decodeIfPresent(String.self, forKey: .activeEndDate)
            categories = try values.decode([MediaCategoryConfiguration].self, forKey: .categories)
        } else {
            let photos = try values.decode(Bool.self, forKey: .photoEnabled)
            let videos = try values.decode(Bool.self, forKey: .videoEnabled)
            acceptedTypes = (photos ? [.photo] : []) + (videos ? [.video] : [])
            maximumTotalItems = try values.decodeIfPresent(Int.self, forKey: .maximumItems) ?? 1
            maximumFileSizeMB = try values.decodeIfPresent(Int.self, forKey: .maximumSizeMB) ?? 25
            maximumVideoLengthSeconds = nil; required = false; activeStartDate = nil; activeEndDate = nil
            privacyText = "Selected media remains on this device in this prototype."
            let category = try values.decodeIfPresent(String.self, forKey: .submissionCategory) ?? "general"
            let represented = try values.decodeIfPresent(Bool.self, forKey: .representedDateRequired) ?? false
            categories = [.init(id: category, displayName: category.replacingOccurrences(of: "-", with: " ").capitalized,
                                description: instructions, acceptedTypes: acceptedTypes, required: false,
                                maximumItems: maximumTotalItems, representedDateRequired: represented)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled); try values.encode(instructions, forKey: .instructions)
        try values.encode(privacyText, forKey: .privacyText); try values.encode(acceptedTypes, forKey: .acceptedTypes)
        try values.encode(maximumTotalItems, forKey: .maximumTotalItems); try values.encode(maximumFileSizeMB, forKey: .maximumFileSizeMB)
        try values.encodeIfPresent(maximumVideoLengthSeconds, forKey: .maximumVideoLengthSeconds)
        try values.encode(required, forKey: .required); try values.encodeIfPresent(activeStartDate, forKey: .activeStartDate)
        try values.encodeIfPresent(activeEndDate, forKey: .activeEndDate); try values.encode(categories, forKey: .categories)
    }
}

struct MediaCategoryConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let acceptedTypes: [MediaType]
    /// Deprecated — decoded for backward JSON compatibility only; never enforced. Don't confuse
    /// with the unrelated (and functional) `ParticipantIDConfiguration.required`.
    let required: Bool
    let maximumItems: Int
    let representedDateRequired: Bool
}

struct SupportContact: Codable, Equatable, Sendable {
    let name: String
    let email: String
    let phone: String?
    let website: String?
}

struct FAQItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let question: String
    let answer: String
}

struct CompletionConfiguration: Codable, Equatable, Sendable {
    let title: String
    let message: String
    let redirectURL: String?
    let appAccessRemainsAvailable: Bool
}
