import SwiftUI
import PhotosUI

struct MediaView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration
    @State private var selectedCategoryID = ""
    @State private var representedDate = Date()
    @State private var includeRepresentedDate = false
    @State private var pickerItems = [PhotosPickerItem]()

    private var media: MediaConfiguration { configuration.media }
    private var selectedCategory: MediaCategoryConfiguration? { media.categories.first { $0.id == selectedCategoryID } }
    private var filter: PHPickerFilter {
        let types = selectedCategory?.acceptedTypes ?? media.acceptedTypes
        if types == [.photo] { return .images }
        if types == [.video] { return .videos }
        return .any(of: [.images, .videos])
    }

    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 20) {
                Text("Media").font(.system(.largeTitle, design: .rounded, weight: .light))
                Text(media.instructions).foregroundStyle(InoxityTheme.secondaryText)
                Text(media.privacyText).font(.footnote).foregroundStyle(InoxityTheme.aqua)
                if let message = state.mediaErrorMessage { ErrorMessageView(message: message) }
                if let message = state.mediaUploadSuccessMessage { SuccessMessageView(message: message) }
                if media.enabled, !media.categories.isEmpty {
                    categoryControls
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: remainingItemCount, matching: filter) {
                        Label(state.mediaActionInProgress ? "Processing…" : "Choose Media", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent).tint(InoxityTheme.aqua).disabled(state.mediaActionInProgress || remainingItemCount == 0)
                    draftList
                } else {
                    InoxityCard { Text("This study does not currently collect media.").foregroundStyle(InoxityTheme.secondaryText) }
                }
            }.foregroundStyle(InoxityTheme.primaryText)
        }
        .task { if selectedCategoryID.isEmpty { selectedCategoryID = media.categories.first?.id ?? "" }; state.refreshMediaRuntime() }
        .onChange(of: pickerItems) { _, items in
            guard let category = selectedCategory else { return }
            let date = includeRepresentedDate ? representedDate : nil
            Task {
                for item in items { await state.importMedia(loader: PhotosPickerSelectionLoader(item: item), categoryID: category.id, representedDate: date) }
                pickerItems = []
            }
        }
    }

    private var categoryControls: some View {
        InoxityCard { VStack(alignment: .leading, spacing: 12) {
            Picker("Category", selection: $selectedCategoryID) { ForEach(media.categories) { Text($0.displayName).tag($0.id) } }.pickerStyle(.menu)
            if let category = selectedCategory { Text(category.description).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText)
                Toggle("What day was this photo from?", isOn: $includeRepresentedDate)
                if includeRepresentedDate { DatePicker("Date", selection: $representedDate, displayedComponents: .date) }
                if category.representedDateRequired && !includeRepresentedDate { Text("A represented date is required for this category.").font(.caption).foregroundStyle(InoxityTheme.pink) }
            }
        } }
    }

    @ViewBuilder private var draftList: some View {
        if state.mediaSummary.drafts.isEmpty { InoxityCard { Text("No media has been added yet.").foregroundStyle(InoxityTheme.secondaryText) } }
        else { ForEach(state.mediaSummary.drafts) { draft in
            MediaDraftCard(draft: draft, categoryName: media.categories.first(where: { $0.id == draft.categoryID })?.displayName ?? "Media",
                           thumbnailURL: state.mediaThumbnailURL(for: draft),
                           upload: { Task { await state.uploadMediaDraft(draft.id) } },
                           retry: { state.retryMediaDraft(draft.id) }, delete: { state.deleteMediaDraft(draft.id) })
        } }
    }
    private var remainingItemCount: Int { max(0, media.maximumTotalItems - state.mediaSummary.drafts.count) }
}
