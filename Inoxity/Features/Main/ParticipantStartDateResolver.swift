import Foundation

/// Resolves which single date counts as "day 1" for a participant — see `StartDateMode` for what
/// each of the study's three configured modes means. Used by `StudyProgress` (the Home-screen day
/// count and the pre-start waiting gate) and `NotificationScheduleBuilder` (so no notification is
/// ever scheduled before a future participant-selected start date).
enum ParticipantStartDateResolver {
    /// `nil` only when the mode requires a date that isn't available yet:
    /// - `.fixed` with no `schedule.startDate` configured — `StudyConfigurationValidator` already
    ///   rejects this at config-load time, so it shouldn't happen in practice, but resolving
    ///   defensively to `nil` (rather than silently falling back to another mode) is safer than
    ///   guessing.
    /// - `.participantSelected` before `ParticipantStartDateView` has run yet (mid-onboarding).
    ///
    /// Callers should treat `nil` as "not yet resolvable" — e.g. `StudyProgress.current` falls
    /// back to `.active` for it, the same as it already does for a wholly-unknown enrollment date.
    static func resolve(
        schedule: StudySchedule,
        participant: ParticipantState,
        calendar: Calendar = .current
    ) -> Date? {
        switch schedule.resolvedStartDateMode {
        case .enrollment:
            return participant.enrollmentDate
        case .fixed:
            return date(schedule.startDate, calendar: calendar)
        case .participantSelected:
            return participant.participantSelectedStartDate
        }
    }

    // Same "YYYY-MM-DD" parsed as midnight in the given (participant-local) calendar convention
    // `NotificationScheduleBuilder`/`SurveyOccurrenceBuilder` already use for this exact field —
    // deliberately not `StudyConfigurationValidator.dateFormatter`, which fixes UTC for a
    // different purpose (the study-wide calendar-window check at config-load time).
    private static func date(_ value: String?, calendar: Calendar) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
