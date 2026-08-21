import Foundation
import HealthKit

@MainActor
final class HealthKitHealthDataQueryService: HealthDataQuerying {
    private let store: HKHealthStore
    init(store: HKHealthStore = HKHealthStore()) { self.store = store }
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let samples: [HKCategorySample] = try await samples(type: type, interval: interval)
        return samples.compactMap { sample in
            let state: HealthSleepState?
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue: state = .inBed
            case HKCategoryValueSleepAnalysis.awake.rawValue: state = .awake
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                 HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue: state = .asleep
            default: state = nil
            }
            return state.map { .init(startDate: sample.startDate, endDate: sample.endDate, state: $0) }
        }
    }

    func quantitySamples(for identifier: String, in interval: DateInterval) async throws -> [HealthQuantityPoint] {
        let (type, unit) = try quantityMetadata(identifier)
        let samples: [HKQuantitySample] = try await samples(type: type, interval: interval)
        return samples.map { .init(date: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    func dailyCumulativeValues(for identifier: String, in interval: DateInterval, calendar: Calendar) async throws -> [HealthDailyValue] {
        let (type, unit) = try quantityMetadata(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let anchor = calendar.startOfDay(for: interval.start)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: anchor,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var result: [HealthDailyValue] = []
                collection?.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
                    if let value = statistics.sumQuantity()?.doubleValue(for: unit) {
                        result.append(.init(day: calendar.startOfDay(for: statistics.startDate), value: value))
                    }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    func workouts(in interval: DateInterval) async throws -> [HealthWorkoutRecord] {
        let samples: [HKWorkout] = try await samples(type: HKObjectType.workoutType(), interval: interval)
        return samples.map { .init(startDate: $0.startDate, endDate: $0.endDate) }
    }

    func categorySampleCount(for identifier: String, in interval: DateInterval) async throws -> Int {
        let metadata = try HealthKitTypeRegistry.type(for: identifier)
        guard let type = metadata.objectType as? HKCategoryType else { throw HealthSummaryError.queryFailed }
        let samples: [HKCategorySample] = try await samples(type: type, interval: interval)
        return samples.count
    }

    private func samples<T: HKSample>(type: HKSampleType, interval: DateInterval) async throws -> [T] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples as? [T] ?? [])
            }
            store.execute(query)
        }
    }

    // Reads straight off HealthKitTypeRegistry instead of maintaining a second, separately-kept
    // identifier→(type, unit) switch.
    private func quantityMetadata(_ identifier: String) throws -> (HKQuantityType, HKUnit) {
        guard let metadata = try? HealthKitTypeRegistry.type(for: identifier),
              let type = metadata.objectType as? HKQuantityType, let unit = metadata.unit
        else { throw HealthSummaryError.queryFailed }
        return (type, unit)
    }
}
