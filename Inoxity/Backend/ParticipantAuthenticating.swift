import Foundation

protocol ParticipantAuthenticating: Sendable {
    func authenticatedParticipant() async throws -> AuthenticatedParticipant
}

protocol ControlBackendAuthenticating: ParticipantAuthenticating {}
protocol StudyBackendAuthenticating: ParticipantAuthenticating {
    var backendID: UUID { get }
    var storageNamespace: String { get }
}

protocol StudyBackendIdentityValidating: Sendable {
    func validate(expectedStudyID: String, expectedCode: String,
                  schemaVersion: Int) async throws -> ValidatedStudyBackendIdentity
}

protocol StudyBackendClientProviding: Sendable {
    var descriptor: StudyBackendDescriptor { get }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant
    func validateIdentity(expectedStudyID: String, expectedCode: String,
                          schemaVersion: Int) async throws -> ValidatedStudyBackendIdentity
}

protocol StudyBackendClientFactory: Sendable {
    func context(for bootstrap: ControlStudyBootstrap) async throws -> StudyBackendContext
    func context(for resolved: ResolvedStudy) async throws -> StudyBackendContext
}
