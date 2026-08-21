import Foundation

/// A one-time snapshot of HealthKit's static per-participant characteristic data — biological
/// sex, blood type, date of birth, Fitzpatrick skin type, and wheelchair use. Unlike everything
/// else in `Inoxity/HealthKit`, these aren't a time series read through the sample-query/sync
/// pipeline (`HealthKitTypeRegistry`/`HealthKitService.syncLocalData`) — they're static facts
/// read once via `HKHealthStore`'s synchronous characteristic getters (see
/// `HealthKitServicing.readCharacteristics()`) and always stored locally. When the study's
/// `healthKit.includeCharacteristics` is on, this snapshot is also best-effort synced to the
/// study's own Study Backend (`AppState.requestHealthKitAccess()`/`syncHealthKitNow()` →
/// `SyncCoordinator.syncParticipantCharacteristics` → `RemoteEnrollmentRepository
/// .updateParticipantCharacteristics`, an idempotent upsert — see that method's doc comment for
/// why no retry-queue is needed). If `includeCharacteristics` is off, this stays local-only, the
/// same way "See My Data" is local-only for everything else.
///
/// Deliberately plain (no `HealthKit` import here, mirroring `HealthKitTypeRegistry`'s
/// `HKObjectType` boundary staying out of `ParticipantState`) — the HealthKit-specific mapping
/// from `HKBiologicalSex`/`HKBloodType`/`HKFitzpatrickSkinType`/`HKWheelchairUse` to these plain
/// values lives in `HealthKitService`, which already imports `HealthKit`.
struct HealthKitCharacteristics: Codable, Equatable, Sendable {
    /// "female", "male", or "other" — nil if HealthKit reports `.notSet`, the type isn't
    /// authorized, or the underlying read failed.
    var biologicalSex: String?
    /// e.g. "oPositive", "abNegative" — nil under the same conditions as `biologicalSex`.
    var bloodType: String?
    var dateOfBirth: Date?
    /// "I" through "VI" on the Fitzpatrick scale — nil under the same conditions as `biologicalSex`.
    var fitzpatrickSkinType: String?
    /// nil if HealthKit reports `.notSet`, the type isn't authorized, or the read failed;
    /// otherwise true/false.
    var usesWheelchair: Bool?

    init(
        biologicalSex: String? = nil,
        bloodType: String? = nil,
        dateOfBirth: Date? = nil,
        fitzpatrickSkinType: String? = nil,
        usesWheelchair: Bool? = nil
    ) {
        self.biologicalSex = biologicalSex
        self.bloodType = bloodType
        self.dateOfBirth = dateOfBirth
        self.fitzpatrickSkinType = fitzpatrickSkinType
        self.usesWheelchair = usesWheelchair
    }

    var hasAnyValue: Bool {
        biologicalSex != nil || bloodType != nil || dateOfBirth != nil
            || fitzpatrickSkinType != nil || usesWheelchair != nil
    }
}
