import Foundation

/// Decides where each Markdown image comes from. Local images are inlined as `data:` URIs so the
/// page needs no file access; they must live in the document's folder tree (like PowerToys).
/// Remote images are used only when allowed, either directly or from `prefetched` data.
public struct MarkdownImagePolicy: Sendable {
    public var documentURL: URL?
    public var showLocalImages: Bool
    public var allowRemoteImages: Bool
    /// Remote URL → `data:` URI, filled by callers that fetch images themselves (Quick Look).
    public var prefetched: [String: String]
    /// Largest local image that is inlined.
    public var maxLocalBytes: Int

    public init(documentURL: URL?, showLocalImages: Bool = true, allowRemoteImages: Bool = false,
                prefetched: [String: String] = [:], maxLocalBytes: Int = 16 * 1024 * 1024) {
        self.documentURL = documentURL
        self.showLocalImages = showLocalImages
        self.allowRemoteImages = allowRemoteImages
        self.prefetched = prefetched
        self.maxLocalBytes = maxLocalBytes
    }

    public static func isRemote(_ src: String) -> Bool {
        let lower = src.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    public func resolve(_ src: String) -> String? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("data:image/") { return trimmed }
        if Self.isRemote(trimmed) {
            guard allowRemoteImages else { return nil }
            return prefetched[trimmed] ?? (trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed)
        }
        guard showLocalImages, let file = localFile(for: trimmed) else { return nil }
        return Self.dataURI(contentsOf: file, maxBytes: maxLocalBytes)
    }

    /// The local file an image source points to, if it stays inside the document's folder.
    public func localFile(for src: String) -> URL? {
        guard let documentURL else { return nil }
        let folder = documentURL.deletingLastPathComponent().standardizedFileURL
        var path = src
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        let url: URL
        if path.lowercased().hasPrefix("file://") {
            guard let u = URL(string: path) else { return nil }
            url = u
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path.removingPercentEncoding ?? path)
        } else {
            url = folder.appendingPathComponent(path.removingPercentEncoding ?? path)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = folder.resolvingSymlinksInPath().path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg", "jpe": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg", "svgz": "image/svg+xml"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        case "heic", "heif": "image/heic"
        case "ico": "image/x-icon"
        case "avif": "image/avif"
        default: nil
        }
    }

    public static func dataURI(contentsOf file: URL, maxBytes: Int) -> String? {
        guard let mime = mimeType(forExtension: file.pathExtension),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    public static func dataURI(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
