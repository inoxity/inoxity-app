import Foundation

protocol MediaThumbnailGenerating: Sendable {
    func thumbnailData(for selection: MediaSelection) async -> Data?
}
