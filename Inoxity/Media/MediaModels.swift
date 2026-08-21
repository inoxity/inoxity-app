import Foundation

enum MediaType: String, Codable, Equatable, Sendable, CaseIterable { case photo, video }
// `.ready`: validated, stored locally, not yet uploaded. `.uploading`: upload in flight (never
// persisted as meaningfully "still uploading" across a relaunch — MediaRuntime.restored() resets
// any found back to `.ready`, since an in-flight network call can't survive process death).
// `.uploadFailed`: last direct upload attempt failed; the same "Upload" action retries it.
// `.failed`: the LOCAL file went missing/corrupt (caught by restored()) — unrelated to uploading.
enum MediaDraftStatus: String, Codable, Equatable, Sendable { case ready, uploading, uploadFailed, failed }

struct PersistedMediaDraft: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let studyID: String
    let categoryID: String
    let mediaType: MediaType
    let createdAt: Date
    var lastModifiedAt: Date
    let originalFilenameExtension: String
    let relativeMediaPath: String
    var relativeThumbnailPath: String?
    let byteCount: Int64
    let durationSeconds: Double?
    let uniformTypeIdentifier: String
    let mimeType: String
    let sha256: String
    var representedDate: Date?
    var status: MediaDraftStatus
    var failureReason: String?
}

struct MediaSelection: Equatable, Sendable {
    let temporaryURL: URL
    let mediaType: MediaType
    let uniformTypeIdentifier: String
    let mimeType: String
    let preferredFilenameExtension: String
}

struct MediaRuntimeSummary: Equatable, Sendable {
    var drafts: [PersistedMediaDraft] = []
    var storageBytes: Int64 { drafts.reduce(0) { $0 + $1.byteCount } }
    var readyCount: Int { drafts.filter { $0.status == .ready }.count }
    var failedCount: Int { drafts.filter { $0.status == .failed }.count }
    var uploadFailedCount: Int { drafts.filter { $0.status == .uploadFailed }.count }
}

enum MediaRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case disabled, inactive, unknownCategory, disallowedType, unsupportedFormat, emptyFile
    case tooLarge, videoTooLong, itemLimit, categoryLimit, duplicate, missingFile
    case invalidRelativePath, copyFailed, checksumMismatch, storageFailure, importFailed
    case persistenceFailure, draftNotFound, representedDateRequired, uploadUnavailable

    var errorDescription: String? {
        switch self {
        case .disabled, .inactive: "Media collection is not currently available for this study."
        case .unknownCategory: "Choose a valid media category."
        case .disallowedType, .unsupportedFormat: "That media type is not accepted for this category."
        case .emptyFile: "The selected file is empty."
        case .tooLarge: "The selected file is larger than this study allows."
        case .videoTooLong: "The selected video is longer than this study allows."
        case .itemLimit, .categoryLimit: "This study’s media item limit has been reached."
        case .duplicate: "This item has already been added to this study."
        case .missingFile, .checksumMismatch: "A saved media item could not be verified."
        case .invalidRelativePath: "Saved media information was not safe to open."
        case .copyFailed, .storageFailure, .importFailed: "The selected media could not be saved locally. Please try again."
        case .persistenceFailure: "Media progress could not be saved."
        case .draftNotFound: "That media item is no longer available."
        case .uploadUnavailable: "Inoxity isn't connected to the study server right now. Please try again."
        case .representedDateRequired: "Choose the date represented by this media item."
        }
    }
}
