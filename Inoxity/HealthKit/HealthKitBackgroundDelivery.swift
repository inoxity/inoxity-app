import Foundation
import HealthKit
import UIKit

@MainActor
protocol HealthKitBackgroundDelivering: AnyObject {
    /// Observes exactly these HealthKit identifiers from now on (empty stops everything).
    /// Idempotent — repeating the current set is a no-op.
    func observe(identifiers: [String])
    /// Re-registers the last observed set. Must run at every launch, including a background
    /// launch HealthKit triggers itself, because observer queries don't survive app termination.
    func resumePersistedObservation()
}

/// Lets iOS wake Inoxity to upload new Apple Health data, instead of new samples only reaching the
/// Study Backend when the participant next opens the app. Each configured sample type gets an
/// `HKObserverQuery` plus background delivery. When one fires, the ordinary sync pass runs
/// (`SyncCoordinator.synchronizePendingLocalChanges`, which already coalesces overlapping calls),
/// wrapped in a background task so iOS doesn't suspend it partway.
///
/// Registered from the app delegate, not AppState, because a HealthKit-triggered background
/// launch may never build SwiftUI's view tree, so AppState might not exist. The observed set is
/// persisted for the same reason. HealthKit data is unreadable while the phone is locked; a
/// wake-up then just fails as a retryable error and the next wake-up or foreground picks it up.
@MainActor
final class HealthKitBackgroundDelivery: HealthKitBackgroundDelivering {
    static let identifiersKey = "inoxity.healthkit-background-identifiers.v1"
    private let store: HKHealthStore
    private let defaults: UserDefaults
    private let synchronize: @Sendable () async -> Void
    private var queries: [HKObserverQuery] = []
    private var observed: [String] = []

    init(store: HKHealthStore = HKHealthStore(), defaults: UserDefaults = .standard,
         synchronize: @escaping @Sendable () async -> Void) {
        self.store = store; self.defaults = defaults; self.synchronize = synchronize
    }

    func resumePersistedObservation() {
        observe(identifiers: defaults.stringArray(forKey: Self.identifiersKey) ?? [])
    }

    func observe(identifiers: [String]) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let sampleIdentifiers = Array(Set(identifiers.filter {
            (try? HealthKitTypeRegistry.type(for: $0))?.objectType is HKSampleType
        })).sorted()
        guard sampleIdentifiers != observed else { return }
        for query in queries { store.stop(query) }
        queries = []
        // Only the dropped types — a blanket disableAll could land after the re-enables below.
        for identifier in Set(observed).subtracting(sampleIdentifiers) {
            guard let type = (try? HealthKitTypeRegistry.type(for: identifier))?.objectType else { continue }
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }
        observed = sampleIdentifiers
        guard !sampleIdentifiers.isEmpty else { defaults.removeObject(forKey: Self.identifiersKey); return }
        defaults.set(sampleIdentifiers, forKey: Self.identifiersKey)
        for identifier in sampleIdentifiers {
            guard let type = (try? HealthKitTypeRegistry.type(for: identifier))?.objectType as? HKSampleType else { continue }
            // HealthKit stops delivering after three wake-ups whose completion handler never runs, so
            // it is called on every path, including when `self` is gone.
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await self?.runSynchronizeInBackgroundTask()
                    completion()
                }
            }
            queries.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    private func runSynchronizeInBackgroundTask() async {
        final class TaskBox { var id: UIBackgroundTaskIdentifier = .invalid }
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "HealthKitUpload") {
            UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid
        }
        await synchronize()
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
    }
}
