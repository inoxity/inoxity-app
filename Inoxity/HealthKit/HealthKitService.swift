import Foundation
import HealthKit

@MainActor
final class HealthKitService: HealthKitServicing {
    private let healthStore: HKHealthStore
    private let now: () -> Date

    init(healthStore: HKHealthStore = HKHealthStore(), now: @escaping () -> Date = Date.init) {
        self.healthStore = healthStore
        self.now = now
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestReadAuthorization(for identifiers: Set<String>, includeCharacteristics: Bool) async throws -> HealthKitAuthorizationRequestResult {
        guard isHealthDataAvailable else { throw HealthKitServiceError.unavailable }
        guard !identifiers.isEmpty else { throw HealthKitServiceError.emptyReadSet }
        var types = try Set(HealthKitTypeRegistry.types(for: identifiers).map(\.objectType))
        if includeCharacteristics { types.formUnion(Self.characteristicTypes) }
        try await healthStore.requestAuthorization(toShare: [], read: types)
        return .completed
    }

    func requestStatus(for identifiers: Set<String>, includeCharacteristics: Bool) async throws -> HealthKitAuthorizationPreCheck {
        guard isHealthDataAvailable else { throw HealthKitServiceError.unavailable }
        guard !identifiers.isEmpty else { throw HealthKitServiceError.emptyReadSet }
        // Deliberately excludes characteristicTypes and any .correlation-kind registry entry
        // (currently just bloodPressure), unlike requestReadAuthorization below.
        // getRequestStatusForAuthorization(toShare:read:) doesn't support HKCharacteristicType or
        // HKCorrelationType in its type sets at all — passing either raises an uncatchable
        // Objective-C exception from HealthKit's own
        // `_throwIfAuthorizationDisallowedForSharing:types:` (crashes the process before the
        // completion handler runs, so no Swift try/catch — even `try?` — can save it). This is
        // only a pre-check for prompt-skipping messaging; requestReadAuthorization is the call
        // that actually needs both of those in its read set, and that API does support them.
        let types = try Set(HealthKitTypeRegistry.types(for: identifiers)
            .filter { $0.sampleKind != .correlation }
            .map(\.objectType))
        return try await withCheckedThrowingContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: types) { status, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                switch status {
                case .shouldRequest: continuation.resume(returning: .shouldRequest)
                case .unnecessary: continuation.resume(returning: .unnecessary)
                case .unknown: continuation.resume(returning: .unknown)
                @unknown default: continuation.resume(returning: .unknown)
                }
            }
        }
    }

    func syncLocalData(for identifiers: Set<String>, interval: DateInterval) async throws -> HealthKitLocalSyncSummary {
        guard isHealthDataAvailable else { throw HealthKitServiceError.unavailable }
        guard !identifiers.isEmpty else { throw HealthKitServiceError.emptyReadSet }
        let metadata = try HealthKitTypeRegistry.types(for: identifiers)
        var metrics: [HealthKitLocalMetric] = []
        for item in metadata {
            metrics.append(try await query(item, interval: interval))
        }
        return HealthKitLocalSyncSummary(completedAt: now(), metrics: metrics)
    }

    // Dispatches on the registry's own aggregationStrategy rather than an identifier-literal
    // switch — generalizes to every quantity/category/workout identifier in the registry, not
    // just the original ten. (.correlation types have aggregationStrategy .none and fall through
    // to unsupportedIdentifier here — this local-summary path doesn't cover them yet, see
    // HealthKitTypeRegistry's doc comment on the correlations group.)
    private func query(_ metadata: HealthKitTypeMetadata, interval: DateInterval) async throws -> HealthKitLocalMetric {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        switch metadata.aggregationStrategy {
        case .cumulativeDaily:
            return try await cumulativeMetric(metadata, predicate: predicate)
        case .latestValue:
            return try await latestQuantityMetric(metadata, predicate: predicate)
        case .sampleCount:
            return try await sampleCountMetric(metadata, predicate: predicate)
        case .none:
            throw HealthKitServiceError.unsupportedIdentifier(metadata.identifier)
        }
    }

    private func cumulativeMetric(_ metadata: HealthKitTypeMetadata, predicate: NSPredicate) async throws -> HealthKitLocalMetric {
        guard let type = metadata.objectType as? HKQuantityType, let unit = metadata.unit else {
            throw HealthKitServiceError.queryFailed("Invalid quantity metadata for \(metadata.identifier).")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error { continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription)); return }
                let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: HealthKitLocalMetric(identifier: metadata.identifier, label: metadata.displayLabel, value: self.formatted(value, metadata: metadata)))
            }
            healthStore.execute(query)
        }
    }

    private func latestQuantityMetric(_ metadata: HealthKitTypeMetadata, predicate: NSPredicate) async throws -> HealthKitLocalMetric {
        guard let type = metadata.objectType as? HKQuantityType, let unit = metadata.unit else {
            throw HealthKitServiceError.queryFailed("Invalid quantity metadata for \(metadata.identifier).")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription)); return }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: HealthKitLocalMetric(identifier: metadata.identifier, label: metadata.displayLabel, value: self.formatted(value, metadata: metadata)))
            }
            healthStore.execute(query)
        }
    }

    private func sampleCountMetric(_ metadata: HealthKitTypeMetadata, predicate: NSPredicate) async throws -> HealthKitLocalMetric {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: metadata.objectType as! HKSampleType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription)); return }
                let count = samples?.count ?? 0
                let noun = metadata.identifier == "workout" ? "workout" : "sample"
                continuation.resume(returning: HealthKitLocalMetric(identifier: metadata.identifier, label: metadata.displayLabel, value: "\(count) \(noun)\(count == 1 ? "" : "s")"))
            }
            healthStore.execute(query)
        }
    }

    // Formats generically from the registry's displayPrecision/canonicalUploadUnit instead of a
    // per-identifier switch — a deliberate simplification versus hand-tuning wording for ~115
    // identifiers (e.g. "150 steps" is still exactly right, "150 count" for a less common metric
    // reads a bit plainer than fully natural-language phrasing would, but is unambiguous).
    private func formatted(_ value: Double?, metadata: HealthKitTypeMetadata) -> String {
        guard let value else { return "No local data found" }
        let number = String(format: "%.\(metadata.displayPrecision)f", value)
        guard let unit = metadata.canonicalUploadUnit else { return number }
        return "\(number) \(unit)"
    }

    // Force-unwrapped like HealthKitTypeRegistry's own entries — these five identifiers are
    // guaranteed valid on every OS version this app supports. Only unioned into a
    // read-authorization request when the caller passes `includeCharacteristics: true` (driven by
    // `HealthKitConfiguration.includeCharacteristics`) — previously these were included
    // unconditionally, which meant every study prompted participants for them regardless of
    // whether the study's configuration actually selected them.
    private static let characteristicTypes: Set<HKObjectType> = [
        HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        HKObjectType.characteristicType(forIdentifier: .bloodType)!,
        HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
        HKObjectType.characteristicType(forIdentifier: .fitzpatrickSkinType)!,
        HKObjectType.characteristicType(forIdentifier: .wheelchairUse)!,
    ]

    // Each of HKHealthStore's characteristic getters is synchronous and throws (rather than the
    // async-callback shape every sample query above uses) — `try?` per field so one unauthorized
    // or unset characteristic doesn't blank out the others.
    func readCharacteristics() -> HealthKitCharacteristics {
        var result = HealthKitCharacteristics()
        if let sex = try? healthStore.biologicalSex(), sex.biologicalSex != .notSet {
            result.biologicalSex = Self.label(sex.biologicalSex)
        }
        if let blood = try? healthStore.bloodType(), blood.bloodType != .notSet {
            result.bloodType = Self.label(blood.bloodType)
        }
        if let components = try? healthStore.dateOfBirthComponents() {
            result.dateOfBirth = Calendar(identifier: .gregorian).date(from: components)
        }
        if let skin = try? healthStore.fitzpatrickSkinType(), skin.skinType != .notSet {
            result.fitzpatrickSkinType = Self.label(skin.skinType)
        }
        if let wheelchair = try? healthStore.wheelchairUse(), wheelchair.wheelchairUse != .notSet {
            result.usesWheelchair = wheelchair.wheelchairUse == .yes
        }
        return result
    }

    private static func label(_ value: HKBiologicalSex) -> String? {
        switch value {
        case .female: return "female"
        case .male: return "male"
        case .other: return "other"
        case .notSet: return nil
        @unknown default: return nil
        }
    }

    private static func label(_ value: HKBloodType) -> String? {
        switch value {
        case .aPositive: return "aPositive"
        case .aNegative: return "aNegative"
        case .bPositive: return "bPositive"
        case .bNegative: return "bNegative"
        case .abPositive: return "abPositive"
        case .abNegative: return "abNegative"
        case .oPositive: return "oPositive"
        case .oNegative: return "oNegative"
        case .notSet: return nil
        @unknown default: return nil
        }
    }

    private static func label(_ value: HKFitzpatrickSkinType) -> String? {
        switch value {
        case .I: return "I"
        case .II: return "II"
        case .III: return "III"
        case .IV: return "IV"
        case .V: return "V"
        case .VI: return "VI"
        case .notSet: return nil
        @unknown default: return nil
        }
    }
}
