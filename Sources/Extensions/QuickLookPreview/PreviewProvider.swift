import AppKit
import PreviewKit
import QuickLookUI
import UniformTypeIdentifiers
import os

/// Data-based Quick Look previews: HTML for Markdown, source code, JSON/XML and CSV/TSV;
/// PNG images for SVG, G-code, binary G-code, STL and QOI. Respects the per-type switches in
/// Finder Add-ons settings (a disabled text type shows as plain text, a disabled graphics type
/// falls back to the generic file preview).
@objc(MacToysPreviewProvider)
final class MacToysPreviewProvider: QLPreviewProvider, QLPreviewingController {
    private let log = Logger(subsystem: "com.w33d.mactoys", category: "quicklook")

    /// Bitmap size for graphics previews (pixels); shown at half size (Retina).
    private static let imagePixels = CGSize(width: 1800, height: 1350)

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let settings = FinderAddonsSettings.load()
        var kind = PreviewKind.of(url)
        if kind == .other || kind == .folder { kind = .code("text") }      // a source type we claim but don't know by name
        let options = PreviewOptions(settings: settings)

        guard settings.previewEnabled(kind) else {
            if kind.isText { return try plainText(url, maxBytes: options.maxTextBytes) }
            throw PreviewError.unsupported
        }
        do {
            if kind.isImage {
                let image = try await PreviewRenderer.image(for: url, kind: kind, maxSize: Self.imagePixels, options: options)
                guard let png = ImageUtil.pngData(image) else { throw PreviewError.unreadable("PNG encoding failed") }
                let size = CGSize(width: max(320, CGFloat(image.width) / 2), height: max(240, CGFloat(image.height) / 2))
                return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in png }
            }
            var prefetched: [String: String] = [:]
            if kind == .markdown, options.allowRemoteImages {
                let text = try PreviewRenderer.readText(url, maxBytes: options.maxTextBytes)
                prefetched = await RemoteImages.fetch(MarkdownRenderer.imageSources(in: text, options: options.markdown)
                    .filter(MarkdownImagePolicy.isRemote))
            }
            let html = try PreviewRenderer.html(for: url, kind: kind, options: options, prefetchedImages: prefetched)
            let width: CGFloat = kind == .markdown ? 960 : 1000
            return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: width, height: 800)) { reply in
                reply.stringEncoding = .utf8
                return Data(html.utf8)
            }
        } catch PreviewError.tooLarge(let bytes) where kind.isText {
            log.info("\(url.lastPathComponent, privacy: .public) is too large (\(bytes) bytes); showing a notice")
            return notice(PreviewError.tooLarge(bytes).localizedDescription, title: url.lastPathComponent)
        } catch {
            log.error("Preview of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The file as plain text (what Quick Look shows for text without MacToys).
    private func plainText(_ url: URL, maxBytes: Int) throws -> QLPreviewReply {
        let text = try PreviewRenderer.readText(url, maxBytes: maxBytes)
        let data = Data(text.utf8)
        return QLPreviewReply(dataOfContentType: .plainText, contentSize: CGSize(width: 900, height: 800)) { reply in
            reply.stringEncoding = .utf8
            return data
        }
    }

    private func notice(_ message: String, title: String) -> QLPreviewReply {
        let html = HTML.document(title: title, body: "<div class=\"notice\" style=\"padding:28px\">\(HTML.escape(message))</div>",
                                 theme: .auto, extraCSS: Styles.code)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: 200)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }
}

/// Downloads remote Markdown images (when the user allowed them) so the preview can inline them:
/// Quick Look's HTML view doesn't load network resources itself.
enum RemoteImages {
    static let maxCount = 24
    static let maxBytes = 8 * 1024 * 1024

    static func fetch(_ sources: [String]) async -> [String: String] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, String?).self) { group in
            for src in sources.prefix(maxCount) {
                group.addTask {
                    let link = src.hasPrefix("//") ? "https:" + src : src
                    guard let url = URL(string: link) else { return (src, nil) }
                    do {
                        let (data, response) = try await session.data(from: url)
                        guard data.count <= maxBytes, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return (src, nil) }
                        let mime = response.mimeType.flatMap { $0.hasPrefix("image/") ? $0 : nil }
                            ?? MarkdownImagePolicy.mimeType(forExtension: url.pathExtension) ?? "image/png"
                        return (src, MarkdownImagePolicy.dataURI(data, mime: mime))
                    } catch {
                        return (src, nil)
                    }
                }
            }
            var map: [String: String] = [:]
            for await (src, uri) in group { if let uri { map[src] = uri } }
            return map
        }
    }
}
