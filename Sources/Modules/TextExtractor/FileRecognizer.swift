import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Why a file or the clipboard gave no text.
enum RecognitionError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case lockedPDF(String)
    case noImageOnClipboard

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            String(localized: "“\(name)” couldn’t be read.", comment: "Text Extractor error; %@ is a file name")
        case .unsupported(let name):
            String(localized: "“\(name)” isn’t an image or a PDF.", comment: "Text Extractor error; %@ is a file name")
        case .lockedPDF(let name):
            String(localized: "“\(name)” is protected with a password.", comment: "Text Extractor error; %@ is a PDF file name")
        case .noImageOnClipboard:
            String(localized: "There’s no image on the clipboard.", comment: "Text Extractor error")
        }
    }
}

/// Text and barcodes from image files, PDFs and clipboard images. PDF pages with a text layer are
/// read from it directly (exact, instant); scanned pages are rendered and recognized.
enum FileRecognizer {
    /// One page (or image) worth of boxes, in its own top-left space.
    struct Page: Sendable {
        var boxes: [TextBox]
        var barcodes: [Barcode]
    }

    /// Pages read from a PDF at most; longer documents are cut off (and say so in the result).
    static let maxPages = 60
    /// Pages also scanned for barcodes (tickets and boarding passes keep them up front).
    static let maxBarcodePages = 10

    static let supportedTypes: [UTType] = [.image, .pdf]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    /// Recognizes a file; `progress(page, pages)` is called before each PDF page.
    static func recognize(_ url: URL, options: TextRecognizer.Options, barcodes: Bool,
                          progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [Page] {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { throw RecognitionError.unreadable(name) }
            if doc.isLocked { throw RecognitionError.lockedPDF(name) }
            let count = min(doc.pageCount, maxPages)
            var pages: [Page] = []
            for index in 0..<count {
                progress(index + 1, count)
                guard let page = doc.page(at: index) else { continue }
                pages.append(try recognize(page, index: index, options: options, barcodes: barcodes))
            }
            return pages
        }
        guard type?.conforms(to: .image) == true else { throw RecognitionError.unsupported(name) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        else { throw RecognitionError.unreadable(name) }
        let out = try TextRecognizer.analyze(image, options: options, barcodes: barcodes)
        return [Page(boxes: out.boxes, barcodes: out.barcodes)]
    }

    static func recognize(_ image: CGImage, options: TextRecognizer.Options, barcodes: Bool) throws -> Page {
        let out = try TextRecognizer.analyze(image, options: options, barcodes: barcodes)
        return Page(boxes: out.boxes, barcodes: out.barcodes)
    }

    private static func recognize(_ page: PDFPage, index: Int, options: TextRecognizer.Options, barcodes: Bool) throws -> Page {
        let bounds = page.bounds(for: .cropBox)
        let hasText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            let lines = page.selection(for: bounds)?.selectionsByLine() ?? []
            let boxes = lines.compactMap { line -> TextBox? in
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let r = line.bounds(for: page)
                // PDF space is bottom-left; boxes are top-left.
                return TextBox(text, CGRect(x: r.minX - bounds.minX, y: bounds.maxY - r.maxY, width: r.width, height: r.height))
            }
            var codes: [Barcode] = []
            if barcodes, index < maxBarcodePages, let image = render(page, scale: 2) {
                codes = (try? TextRecognizer.barcodes(in: image)) ?? []
            }
            return Page(boxes: boxes, barcodes: codes)
        }
        guard let image = render(page, scale: 3) else { return Page(boxes: [], barcodes: []) }
        let out = try TextRecognizer.analyze(image, options: options, barcodes: barcodes && index < maxBarcodePages)
        return Page(boxes: out.boxes, barcodes: out.barcodes)
    }

    /// Draws a page on white at `scale` × its point size (capped so huge pages stay reasonable).
    static func render(_ page: PDFPage, scale requested: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(requested, 6000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Image data on the clipboard (a screenshot copied with ⌃⇧⌘4, an image copied in a browser).
    @MainActor static func clipboardImage(_ pb: NSPasteboard = .general) -> CGImage? {
        guard pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                      NSPasteboard.PasteboardType("public.heic")]) != nil,
              let image = NSImage(pasteboard: pb) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Image and PDF files copied in Finder.
    @MainActor static func clipboardFileURLs(_ pb: NSPasteboard = .general) -> [URL] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter(isSupported)
    }
}
