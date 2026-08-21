import Foundation

/// A single calendar day's worth of readable Apple Health data, for the "See My Data" page's
/// day-by-day navigation — unlike `HealthSummarySnapshot` (a rolling 30-day aggregate with
/// latest/7-day/30-day framing), this is scoped to exactly one day, so it reuses the same
/// underlying quantity/workout shapes where they still make sense (`QuantityMetricSummary`,
/// `WorkoutSummary`) but flattens the daily-cumulative metrics and sleep summary down to a
/// single value for that one day. Generic across every configured identifier, same reasoning as
/// `HealthSummarySnapshot` — see that type's doc comment.
struct DailyHealthSnapshot: Equatable, Sendable {
    let day: Date // start-of-day, in the participant's current local timezone
    let configuredMetrics: Set<String>
    var sleepDuration: TimeInterval?
    var quantities: [String: QuantityMetricSummary] = [:]
    var dailyTotals: [String: Double] = [:]
    var categoryCounts: [String: Int] = [:]
    var workouts: WorkoutSummary?
    var unavailableMetrics: Set<String> = []

    var hasData: Bool {
        sleepDuration != nil || !quantities.isEmpty || !dailyTotals.isEmpty || !categoryCounts.isEmpty || workouts != nil
    }
}

enum DailyHealthSummaryRuntimeStatus: Equatable, Sendable {
    case idle, loading, loaded(DailyHealthSnapshot), failed(String)
}
