import Foundation

enum ParticipantStatePersistenceError: Error, Equatable {
    case corruptData
    case unsupportedVersion(Int)
    case studyMismatch(expected: String, actual: String)
}

@MainActor
protocol ParticipantStatePersisting: AnyObject {
    var activeStudyCode: String? { get }
    func setActiveStudyCode(_ code: String?)
    func loadState(for studyID: String) throws -> ParticipantState?
    func allStates() throws -> [ParticipantState]
    func saveState(_ state: ParticipantState) throws
    func removeState(for studyID: String)
    func legacyEnrollment() -> LegacyEnrollmentState?
    func clearLegacyEnrollment()
}
