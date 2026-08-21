import Foundation

struct MediaRuntime: Sendable {
    let validator: MediaValidator
    let storage: any MediaStoring
    let thumbnailGenerator: any MediaThumbnailGenerating

    init(validator: MediaValidator = .init(), storage: any MediaStoring,
         thumbnailGenerator: any MediaThumbnailGenerating = MediaThumbnailGenerator()) {
        self.validator = validator; self.storage = storage; self.thumbnailGenerator = thumbnailGenerator
    }

    func importSelection(loader: any MediaSelectionLoading, configuration: MediaConfiguration,
                         category: MediaCategoryConfiguration, studyID: String,
                         existing: [PersistedMediaDraft], representedDate: Date?, now: Date) async throws -> PersistedMediaDraft {
        guard !category.representedDateRequired || representedDate != nil else {
            throw MediaRuntimeError.representedDateRequired
        }
        try ensureActive(configuration, now: now)
        let selection = try await loader.loadSelection()
        defer { try? FileManager.default.removeItem(at: selection.temporaryURL) }
        let validated = try await validator.validate(selection, configuration: configuration, category: category, existing: existing)
        let id = UUID().uuidString.lowercased()
        let thumbnail = await thumbnailGenerator.thumbnailData(for: selection)
        let files = try storage.store(validated, studyID: studyID, draftID: id, thumbnailData: thumbnail)
        return .init(id: id, studyID: studyID, categoryID: category.id, mediaType: selection.mediaType,
                     createdAt: now, lastModifiedAt: now, originalFilenameExtension: selection.preferredFilenameExtension,
                     relativeMediaPath: files.relativeMediaPath, relativeThumbnailPath: files.relativeThumbnailPath,
                     byteCount: validated.byteCount, durationSeconds: validated.durationSeconds,
                     uniformTypeIdentifier: selection.uniformTypeIdentifier, mimeType: selection.mimeType,
                     sha256: validated.sha256, representedDate: representedDate, status: .ready, failureReason: nil)
    }

    /// Re-verifies every draft's file on disk (marking any that went missing/corrupted `.failed`),
    /// and resets any found still `.uploading` back to `.ready` — an in-flight direct upload
    /// cannot have survived the app not running, so on relaunch it's safe-to-retry rather than
    /// trusting stale state.
    func restored(drafts: [String: PersistedMediaDraft]) -> [String: PersistedMediaDraft] {
        var restored = drafts
        for (id, draft) in drafts {
            do {
                try storage.verify(draft)
                if draft.status == .uploading { restored[id]?.status = .ready }
            }
            catch { var failed = draft; failed.status = .failed; failed.failureReason = MediaRuntimeError.checksumMismatch.localizedDescription; restored[id] = failed }
        }
        return restored
    }

    func retry(_ draft: PersistedMediaDraft, now: Date) throws -> PersistedMediaDraft {
        try storage.verify(draft); var value = draft; value.status = .ready; value.failureReason = nil; value.lastModifiedAt = now; return value
    }

    private func ensureActive(_ configuration: MediaConfiguration, now: Date) throws {
        let calendar = StudyConfigurationValidator.calendar
        let today = calendar.startOfDay(for: now)
        if let value = configuration.activeStartDate,
           let start = StudyConfigurationValidator.dateFormatter.date(from: value), today < start {
            throw MediaRuntimeError.inactive
        }
        if let value = configuration.activeEndDate,
           let end = StudyConfigurationValidator.dateFormatter.date(from: value), today > end {
            throw MediaRuntimeError.inactive
        }
    }
}
