import AppKit
import ImageIO
import MacToysCore
import UniformTypeIdentifiers

/// App icons by bundle id (or by name for entries recorded before bundle ids were kept), cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String?, name: String?) -> NSImage? {
        let key = bundleID ?? name ?? ""
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        var url: URL?
        if let bundleID { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        if url == nil, let name {
            url = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent("\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = icon
        return icon
    }
}

/// Downsampled images for rows, cards and previews, cached per entry and size.
@MainActor
enum ClipThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    /// A copied image, at most `maxPixel` on its longest side.
    static func image(_ item: ClipItem, maxPixel: Int) -> NSImage? {
        guard let data = item.image else { return nil }
        let key = "\(item.id.uuidString)-\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsample(source, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A file's thumbnail (images) or its Finder icon; the type's icon when the file is gone.
    static func file(_ url: URL, maxPixel: Int) -> NSImage {
        let key = "\(url.path)-\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let exists = FileManager.default.fileExists(atPath: url.path)
        var image: NSImage?
        if exists, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = downsample(source, maxPixel: maxPixel)
        }
        let result = image ?? (exists ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
        cache.setObject(result, forKey: key)
        return result
    }

    /// Whether `file(_:maxPixel:)` gives a picture of the content rather than an icon.
    static func isPictureFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

/// Byte counts, character counts and relative times for the preview.
enum ClipFormat {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 45 { return String(localized: "Just now", comment: "When a clipboard entry was copied") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
