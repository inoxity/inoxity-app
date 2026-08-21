import Foundation
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation

struct ValidatedMediaSelection: Equatable, Sendable {
    let selection: MediaSelection
    let byteCount: Int64
    let durationSeconds: Double?
    let sha256: String
}

struct MediaValidator: Sendable {
    func validate(_ selection: MediaSelection, configuration: MediaConfiguration,
                  category: MediaCategoryConfiguration, existing: [PersistedMediaDraft]) async throws -> ValidatedMediaSelection {
        guard configuration.enabled else { throw MediaRuntimeError.disabled }
        guard configuration.categories.contains(where: { $0.id == category.id }) else { throw MediaRuntimeError.unknownCategory }
        guard configuration.acceptedTypes.contains(selection.mediaType), category.acceptedTypes.contains(selection.mediaType) else { throw MediaRuntimeError.disallowedType }
        guard supported(selection) else { throw MediaRuntimeError.unsupportedFormat }
        let attributes = try FileManager.default.attributesOfItem(atPath: selection.temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw MediaRuntimeError.emptyFile }
        guard size <= Int64(configuration.maximumFileSizeMB) * 1_048_576 else { throw MediaRuntimeError.tooLarge }
        guard existing.count < configuration.maximumTotalItems else { throw MediaRuntimeError.itemLimit }
        guard existing.filter({ $0.categoryID == category.id }).count < category.maximumItems else { throw MediaRuntimeError.categoryLimit }
        let data = try Data(contentsOf: selection.temporaryURL, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var duration: Double?
        if selection.mediaType == .video {
            let asset = AVURLAsset(url: selection.temporaryURL)
            let loaded = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(loaded)
            duration = seconds.isFinite ? seconds : nil
            if let limit = configuration.maximumVideoLengthSeconds, let duration, duration > Double(limit) { throw MediaRuntimeError.videoTooLong }
        }
        if existing.contains(where: { $0.sha256 == checksum && $0.byteCount == size && $0.mediaType == selection.mediaType }) {
            throw MediaRuntimeError.duplicate
        }
        return .init(selection: selection, byteCount: size, durationSeconds: duration, sha256: checksum)
    }

    private func supported(_ selection: MediaSelection) -> Bool {
        guard let type = UTType(selection.uniformTypeIdentifier) else { return false }
        switch selection.mediaType {
        case .photo: return type.conforms(to: .heic) || type.conforms(to: .jpeg) || type.conforms(to: .png)
        case .video: return type.conforms(to: .quickTimeMovie) || type.conforms(to: .mpeg4Movie)
        }
    }
}
