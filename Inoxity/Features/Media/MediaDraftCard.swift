import SwiftUI

struct MediaDraftCard: View {
    let draft: PersistedMediaDraft
    let categoryName: String
    let thumbnailURL: URL?
    let upload: () -> Void
    let retry: () -> Void
    let delete: () -> Void

    var body: some View { InoxityCard { HStack(alignment: .top, spacing: 14) {
        MediaThumbnailView(url: thumbnailURL, mediaType: draft.mediaType)
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(categoryName).font(.headline); Spacer(); Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(InoxityTheme.aqua) }
            Text(ByteCountFormatter.string(fromByteCount: draft.byteCount, countStyle: .file)).font(.caption).foregroundStyle(InoxityTheme.secondaryText)
            if let duration = draft.durationSeconds { Text("Duration: \(duration.formatted(.number.precision(.fractionLength(0)))) seconds").font(.caption).foregroundStyle(InoxityTheme.secondaryText) }
            if let represented = draft.representedDate { Text("Represents \(represented.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(InoxityTheme.secondaryText) }
            Text("Added \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(InoxityTheme.secondaryText)
            if let failureReason = draft.failureReason, draft.status == .uploadFailed {
                Text(failureReason).font(.caption).foregroundStyle(InoxityTheme.pink)
            }
            switch draft.status {
            case .failed: SecondaryButton(title: "Retry Local Processing", action: retry)
            case .uploading: SecondaryButton(title: "Uploading…", action: {}).disabled(true)
            case .ready: SecondaryButton(title: "Upload", action: upload)
            case .uploadFailed: SecondaryButton(title: "Retry Upload", action: upload)
            }
            SecondaryButton(title: "Delete", action: delete)
        }
    } } }
    private var statusText: String {
        switch draft.status {
        case .ready: "Ready to upload"
        case .uploading: "Uploading…"
        case .uploadFailed: "Upload failed"
        case .failed: draft.status.rawValue.capitalized
        }
    }
}
