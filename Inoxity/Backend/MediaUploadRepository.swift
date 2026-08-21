import Foundation

protocol MediaUploadRepository: Sendable {
    func upload(_ media: MediaUploadDescriptor, data: Data) async throws -> MediaUploadAcknowledgment
}

struct UnavailableMediaUploadRepository: MediaUploadRepository {
    func upload(_ media: MediaUploadDescriptor, data: Data) async throws -> MediaUploadAcknowledgment {
        throw MediaUploadError.unavailable
    }
}

enum MediaUploadError: Error, Equatable, Sendable {
    case unavailable, routingRequired
}
