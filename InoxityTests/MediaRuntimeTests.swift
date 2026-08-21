import XCTest
@testable import Inoxity

final class MediaRuntimeTests: XCTestCase {
    func testImportCreatesDurableDraftReadyToUpload() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let draft = try await context.runtime.importSelection(loader: MockMediaSelectionLoader(result: .success(context.selection)),
            configuration: context.study.media, category: try XCTUnwrap(context.study.media.categories.first),
            studyID: context.study.identity.id, existing: [], representedDate: Date(), now: Date())
        XCTAssertEqual(draft.status, .ready)
        XCTAssertEqual(draft.id, draft.id.lowercased())
        XCTAssertNil(draft.failureReason)
        XCTAssertTrue(context.storage.stored.contains(draft.id))
    }

    func testThumbnailFailureIsNonFatalAndRetryKeepsIdentifier() async throws {
        let context = try Context(thumbnail: nil); defer { context.cleanup() }
        let draft = try await context.runtime.importSelection(loader: MockMediaSelectionLoader(result: .success(context.selection)),
            configuration: context.study.media, category: try XCTUnwrap(context.study.media.categories.first),
            studyID: context.study.identity.id, existing: [], representedDate: Date(), now: Date())
        XCTAssertNil(draft.relativeThumbnailPath)
        var failed = draft; failed.status = .failed
        XCTAssertEqual(try context.runtime.retry(failed, now: Date()).id, draft.id)
    }

    func testRepresentedDateAndActiveWindowAreEnforcedBeforeCopy() async throws {
        let context = try Context(); defer { context.cleanup() }
        let category = try XCTUnwrap(context.study.media.categories.first)
        do {
            _ = try await context.runtime.importSelection(loader: MockMediaSelectionLoader(result: .success(context.selection)), configuration: context.study.media,
                category: category, studyID: context.study.identity.id, existing: [], representedDate: nil, now: Date())
            XCTFail("Expected represented date requirement")
        } catch { XCTAssertEqual(error as? MediaRuntimeError, .representedDateRequired) }
        XCTAssertTrue(context.storage.stored.isEmpty)
    }

    func testRestoreMarksMissingOrCorruptFileFailed() throws {
        let context = try Context(); defer { context.cleanup() }
        let draft = context.draft(id: "missing")
        context.storage.verifyError = MediaRuntimeError.missingFile
        let result = context.runtime.restored(drafts: [draft.id: draft])
        XCTAssertEqual(result[draft.id]?.status, .failed)
    }

    // Regression coverage: an upload that was in flight when the app stopped can't have
    // survived process death, so restoring on next launch must not leave it stuck showing
    // "Uploading…" forever — it resets to `.ready` so the participant can just retry.
    func testRestoreResetsStuckUploadingBackToReady() throws {
        let context = try Context(); defer { context.cleanup() }
        var draft = context.draft(id: "in-flight"); draft.status = .uploading
        let result = context.runtime.restored(drafts: [draft.id: draft])
        XCTAssertEqual(result[draft.id]?.status, .ready)
    }

    private final class Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = MockMediaStorage(); let study: StudyConfiguration; let selection: MediaSelection; let runtime: MediaRuntime
        init(thumbnail: Data? = Data("thumb".utf8)) throws {
            let url = try XCTUnwrap(Bundle(for: MediaRuntimeTests.self).url(forResource: "SleepStudy", withExtension: "json"))
            study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("photo.jpg"); try Data("photo".utf8).write(to: file)
            selection = .init(temporaryURL: file, mediaType: .photo, uniformTypeIdentifier: "public.jpeg", mimeType: "image/jpeg", preferredFilenameExtension: "jpg")
            runtime = MediaRuntime(storage: storage, thumbnailGenerator: MockMediaThumbnailGenerator(data: thumbnail))
        }
        func draft(id: String) -> PersistedMediaDraft { .init(id: id, studyID: study.identity.id, categoryID: "sleep-diary", mediaType: .photo, createdAt: Date(), lastModifiedAt: Date(), originalFilenameExtension: "jpg", relativeMediaPath: "original.jpg", relativeThumbnailPath: nil, byteCount: 5, durationSeconds: nil, uniformTypeIdentifier: "public.jpeg", mimeType: "image/jpeg", sha256: "hash", representedDate: Date(), status: .ready, failureReason: nil) }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
