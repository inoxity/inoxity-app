import Foundation

/// Participant-relative study progress for the Home screen — always computed relative to this
/// individual participant's own enrollment date, never the study-wide calendar window
/// (`StudySchedule.startDate`/`endDate`), since participants can enroll at different times under
/// rolling enrollment and the global window may not line up with any one participant's own days.
enum StudyProgress: Equatable {
    /// A fixed participant duration is configured (`StudySchedule.participantDurationDays`).
    /// Applies identically whether the underlying study uses rolling or fixed-cohort enrollment —
    /// progress is always relative to this participant's own start date, not the study's.
    /// `day` is 1-based and clamped to `1...total`; `progress` is clamped to `0...1`.
    case dayOfN(day: Int, total: Int, progress: Double)
    /// No fixed participant duration is configured, but the participant's start date is known.
    case dayCount(day: Int)
    /// Neither a fixed duration nor a start date is available.
    case active
    /// The participant's resolved start date (see `ParticipantStartDateResolver`) is still in the
    /// future — only reachable under `StartDateMode.fixed`/`.participantSelected`, since
    /// `.enrollment`'s start date is stamped at the moment of enrollment and so can never itself be
    /// in the future. Day-in-study math doesn't apply yet; the app shows a waiting state instead
    /// (see `WaitingForStudyStartView`) rather than the "Day 1" that `dayNumber`'s old unconditional
    /// `max(1, ...)` clamp used to display for a not-yet-started participant.
    case notYetStarted(startsOn: Date)

    /// - Parameters:
    ///   - startDate: The participant's resolved start date (`ParticipantStartDateResolver.resolve`),
    ///     or `nil` before it's resolvable at all (e.g. a `.participantSelected` study before that
    ///     onboarding step runs).
    ///   - participantDurationDays: `StudyConfiguration.schedule.participantDurationDays`. When
    ///     `nil`, `StudySchedule.startDate`/`endDate` are deliberately never consulted as a
    ///     substitute here — those describe the study-wide calendar window, which can misrepresent
    ///     an individual participant's progress under rolling enrollment, so falling back to
    ///     `.dayCount`/`.active` instead of a fabricated percentage is the safer default.
    static func current(
        startDate: Date?,
        participantDurationDays: Int?,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> StudyProgress {
        guard let startDate else { return .active }
        if calendar.startOfDay(for: now) < calendar.startOfDay(for: startDate) { return .notYetStarted(startsOn: startDate) }
        let dayNumber = Self.dayNumber(startDate: startDate, calendar: calendar, now: now)

        guard let total = participantDurationDays, total > 0 else {
            return .dayCount(day: dayNumber)
        }
        let clampedDay = min(dayNumber, total)
        let progress = min(max(Double(clampedDay) / Double(total), 0), 1)
        return .dayOfN(day: clampedDay, total: total, progress: progress)
    }

    /// True once the participant's uncapped day number has advanced past a configured fixed
    /// participant duration — i.e. they've completed the study. Always false for open-ended studies
    /// (`participantDurationDays` nil/<=0, consistent with `.dayCount` above never fabricating an
    /// end), before a start date resolves, or while still `.notYetStarted`. Deliberately separate
    /// from `current(...)`, which clamps `dayNumber` to `total` for display and so can never itself
    /// signal having gone past it.
    static func isPastParticipantDuration(
        startDate: Date?,
        participantDurationDays: Int?,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Bool {
        guard let startDate, let total = participantDurationDays, total > 0,
              calendar.startOfDay(for: now) >= calendar.startOfDay(for: startDate) else { return false }
        return Self.dayNumber(startDate: startDate, calendar: calendar, now: now) > total
    }

    // Day 1 = the calendar day of the resolved start date. Callers are expected to have already
    // checked `now >= startDate` (see `current(...)`/`isPastParticipantDuration` above) — this no
    // longer clamps a negative `daysElapsed` up to day 1 itself, since that used to silently
    // display "Day 1" for a still-in-the-future start date instead of a waiting state.
    private static func dayNumber(startDate: Date, calendar: Calendar, now: Date) -> Int {
        let daysElapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: startDate),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return daysElapsed + 1
    }

    var title: String {
        switch self {
        case .dayOfN(let day, let total, _): "Day \(day) of \(total)"
        case .dayCount(let day): "Day \(day) in the study"
        case .active: "Study active"
        case .notYetStarted: "Study hasn't started yet"
        }
    }

    /// Non-nil only for `.dayOfN` — the view uses this to decide whether a progress bar makes
    /// sense to show at all (never fabricated for `.dayCount`/`.active`).
    var fractionComplete: Double? {
        if case .dayOfN(_, _, let progress) = self { progress } else { nil }
    }

    /// Non-nil only for `.dayOfN` — `(day, total)` for rendering a center label alongside
    /// `fractionComplete` (e.g. a progress ring), without the view needing to pattern-match the enum.
    var dayAndTotal: (day: Int, total: Int)? {
        if case .dayOfN(let day, let total, _) = self { (day, total) } else { nil }
    }
}
