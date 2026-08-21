import Foundation

@MainActor
protocol HealthDataQuerying: AnyObject {
    var isAvailable: Bool { get }
    func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample]
    func quantitySamples(for identifier: String, in interval: DateInterval) async throws -> [HealthQuantityPoint]
    func dailyCumulativeValues(for identifier: String, in interval: DateInterval, calendar: Calendar) async throws -> [HealthDailyValue]
    func workouts(in interval: DateInterval) async throws -> [HealthWorkoutRecord]
    /// Sample count for any category-kind identifier other than sleep (symptoms, reproductive
    /// health, heart-rhythm events, ...) — sleep keeps its own dedicated `sleepSamples` query
    /// since it needs the actual sample intervals/states, not just a count.
    func categorySampleCount(for identifier: String, in interval: DateInterval) async throws -> Int
}
