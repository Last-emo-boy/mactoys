import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A picture for an item: a Quick Look thumbnail (photos, PDF pages, documents) or the file's icon.
struct ShelfThumbnail {
    var image: NSImage
    /// Icons are drawn as they are; thumbnails get a thin border and a shadow, like a print.
    var isIcon: Bool
}

/// Loads Quick Look thumbnails off the main thread and caches them by file and modification date.
@MainActor
final class ShelfThumbnailLoader {
    static let shared = ShelfThumbnailLoader()

    private var cache: [String: ShelfThumbnail] = [:]
    private var order: [String] = []
    private let limit = 300

    /// The cached thumbnail, or the file's icon right away.
    func immediate(for item: ShelfItem) -> ShelfThumbnail {
        if let cached = cache[key(item)] { return cached }
        return ShelfThumbnail(image: icon(for: item), isIcon: true)
    }

    /// The best thumbnail Quick Look can make (or the icon).
    func load(_ item: ShelfItem, size: CGFloat = 160) async -> ShelfThumbnail {
        let key = key(item)
        if let cached = cache[key] { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: [.thumbnail, .icon])
        var result = ShelfThumbnail(image: icon(for: item), isIcon: true)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            result = ShelfThumbnail(image: rep.nsImage, isIcon: rep.type != .thumbnail)
        }
        // Folders, packages and apps look best as their icons.
        if item.isDirectory || item.utType?.conforms(to: .package) == true { result = ShelfThumbnail(image: icon(for: item), isIcon: true) }
        store(result, for: key)
        return result
    }

    func icon(for item: ShelfItem) -> NSImage {
        if FileManager.default.fileExists(atPath: item.url.path) { return NSWorkspace.shared.icon(forFile: item.url.path) }
        return NSWorkspace.shared.icon(for: item.utType ?? .data)
    }

    private func key(_ item: ShelfItem) -> String {
        let date = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return item.url.path + "|" + String(date?.timeIntervalSinceReferenceDate ?? 0)
    }

    private func store(_ thumb: ShelfThumbnail, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = thumb
        if order.count > limit { cache[order.removeFirst()] = nil }
    }
}
