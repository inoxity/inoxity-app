import Foundation

final class MockMediaStorage: MediaStoring, @unchecked Sendable {
    var storeError: Error?, deleteError: Error?, verifyError: Error?
    private(set) var stored = Set<String>(), deleted = [String](), deletedStudies = [String]()
    func store(_ validated: ValidatedMediaSelection, studyID: String, draftID: String, thumbnailData: Data?) throws -> StoredMediaFiles {
        if let storeError { throw storeError }; stored.insert(draftID)
        return .init(relativeMediaPath: "original.\(validated.selection.preferredFilenameExtension)", relativeThumbnailPath: thumbnailData == nil ? nil : "thumbnail.jpg")
    }
    func mediaURL(studyID: String, draftID: String, relativePath: String) throws -> URL { URL(fileURLWithPath: "/tmp/\(draftID)/\(relativePath)") }
    func thumbnailURL(studyID: String, draftID: String, relativePath: String) throws -> URL { try mediaURL(studyID: studyID, draftID: draftID, relativePath: relativePath) }
    func verify(_ draft: PersistedMediaDraft) throws { if let verifyError { throw verifyError } }
    func deleteDraft(studyID: String, draftID: String) throws { if let deleteError { throw deleteError }; stored.remove(draftID); deleted.append(draftID) }
    func deleteStudy(studyID: String) throws { if let deleteError { throw deleteError }; deletedStudies.append(studyID); stored.removeAll() }
}

struct MockMediaSelectionLoader: MediaSelectionLoading {
    let result: Result<MediaSelection, Error>
    func loadSelection() async throws -> MediaSelection { try result.get() }
}

struct MockMediaThumbnailGenerator: MediaThumbnailGenerating {
    let data: Data?
    func thumbnailData(for selection: MediaSelection) async -> Data? { data }
}
