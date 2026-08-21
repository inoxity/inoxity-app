import Foundation

struct StoredMediaFiles: Equatable, Sendable {
    let relativeMediaPath: String
    let relativeThumbnailPath: String?
}

protocol MediaStoring: Sendable {
    func store(_ validated: ValidatedMediaSelection, studyID: String, draftID: String,
               thumbnailData: Data?) throws -> StoredMediaFiles
    func mediaURL(studyID: String, draftID: String, relativePath: String) throws -> URL
    func thumbnailURL(studyID: String, draftID: String, relativePath: String) throws -> URL
    func verify(_ draft: PersistedMediaDraft) throws
    func deleteDraft(studyID: String, draftID: String) throws
    func deleteStudy(studyID: String) throws
}
