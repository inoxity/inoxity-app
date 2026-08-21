import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotosPickerSelectionLoader: MediaSelectionLoading, @unchecked Sendable {
    let item: PhotosPickerItem

    func loadSelection() async throws -> MediaSelection {
        guard let typeIdentifier = item.supportedContentTypes.first?.identifier,
              let type = UTType(typeIdentifier),
              let data = try await item.loadTransferable(type: Data.self) else { throw MediaRuntimeError.importFailed }
        let mediaType: MediaType = type.conforms(to: .movie) ? .video : .photo
        let ext = type.preferredFilenameExtension ?? (mediaType == .photo ? "jpg" : "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inoxity-media-\(UUID().uuidString).\(ext)")
        do { try data.write(to: url, options: .atomic) }
        catch { throw MediaRuntimeError.importFailed }
        return .init(temporaryURL: url, mediaType: mediaType, uniformTypeIdentifier: typeIdentifier,
                     mimeType: type.preferredMIMEType ?? "application/octet-stream", preferredFilenameExtension: ext)
    }
}
