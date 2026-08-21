protocol SyncCoordinating: Sendable {
    func synchronizePendingLocalChanges() async -> SyncResult
    /// Best-effort push of the participant's wake/bed time to their Study
    /// Backend. Swallows routing/network failures — local `ParticipantState`
    /// stays the source of truth for on-device scheduling either way, so a
    /// failed sync just means the researcher-facing copy is stale until the
    /// next successful call (e.g. the next time the participant edits it).
    func syncSleepSchedule(wakeMinutes: Int, bedMinutes: Int, for state: ParticipantState) async
    /// Best-effort push of a post-enrollment participant_identifier correction (e.g. a
    /// SONA ID typo fixed from Settings) to their Study Backend. Swallows routing/network
    /// failures — local `ParticipantState.externalParticipantID` stays the source of truth
    /// for what's shown in the app either way, so a failed sync just means the
    /// researcher-facing copy is stale until the next successful call.
    func syncParticipantIdentifier(_ value: String, for state: ParticipantState) async
    /// Best-effort push of the participant's HealthKit characteristics snapshot to their Study
    /// Backend — only ever called for studies with `healthKit.includeCharacteristics` on.
    /// Swallows routing/network failures — local `ParticipantState.healthKitCharacteristics`
    /// stays the source of truth either way, so a failed sync just means the researcher-facing
    /// copy is stale until the next successful call.
    func syncParticipantCharacteristics(_ value: HealthKitCharacteristics, for state: ParticipantState) async
}
