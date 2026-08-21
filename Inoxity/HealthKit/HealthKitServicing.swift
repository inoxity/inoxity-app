import Foundation

@MainActor
protocol HealthKitServicing: AnyObject {
    var isHealthDataAvailable: Bool { get }
    /// `includeCharacteristics` additionally requests HealthKit's five static characteristic
    /// types (see `HealthKitService.characteristicTypes`) — only when a study's
    /// `HealthKitConfiguration.includeCharacteristics` opts in, so participants are never
    /// prompted for a data type the study didn't select.
    func requestReadAuthorization(for identifiers: Set<String>, includeCharacteristics: Bool) async throws -> HealthKitAuthorizationRequestResult
    /// Reports, before actually requesting, whether iOS would show a fresh permission sheet for any
    /// type in `identifiers` (`.shouldRequest`) or whether every type already has a saved OS decision
    /// from a previous study/install (`.unnecessary`).
    // Neither requirement above gives `includeCharacteristics` a default value — the one real
    // caller (AppState) always has an explicit config-driven value to pass, so a default would
    // only invite silently forgetting it. `MockHealthKitService`'s own declarations give it a
    // default there instead, for the tests that don't care.
    func requestStatus(for identifiers: Set<String>, includeCharacteristics: Bool) async throws -> HealthKitAuthorizationPreCheck
    func syncLocalData(for identifiers: Set<String>, interval: DateInterval) async throws -> HealthKitLocalSyncSummary
    /// Best-effort, synchronous read of HealthKit's static per-participant characteristic data
    /// (biological sex, blood type, date of birth, Fitzpatrick skin type, wheelchair use) — see
    /// `HealthKitCharacteristics`'s doc comment. Never throws: an unauthorized, `.notSet`, or
    /// failed field is simply nil in the result rather than failing the whole read. Only
    /// meaningful when `requestReadAuthorization` was called with `includeCharacteristics: true` —
    /// callers should skip calling this at all otherwise, since every field would just read back nil.
    func readCharacteristics() -> HealthKitCharacteristics
}

// The UI and AppState depend only on this small façade. Future historical sync and
// background-delivery coordination can be implemented behind it without changing callers.
