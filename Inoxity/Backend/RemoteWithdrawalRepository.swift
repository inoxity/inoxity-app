import Foundation

protocol RemoteWithdrawalRepository: Sendable {
    func submit(_ event: PendingWithdrawalEvent, remoteEnrollmentID: UUID?) async throws -> UUID
}
