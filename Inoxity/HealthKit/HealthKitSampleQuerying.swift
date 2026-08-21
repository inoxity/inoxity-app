import Foundation
import HealthKit

protocol HealthKitSampleQuerying: Sendable {
    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage
}

enum HealthKitAnchorCodec {
    static func encode(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }
    static func decode(_ data: Data?) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        do { return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) }
        catch { throw HealthKitUploadError.malformedCursor }
    }
}

final class HealthKitAnchoredSampleQueryService: HealthKitSampleQuerying, @unchecked Sendable {
    private let store: HKHealthStore
    init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage {
        guard limit > 0, limit <= HealthKitUploadPolicy.phase3D.maximumQueryPageSize else { throw HealthKitUploadError.invalidBatchSize }
        let metadata = try HealthKitTypeRegistry.type(for: identifier)
        guard let sampleType = metadata.objectType as? HKSampleType else { throw HealthKitUploadError.unsupportedIdentifier(identifier) }
        let decoded = try HealthKitAnchorCodec.decode(anchor)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: sampleType, predicate: predicate, anchor: decoded, limit: limit) { _, added, deleted, newAnchor, error in
                if error != nil { continuation.resume(throwing: HealthKitUploadError.unavailable); return }
                guard let newAnchor else { continuation.resume(throwing: HealthKitUploadError.malformedCursor); return }
                do {
                    let samples = try (added ?? []).compactMap { try Self.map($0, identifier: identifier) }
                    continuation.resume(returning: .init(samples: samples, nextAnchor: try HealthKitAnchorCodec.encode(newAnchor),
                        hasMore: (added?.count ?? 0) + (deleted?.count ?? 0) >= limit,
                        ignoredDeletionCount: deleted?.count ?? 0))
                } catch { continuation.resume(throwing: error) }
            }
            self.store.execute(query)
        }
    }

    private static func map(_ sample: HKSample, identifier: String) throws -> HealthKitRawSample? {
        let metadata = try HealthKitTypeRegistry.type(for: identifier)
        let zone = timeZoneIdentifier(for: sample)
        // Dispatches on the registry's own sampleKind rather than identifier-literal checks
        // (the old `identifier == "sleepAnalysis"`/`"workout"`) — generalizes to every category/
        // quantity/workout identifier now in the registry, not just the original two.
        if let quantity = sample as? HKQuantitySample, metadata.sampleKind == .quantity, let unit = metadata.canonicalUploadUnit {
            let hkUnit: HKUnit = metadata.unit ?? .count()
            return .init(uuid: sample.uuid, identifier: identifier, kind: .quantity, start: sample.startDate, end: sample.endDate,
                         timeZoneIdentifier: zone, quantityValue: quantity.quantity.doubleValue(for: hkUnit), canonicalUnit: unit,
                         categoryValue: nil, workoutActivityType: nil, workoutDurationSeconds: nil)
        }
        if let category = sample as? HKCategorySample, metadata.sampleKind == .category {
            return .init(uuid: sample.uuid, identifier: identifier, kind: .category, start: sample.startDate, end: sample.endDate,
                         timeZoneIdentifier: zone, quantityValue: nil, canonicalUnit: nil, categoryValue: category.value,
                         workoutActivityType: nil, workoutDurationSeconds: nil)
        }
        if let workout = sample as? HKWorkout, metadata.sampleKind == .workout {
            return .init(uuid: sample.uuid, identifier: identifier, kind: .workout, start: sample.startDate, end: sample.endDate,
                         timeZoneIdentifier: zone, quantityValue: nil, canonicalUnit: nil, categoryValue: nil,
                         workoutActivityType: workout.workoutActivityType.rawValue,
                         workoutDurationSeconds: workout.duration)
        }
        // Only "bloodPressure" exists as a .correlation identifier today — its two-value shape
        // (systolic+diastolic) is specific enough that this stays a dedicated branch rather than
        // a fully generic one, unlike quantity/category/workout above.
        if let correlation = sample as? HKCorrelation, metadata.sampleKind == .correlation, identifier == "bloodPressure" {
            guard let systolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
                  let diastolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
                  let systolicSample = correlation.objects(for: systolicType).first as? HKQuantitySample,
                  let diastolicSample = correlation.objects(for: diastolicType).first as? HKQuantitySample
            else { throw HealthKitUploadError.invalidSample }
            let unit = HKUnit.millimeterOfMercury()
            return .init(uuid: sample.uuid, identifier: identifier, kind: .correlation, start: sample.startDate, end: sample.endDate,
                         timeZoneIdentifier: zone, quantityValue: systolicSample.quantity.doubleValue(for: unit), canonicalUnit: metadata.canonicalUploadUnit,
                         categoryValue: nil, workoutActivityType: nil, workoutDurationSeconds: nil,
                         secondaryQuantityValue: diastolicSample.quantity.doubleValue(for: unit))
        }
        throw HealthKitUploadError.invalidSample
    }

    /// Prefers the sample's own `HKMetadataKeyTimeZone` — the zone the *source* recorded it was
    /// captured in — over the current device zone, since HealthKit samples are routinely
    /// backfilled well after the fact (see `HealthKitUploadPolicy.initialHistoryDays`) from a
    /// device that may have since traveled. Not every source populates this key, so falling back
    /// to `.current` is the best available answer when it's absent, not a guess about the past.
    private static func timeZoneIdentifier(for sample: HKSample) -> String {
        (sample.metadata?[HKMetadataKeyTimeZone] as? String) ?? TimeZone.current.identifier
    }
}
