import SwiftUI

struct MediaThumbnailView: View {
    let url: URL?
    let mediaType: MediaType
    var body: some View {
        Group {
            if let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: mediaType == .photo ? "photo" : "video").font(.title).foregroundStyle(InoxityTheme.aqua) }
        }.frame(width: 72, height: 72).background(InoxityTheme.surface.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
