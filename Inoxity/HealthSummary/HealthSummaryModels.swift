import Foundation

enum HealthSleepState: Equatable, Sendable { case asleep, awake, inBed }

struct HealthSleepSample: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let state: HealthSleepState
}

struct HealthQuantityPoint: Equatable, Sendable { let date: Date; let value: Double }
struct HealthDailyValue: Equatable, Sendable { let day: Date; let value: Double }
struct HealthWorkoutRecord: Equatable, Sendable { let startDate: Date; let endDate: Date; var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) } }

struct SleepSummary: Equatable, Sendable {
    let latestDuration: TimeInterval
    let latestDate: Date
    let sevenDayAverage: TimeInterval?
    let thirtyDayAverage: TimeInterval
    let recordCount: Int
}

struct QuantityMetricSummary: Equatable, Sendable {
    let latest: Double
    let average: Double
    let minimum: Double?
    let maximum: Double?
    let unit: String
}

struct DailyMetricSummary: Equatable, Sendable {
    let today: Double
    let yesterday: Double?
    let sevenDayAverage: Double
    let unit: String
}

struct WorkoutSummary: Equatable, Sendable { let count: Int; let totalDuration: TimeInterval }

/// A rolling 30-day Apple Health summary, generic across every identifier a study configures
/// (`StudyConfiguration.healthKit.identifiers`) rather than one named field per metric — the
/// previous 10-metric-max design (a fixed enum + one hardcoded optional field per case) doesn't
/// scale to the full HealthKit catalog. `sleep`/`workouts` stay their own dedicated fields since
/// both have a genuinely different shape from an ordinary quantity/category summary; every other
/// configured metric lands in `quantities` (latest-value-style, e.g. heart rate) or
/// `dailyCumulative` (running-total-style, e.g. steps) keyed by its HealthKit identifier string,
/// looked up generically via `HealthKitTypeRegistry` for display label/symbol/unit. Category
/// types beyond sleep (symptoms, reproductive health, heart-rhythm events) report through
/// `categoryCounts` — how many samples occurred in the window, the same "count, don't fabricate a
/// number that doesn't make sense for the type" treatment workouts already got.
struct HealthSummarySnapshot: Equatable, Sendable {
    let generatedAt: Date
    let configuredMetrics: Set<String>
    var sleep: SleepSummary?
    var quantities: [String: QuantityMetricSummary] = [:]
    var dailyCumulative: [String: DailyMetricSummary] = [:]
    var categoryCounts: [String: Int] = [:]
    var workouts: WorkoutSummary?
    var unavailableMetrics: Set<String> = []

    var hasData: Bool {
        sleep != nil || !quantities.isEmpty || !dailyCumulative.isEmpty || !categoryCounts.isEmpty || workouts != nil
    }
}

enum HealthSummaryRuntimeStatus: Equatable, Sendable {
    case idle, loading, loaded(HealthSummarySnapshot), failed(String)
}

enum HealthSummaryError: Error, Equatable, LocalizedError, Sendable {
    case unavailable, withdrawn, noConfiguredMetrics, queryFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is unavailable on this device."
        case .withdrawn: "Apple Health summaries are unavailable for a withdrawn enrollment."
        case .noConfiguredMetrics: "This study does not request Apple Health data."
        case .queryFailed: "Apple Health data could not be refreshed. Please try again."
        }
    }
}
