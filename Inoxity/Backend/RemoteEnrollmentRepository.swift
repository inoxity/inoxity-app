protocol RemoteEnrollmentRepository: Sendable {
    func ensureParticipant() async throws -> RemoteParticipant
    func register(_ registration: EnrollmentRegistration) async throws -> RemoteEnrollment
    /// Best-effort sync of the participant's wake/bed time to the Study Backend
    /// (`participants.wake_time`/`bed_time`, mirroring the pre-dashboard app) so
    /// researchers have server-side visibility into it. Callers should treat
    /// failures as non-fatal — local `ParticipantState` stays the source of truth
    /// for on-device scheduling regardless of whether this sync succeeds.
    func updateSleepSchedule(wakeMinutes: Int, bedMinutes: Int) async throws
    /// Best-effort sync of a post-enrollment correction to the participant's own
    /// `study_enrollments.participant_identifier` (e.g. a SONA ID typo fixed from
    /// Settings) to the Study Backend. Callers should treat failures as non-fatal —
    /// local `ParticipantState.externalParticipantID` stays the source of truth for
    /// what's shown in the app regardless of whether this sync succeeds.
    func updateParticipantIdentifier(_ value: String) async throws
    /// Best-effort sync of the participant's HealthKit characteristics snapshot (biological sex,
    /// blood type, date of birth, Fitzpatrick skin type, wheelchair use) to the Study Backend —
    /// only ever called for studies with `healthKit.includeCharacteristics` on. Idempotent upsert
    /// server-side (one row per participant), so a missed sync self-heals the next time this is
    /// called again — no queue/retry infrastructure needed, same reasoning as
    /// `updateSleepSchedule` above. Callers should treat failures as non-fatal — local
    /// `ParticipantState.healthKitCharacteristics` stays the source of truth regardless of
    /// whether this sync succeeds.
    func updateParticipantCharacteristics(_ value: HealthKitCharacteristics) async throws
}
