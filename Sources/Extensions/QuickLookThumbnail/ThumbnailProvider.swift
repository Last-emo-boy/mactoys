import AppKit
import PreviewKit
import QuickLookThumbnailing
import os

/// Finder thumbnails for SVG, G-code/binary G-code (embedded slicer thumbnail or a rendered
/// toolpath), STL, QOI, Markdown and PDF. Types switched off in Finder Add-ons settings return an
/// error so Finder keeps the regular icon.
@objc(MacToysThumbnailProvider)
final class MacToysThumbnailProvider: QLThumbnailProvider {
    private let log = Logger(subsystem: "com.w33d.mactoys", category: "thumbnails")

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = request.maximumSize
        let scale = max(1, request.scale)
        let settings = FinderAddonsSettings.load()
        let kind = PreviewKind.of(url)
        guard settings.thumbnailEnabled(kind) else {
            handler(nil, PreviewError.unsupported)
            return
        }
        let pixels = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)
        let log = self.log
        Task {
            do {
                let image = try await PreviewRenderer.thumbnail(for: url, kind: kind, maxSize: pixels, settings: settings)
                let fitted = ImageUtil.fit(CGSize(width: image.width, height: image.height), in: pixels)
                let size = CGSize(width: max(1, fitted.width / scale), height: max(1, fitted.height / scale))
                let reply = QLThumbnailReply(contextSize: size) { ctx -> Bool in
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(origin: .zero, size: size))
                    return true
                }
                if let badge = Self.badge(for: kind) { reply.extensionBadge = badge }
                handler(reply, nil)
            } catch {
                log.error("Thumbnail of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                handler(nil, error)
            }
        }
    }

    /// The small type label Finder draws on document-style thumbnails.
    static func badge(for kind: PreviewKind) -> String? {
        switch kind {
        case .markdown: "MD"
        case .gcode: "GCODE"
        case .bgcode: "BGCODE"
        case .stl: "STL"
        default: nil
        }
    }
}
