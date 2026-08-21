import Foundation

/// The DOSE-inspired EMA windowed-random algorithm, shared by `NotificationScheduleBuilder`
/// (message reminders, and resolving a survey's own schedule to derive a linked reminder's fire
/// time) and `SurveyOccurrenceBuilder` (a survey's own `.randomWindow` occurrence times). Both
/// callers MUST produce identical results for the same `(seedKey, day)` — `SurveyOccurrenceBuilder`
/// throws `.inconsistentPersistedState` if a rebuilt occurrence's time ever drifts from what's
/// already persisted, and a notification whose fire time disagrees with the survey's own actual
/// occurrence time would carry an occurrence ID `SurveyOccurrenceBuilder` never itself generates
/// (an `unknownOccurrence` error when the participant taps it). Extracted into one shared place
/// specifically so there's only one implementation to keep in sync, rather than two independently
/// duplicated ones — this is safety-critical, not just DRY-for-its-own-sake.
enum RandomWindowScheduling {
    /// Splits `day` into `schedule.windowCount` windows of `schedule.windowLengthHours` starting
    /// at `schedule.windowStartHour`, and picks one random fire time inside each — deterministic
    /// per `(studyID, seedKey, day, window index)`, so repeated calls for the same day/seed always
    /// reproduce the exact same times (no reshuffling on every reconciliation/rebuild), while
    /// different days/seeds still diverge freely. `studyID` is included so two different studies
    /// whose researchers happen to reuse the same reminder/survey ID slug (e.g. both naming one
    /// "morning-reminder") don't randomize identically. `seedKey` must be the SAME identifier the
    /// underlying entity is otherwise addressed by — a reminder's own `.randomWindow` schedule
    /// seeds with that reminder's `id`; resolving a SURVEY's schedule (whether from
    /// `SurveyOccurrenceBuilder` itself or from `NotificationScheduleBuilder` announcing it via a
    /// linked reminder) must always seed with that survey's `id`, never the reminder's.
    static func occurrences(on day: Date, schedule: ReminderScheduleConfiguration, calendar: Calendar, studyID: String, seedKey: String) -> [Date] {
        guard let windowCount = schedule.windowCount, let windowStartHour = schedule.windowStartHour,
              let windowLengthHours = schedule.windowLengthHours, windowCount > 0, windowLengthHours > 0 else { return [] }
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let daySeed = "\(studyID)|\(seedKey)|\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        var results = [Date]()
        for window in 0..<windowCount {
            let windowStart = windowStartHour + window * windowLengthHours
            guard windowStart < 24 else { continue } // defensive — StudyConfigurationValidator already rejects windowCount*windowLengthHours > 24
            let windowEnd = min(windowStart + windowLengthHours, 24)
            var generator = SeededGenerator(seed: fnv1aValue("\(daySeed)|\(window)"))
            let hour = Int.random(in: windowStart..<windowEnd, using: &generator)
            let minute = Int.random(in: 0..<60, using: &generator)
            if let occurrence = clockTimeOccurrence(on: day, hour: hour, minute: minute, calendar: calendar) {
                results.append(occurrence)
            }
        }
        return results
    }

    private static func clockTimeOccurrence(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute
        if let exact = calendar.date(from: components) { return exact }
        return calendar.nextDate(after: calendar.startOfDay(for: day), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private static func fnv1aValue(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return hash
    }
}

/// Deterministic `RandomNumberGenerator` (splitmix64) — same seed always produces the same
/// sequence, which is exactly what `RandomWindowScheduling.occurrences` needs: a given day's
/// random fire times must stay stable across repeated calls.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
