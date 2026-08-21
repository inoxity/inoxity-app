import Foundation
import UIKit
import ImageIO
import AVFoundation

struct MediaThumbnailGenerator: MediaThumbnailGenerating {
    func thumbnailData(for selection: MediaSelection) async -> Data? {
        switch selection.mediaType {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(selection.temporaryURL as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 420,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.78)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: selection.temporaryURL))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = .init(width: 420, height: 420)
            guard let image = try? await generator.image(at: .zero).image else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.78)
        }
    }
}
