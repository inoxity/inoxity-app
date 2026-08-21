import Foundation

protocol RemoteStudyRepository: Sendable {
    func resolveStudyBootstrap(studyCode: String) async throws -> ControlStudyBootstrap
}
protocol ControlBackendClientProviding: RemoteStudyRepository {}
