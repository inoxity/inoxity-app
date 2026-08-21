import Foundation

@MainActor
protocol WithdrawalEventPersisting: AnyObject {
    func events(for studyID: String) throws -> [PendingWithdrawalEvent]
    func allEvents() throws -> [PendingWithdrawalEvent]
    func save(_ event: PendingWithdrawalEvent) throws
    func update(_ event: PendingWithdrawalEvent) throws
    func remove(eventID: String, studyID: String)
}

enum WithdrawalEventPersistenceError: Error, Equatable { case corruptData, unsupportedVersion(Int) }
