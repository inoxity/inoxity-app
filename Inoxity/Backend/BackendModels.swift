import Foundation

struct RemoteParticipantSession: Equatable, Sendable { let participantUUID: UUID; let studyID: String }
struct RemoteEnrollmentRecord: Equatable, Sendable { let participantUUID: UUID; let studyID: String; let enrolledAt: Date }
struct MediaUploadDescriptor: Equatable, Sendable {
    let studyID: String
    let stableStudyID: String
    let draftID: String
    let categoryID: String
    let mediaType: MediaType
    let mimeType: String
    let byteCount: Int64
    let checksum: String
    let durationSeconds: Double?
    let representedDate: Date?
    let originalFilenameExtension: String
    let remoteEnrollmentID: UUID
    let studyBackendID: UUID
    let configurationSchemaVersion: Int
    let configurationRevision: Int
}

struct MediaUploadAcknowledgment: Equatable, Sendable { let id: UUID; let receivedAt: Date }
