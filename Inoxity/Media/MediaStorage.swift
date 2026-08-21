import Foundation
import CryptoKit

struct MediaStorage: MediaStoring, @unchecked Sendable {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = support.appendingPathComponent("Inoxity", isDirectory: true)
    }

    func store(_ validated: ValidatedMediaSelection, studyID: String, draftID: String, thumbnailData: Data?) throws -> StoredMediaFiles {
        try validateComponent(studyID); try validateComponent(draftID)
        let directory = draftDirectory(studyID: studyID, draftID: draftID)
        let mediaName = "original.\(validated.selection.preferredFilenameExtension.lowercased())"
        try validateRelative(mediaName)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var root = rootURL; try root.setResourceValues(values)
            let destination = directory.appendingPathComponent(mediaName)
            try fileManager.copyItem(at: validated.selection.temporaryURL, to: destination)
            var thumbnailName: String?
            if let thumbnailData {
                do {
                    let name = "thumbnail.jpg"; try thumbnailData.write(to: directory.appendingPathComponent(name), options: .atomic)
                    thumbnailName = name
                } catch { thumbnailName = nil }
            }
            return .init(relativeMediaPath: mediaName, relativeThumbnailPath: thumbnailName)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw MediaRuntimeError.copyFailed
        }
    }

    func mediaURL(studyID: String, draftID: String, relativePath: String) throws -> URL {
        try safeURL(studyID: studyID, draftID: draftID, relativePath: relativePath)
    }
    func thumbnailURL(studyID: String, draftID: String, relativePath: String) throws -> URL {
        try safeURL(studyID: studyID, draftID: draftID, relativePath: relativePath)
    }
    func verify(_ draft: PersistedMediaDraft) throws {
        let url = try mediaURL(studyID: draft.studyID, draftID: draft.id, relativePath: draft.relativeMediaPath)
        guard fileManager.fileExists(atPath: url.path) else { throw MediaRuntimeError.missingFile }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == draft.byteCount else { throw MediaRuntimeError.checksumMismatch }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard checksum == draft.sha256 else { throw MediaRuntimeError.checksumMismatch }
        if let thumbnail = draft.relativeThumbnailPath { _ = try thumbnailURL(studyID: draft.studyID, draftID: draft.id, relativePath: thumbnail) }
    }
    func deleteDraft(studyID: String, draftID: String) throws {
        try validateComponent(studyID); try validateComponent(draftID)
        let url = draftDirectory(studyID: studyID, draftID: draftID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
    func deleteStudy(studyID: String) throws {
        try validateComponent(studyID)
        let url = rootURL.appendingPathComponent("Studies", isDirectory: true).appendingPathComponent(studyID, isDirectory: true).appendingPathComponent("Media", isDirectory: true)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func draftDirectory(studyID: String, draftID: String) -> URL {
        rootURL.appendingPathComponent("Studies", isDirectory: true).appendingPathComponent(studyID, isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true).appendingPathComponent(draftID, isDirectory: true)
    }
    private func safeURL(studyID: String, draftID: String, relativePath: String) throws -> URL {
        try validateComponent(studyID); try validateComponent(draftID); try validateRelative(relativePath)
        return draftDirectory(studyID: studyID, draftID: draftID).appendingPathComponent(relativePath)
    }
    private func validateComponent(_ value: String) throws {
        guard !value.isEmpty, !value.contains(".."), !value.contains("/"), !value.contains("\\"), URL(string: value)?.scheme == nil else { throw MediaRuntimeError.invalidRelativePath }
    }
    private func validateRelative(_ value: String) throws { try validateComponent(value) }
}
