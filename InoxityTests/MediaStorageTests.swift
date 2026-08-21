import XCTest
import CryptoKit
@testable import Inoxity

final class MediaStorageTests: XCTestCase {
    func testCopyVerifyChecksumAndCleanup() throws {
        let context = try Context()
        defer { context.cleanup() }
        let selection = context.selection(data: Data("image bytes".utf8))
        let validated = try validated(selection)
        let files = try context.storage.store(validated, studyID: "sleep-study", draftID: "draft-id", thumbnailData: Data("thumb".utf8))
        let draft = makeDraft(files: files, validated: validated)
        XCTAssertNoThrow(try context.storage.verify(draft))
        XCTAssertTrue(try context.storage.mediaURL(studyID: draft.studyID, draftID: draft.id, relativePath: draft.relativeMediaPath).isFileURL)
        try context.storage.deleteDraft(studyID: draft.studyID, draftID: draft.id)
        XCTAssertThrowsError(try context.storage.verify(draft))
    }

    func testChecksumMismatchIsDetected() throws {
        let context = try Context(); defer { context.cleanup() }
        let selection = context.selection(data: Data("image bytes".utf8))
        let validated = try validated(selection)
        let files = try context.storage.store(validated, studyID: "sleep-study", draftID: "draft-id", thumbnailData: nil)
        var draft = makeDraft(files: files, validated: validated)
        draft = PersistedMediaDraft(id: draft.id, studyID: draft.studyID, categoryID: draft.categoryID, mediaType: draft.mediaType,
            createdAt: draft.createdAt, lastModifiedAt: draft.lastModifiedAt, originalFilenameExtension: draft.originalFilenameExtension,
            relativeMediaPath: draft.relativeMediaPath, relativeThumbnailPath: draft.relativeThumbnailPath, byteCount: draft.byteCount,
            durationSeconds: draft.durationSeconds, uniformTypeIdentifier: draft.uniformTypeIdentifier, mimeType: draft.mimeType,
            sha256: String(repeating: "0", count: 64), representedDate: nil, status: .ready, failureReason: nil)
        XCTAssertThrowsError(try context.storage.verify(draft)) { XCTAssertEqual($0 as? MediaRuntimeError, .checksumMismatch) }
    }

    func testStrictPathTraversalRejection() throws {
        let context = try Context(); defer { context.cleanup() }
        for unsafe in ["../file", "/file", "a/b", "a\\b", "https://example.com/file"] {
            XCTAssertThrowsError(try context.storage.mediaURL(studyID: "study", draftID: "draft", relativePath: unsafe)) {
                XCTAssertEqual($0 as? MediaRuntimeError, .invalidRelativePath)
            }
        }
    }

    private func validated(_ selection: MediaSelection) throws -> ValidatedMediaSelection {
        let data = try Data(contentsOf: selection.temporaryURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(selection: selection, byteCount: Int64(data.count), durationSeconds: nil, sha256: hash)
    }
    private func makeDraft(files: StoredMediaFiles, validated: ValidatedMediaSelection) -> PersistedMediaDraft {
        .init(id: "draft-id", studyID: "sleep-study", categoryID: "sleep-diary", mediaType: .photo,
              createdAt: Date(), lastModifiedAt: Date(), originalFilenameExtension: "jpg",
              relativeMediaPath: files.relativeMediaPath, relativeThumbnailPath: files.relativeThumbnailPath,
              byteCount: validated.byteCount, durationSeconds: nil, uniformTypeIdentifier: "public.jpeg",
              mimeType: "image/jpeg", sha256: validated.sha256, representedDate: nil, status: .ready, failureReason: nil)
    }
    private final class Context {
        let directory: URL; let storage: MediaStorage
        init() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); storage = MediaStorage(rootURL: directory) }
        func selection(data: Data) -> MediaSelection {
            let url = directory.appendingPathComponent(UUID().uuidString + ".jpg")
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try! data.write(to: url)
            return .init(temporaryURL: url, mediaType: .photo, uniformTypeIdentifier: "public.jpeg", mimeType: "image/jpeg", preferredFilenameExtension: "jpg")
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
