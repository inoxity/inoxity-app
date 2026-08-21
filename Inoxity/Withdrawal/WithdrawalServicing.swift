import Foundation

@MainActor
protocol WithdrawalServicing: AnyObject {
    func withdraw(_ state: ParticipantState, choice: WithdrawalChoice) async throws -> PendingWithdrawalEvent
    func deleteRetainedLocalData(_ state: ParticipantState) async throws
}
