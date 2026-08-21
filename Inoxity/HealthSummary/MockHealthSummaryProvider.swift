import Foundation

@MainActor
final class MockHealthSummaryProvider: HealthSummaryProviding {
    var result: Result<HealthSummarySnapshot, Error>
    var dailyResult: Result<DailyHealthSnapshot, Error> = .failure(HealthSummaryError.noConfiguredMetrics)
    private(set) var requests: [(StudyConfiguration, ParticipantState)] = []
    private(set) var dailyRequests: [(StudyConfiguration, ParticipantState, Date)] = []
    init(result: Result<HealthSummarySnapshot, Error> = .failure(HealthSummaryError.noConfiguredMetrics)) { self.result = result }
    func snapshot(configuration: StudyConfiguration, participant: ParticipantState) async throws -> HealthSummarySnapshot {
        requests.append((configuration, participant)); return try result.get()
    }
    func dailySnapshot(configuration: StudyConfiguration, participant: ParticipantState, day: Date, timeZone: TimeZone?) async throws -> DailyHealthSnapshot {
        dailyRequests.append((configuration, participant, day)); return try dailyResult.get()
    }
}

@MainActor
final class MockHealthDataQueryService: HealthDataQuerying {
    var isAvailable = true
    var sleepResult: Result<[HealthSleepSample], Error> = .success([])
    var quantityResults: [String: Result<[HealthQuantityPoint], Error>] = [:]
    var dailyResults: [String: Result<[HealthDailyValue], Error>] = [:]
    var workoutResult: Result<[HealthWorkoutRecord], Error> = .success([])
    var categoryCountResults: [String: Result<Int, Error>] = [:]
    /// Every interval `sleepSamples(in:)` was actually queried with — lets a test assert
    /// `HealthSummaryService.dailySnapshot`'s sleep case queries a lookback-padded interval (see
    /// `HealthSummaryService.sleepQueryInterval`), not just that its post-processing is correct.
    private(set) var sleepQueryIntervals: [DateInterval] = []
    func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample] { sleepQueryIntervals.append(interval); return try sleepResult.get() }
    func quantitySamples(for identifier: String, in interval: DateInterval) async throws -> [HealthQuantityPoint] { try quantityResults[identifier, default: .success([])].get() }
    func dailyCumulativeValues(for identifier: String, in interval: DateInterval, calendar: Calendar) async throws -> [HealthDailyValue] { try dailyResults[identifier, default: .success([])].get() }
    func workouts(in interval: DateInterval) async throws -> [HealthWorkoutRecord] { try workoutResult.get() }
    func categorySampleCount(for identifier: String, in interval: DateInterval) async throws -> Int { try categoryCountResults[identifier, default: .success(0)].get() }
}
