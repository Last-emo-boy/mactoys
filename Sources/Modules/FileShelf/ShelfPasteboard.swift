import AppKit
import MacToysCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    static let gif = NSPasteboard.PasteboardType(UTType.gif.identifier)
    static let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)
    static let urlName = NSPasteboard.PasteboardType("public.url-name")
}

/// Turns what's on a pasteboard (a drop or the clipboard) into `ShelfDrop`s, one per pasteboard
/// item: files and folders, then images, then links, then text.
enum ShelfPasteboardReader {
    /// Types a shelf accepts as a drop target (file promises are added by the panel).
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff, .jpeg, .gif, .heic, .rtf]

    /// Whether the pasteboard holds anything a shelf takes (cheap: looks at types only).
    static func hasContent(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: acceptedTypes) != nil
    }

    static func drops(from pasteboard: NSPasteboard) -> [ShelfDrop] {
        (pasteboard.pasteboardItems ?? []).compactMap(drop(from:))
    }

    static func drop(from item: NSPasteboardItem) -> ShelfDrop? {
        let types = item.types
        if types.contains(.fileURL), let s = item.string(forType: .fileURL), let url = fileURL(s) {
            return .file(url)
        }
        // Image bytes in formats worth keeping as they are, then ones converted to PNG.
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.jpeg, "jpg"), (.gif, "gif")] where types.contains(type) {
            if let data = item.data(forType: type), !data.isEmpty { return .image(data, ext) }
        }
        for type in [NSPasteboard.PasteboardType.tiff, .heic] where types.contains(type) {
            if let data = item.data(forType: type), let png = pngData(data) { return .image(png, "png") }
        }
        if types.contains(.URL), let s = item.string(forType: .URL), let url = URL(string: s), url.scheme != nil {
            if url.isFileURL { return .file(url.standardizedFileURL) }
            let title = item.string(forType: .urlName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .link(url, title: title?.isEmpty == false ? title : nil)
        }
        if let text = item.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let url = webURL(trimmed) { return .link(url, title: nil) }
            return .text(text)
        }
        if types.contains(.rtf), let data = item.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        return nil
    }

    /// A pasted string that is one web address and nothing else.
    static func webURL(_ s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace), let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// Finder writes file *reference* URLs (`file:///.file/id=…`); resolve them to paths.
    private static func fileURL(_ s: String) -> URL? {
        guard let ns = NSURL(string: s), ns.isFileURL else { return nil }
        return (ns.filePathURL ?? ns as URL).standardizedFileURL
    }

    private static func pngData(_ data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}

/// Puts shelf items on a pasteboard (copy) or into drags.
@MainActor
enum ShelfPasteboardWriter {
    /// Writes the items to the pasteboard as Finder and other apps expect: files as file URLs, text
    /// as text, images as image data, links as URLs.
    static func copy(_ items: [ShelfItem], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.compactMap(pasteboardItem(for:)))
    }

    static func pasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
        let p = NSPasteboardItem()
        switch item.kind {
        case .file:
            p.setString(item.url.absoluteString, forType: .fileURL)
            p.setString(item.name, forType: .string)
        case .text:
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return nil }
            p.setString(text, forType: .string)
        case .image:
            guard let data = try? Data(contentsOf: item.url) else { return nil }
            p.setData(data, forType: imageType(for: item))
            if let tiff = NSImage(data: data)?.tiffRepresentation, imageType(for: item) != .tiff {
                p.setData(tiff, forType: .tiff)
            }
        case .link:
            guard let link = item.link else { return nil }
            p.setString(link.absoluteString, forType: .URL)
            p.setString(link.absoluteString, forType: .string)
            if let title = item.preview { p.setString(title, forType: .urlName) }
        }
        return p
    }

    /// A drag writer: file URLs for files (Finder moves or copies them as usual), a file promise
    /// that also carries the text, image or link for clippings — text editors get the text,
    /// Finder gets a file.
    static func dragWriter(for item: ShelfItem) -> NSPasteboardWriting {
        guard item.isClipping else { return item.url as NSURL }
        let provider = ClippingPromiseProvider(fileType: item.contentType ?? UTType.data.identifier,
                                               delegate: ClippingPromiseDelegate.shared)
        provider.userInfo = ClippingPayload(item: item)
        return provider
    }

    static func imageType(for item: ShelfItem) -> NSPasteboard.PasteboardType {
        switch item.url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "tif", "tiff": .tiff
        default: .png
        }
    }
}

/// What a clipping's file promise carries besides the promise.
struct ClippingPayload: @unchecked Sendable {
    let url: URL
    let name: String
    let kind: ShelfItem.Kind
    let link: URL?
    let title: String?
    let imageType: NSPasteboard.PasteboardType

    @MainActor
    init(item: ShelfItem) {
        url = item.url
        name = item.name
        kind = item.kind
        link = item.link
        title = item.preview
        imageType = ShelfPasteboardWriter.imageType(for: item)
    }

    /// The non-promise types, written right away.
    var types: [NSPasteboard.PasteboardType] {
        switch kind {
        case .file: []
        case .text: [.string]
        case .image: imageType == .tiff ? [.tiff] : [imageType, .tiff]
        case .link: [.URL, .string, .urlName]
        }
    }

    func value(for type: NSPasteboard.PasteboardType) -> Any? {
        switch (kind, type) {
        case (.text, .string): return try? String(contentsOf: url, encoding: .utf8)
        case (.image, .tiff): return (try? Data(contentsOf: url)).flatMap { NSImage(data: $0)?.tiffRepresentation }
        case (.image, imageType): return try? Data(contentsOf: url)
        case (.link, .URL): return (link as NSURL?)?.pasteboardPropertyList(forType: .URL)
        case (.link, .string): return link?.absoluteString
        case (.link, .urlName): return title ?? link?.host()
        default: return nil
        }
    }
}

/// A file promise for a clipping that also offers the clipping's text, image or link.
final class ClippingPromiseProvider: NSFilePromiseProvider {
    private var payload: ClippingPayload? { userInfo as? ClippingPayload }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + (payload?.types ?? [])
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        payload?.types.contains(type) == true ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if payload?.types.contains(type) == true { return payload?.value(for: type) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Writes promised clipping files where the drop landed (Finder, Mail…), copying them out of the
/// clippings store.
final class ClippingPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = ClippingPromiseDelegate()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "shelf.promises"
        return q
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? ClippingPayload)?.name ?? "Clipping"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload = provider.userInfo as? ClippingPayload else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let fm = FileManager.default
        var target = url
        if fm.fileExists(atPath: target.path) {
            let folder = url.deletingLastPathComponent()
            let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            target = folder.appendingPathComponent(ShelfNaming.unique(url.lastPathComponent, existing: existing))
        }
        do {
            try fm.copyItem(at: payload.url, to: target)
            completionHandler(nil)
        } catch {
            Log.for("shelf").error("Could not write promised file: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
