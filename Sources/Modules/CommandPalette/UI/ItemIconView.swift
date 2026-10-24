import AppKit
import MacToysCore
import QuickLookThumbnailing
import SwiftUI

/// Finder icons by path, cached.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(_ path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

/// Draws an `ItemIcon`: a tinted symbol tile, a Finder icon or an emoji.
struct ItemIconView: View {
    let icon: ItemIcon
    var size: CGFloat = 28

    var body: some View {
        switch icon {
        case .symbol(let name, let tint):
            ModuleIcon(symbol: name, tint: tint, size: size)
        case .file(let path):
            Image(nsImage: IconCache.icon(path))
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.14, height: size * 1.14)
                .frame(width: size, height: size)
        case .emoji(let e):
            Text(e)
                .font(.system(size: size * 0.78))
                .frame(width: size, height: size)
        }
    }
}

/// A Quick Look thumbnail of a file, loaded asynchronously.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: IconCache.icon(url.path)).resizable().aspectRatio(contentMode: .fit).padding(30)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 520, height: 360),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}
