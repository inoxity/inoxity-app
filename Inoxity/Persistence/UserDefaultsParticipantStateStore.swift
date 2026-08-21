import Foundation

@MainActor
final class UserDefaultsParticipantStateStore: ParticipantStatePersisting {
    enum Key {
        static let activeStudyCode = "participant.activeStudyCode"
        static let statePrefix = "participant.state."
        static let legacyStudyCode = "enrollment.studyCode"
        static let legacyParticipantID = "enrollment.participantID"
        static let legacyOnboardingComplete = "enrollment.onboardingComplete"
        static let legacyOnboardingStep = "enrollment.onboardingStep"
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var activeStudyCode: String? {
        defaults.string(forKey: Key.activeStudyCode) ?? defaults.string(forKey: Key.legacyStudyCode)
    }

    func setActiveStudyCode(_ code: String?) {
        if let code { defaults.set(StudyCodeNormalizer.normalize(code), forKey: Key.activeStudyCode) }
        else { defaults.removeObject(forKey: Key.activeStudyCode) }
    }

    func loadState(for studyID: String) throws -> ParticipantState? {
        guard let data = defaults.data(forKey: stateKey(studyID)) else { return nil }
        let state: ParticipantState
        do { state = try decoder.decode(ParticipantState.self, from: data) }
        catch { throw ParticipantStatePersistenceError.corruptData }
        guard state.studyID == studyID else {
            throw ParticipantStatePersistenceError.studyMismatch(expected: studyID, actual: state.studyID)
        }
        switch state.persistenceVersion {
        case ParticipantState.currentPersistenceVersion:
            return state
        case 1, 2, 3, 4, 5, 6, 7, 8:
            let migrated = state.migratedToCurrentVersion()
            try saveState(migrated)
            return migrated
        default:
            throw ParticipantStatePersistenceError.unsupportedVersion(state.persistenceVersion)
        }
    }

    func allStates() throws -> [ParticipantState] {
        try defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Key.statePrefix) }.compactMap {
            try loadState(for: String($0.dropFirst(Key.statePrefix.count)))
        }
    }

    func saveState(_ state: ParticipantState) throws {
        guard state.persistenceVersion == ParticipantState.currentPersistenceVersion else {
            throw ParticipantStatePersistenceError.unsupportedVersion(state.persistenceVersion)
        }
        defaults.set(try encoder.encode(state), forKey: stateKey(state.studyID))
    }

    func removeState(for studyID: String) { defaults.removeObject(forKey: stateKey(studyID)) }

    func legacyEnrollment() -> LegacyEnrollmentState? {
        guard let code = defaults.string(forKey: Key.legacyStudyCode) else { return nil }
        return LegacyEnrollmentState(
            studyCode: StudyCodeNormalizer.normalize(code),
            participantID: defaults.string(forKey: Key.legacyParticipantID) ?? "",
            onboardingStep: defaults.integer(forKey: Key.legacyOnboardingStep),
            onboardingComplete: defaults.bool(forKey: Key.legacyOnboardingComplete)
        )
    }

    func clearLegacyEnrollment() {
        [Key.legacyStudyCode, Key.legacyParticipantID, Key.legacyOnboardingComplete, Key.legacyOnboardingStep]
            .forEach(defaults.removeObject(forKey:))
    }

    private func stateKey(_ studyID: String) -> String { Key.statePrefix + studyID }
}
