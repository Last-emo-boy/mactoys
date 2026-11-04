import Foundation
import PDFKit
import Quartz

/// Shrinks PDFs by re-encoding their embedded images at a lower resolution and JPEG quality through
/// a Quartz filter (the mechanism behind Preview's "Reduce File Size", with our own settings).
/// Text, vector art, links and outlines stay as they are, so text remains selectable; results that
/// lost text are rejected.
enum PDFOptimizer {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case locked
        case failed
        case lostText

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Not a PDF MacToys can read")
            case .locked: String(localized: "The PDF is password-protected")
            case .failed: String(localized: "The PDF could not be rewritten")
            case .lostText: String(localized: "Rewriting the PDF would lose its text, so it was left as it is")
            }
        }
    }

    struct Result: Sendable {
        var pageCount: Int
    }

    /// The Quartz filter description: images limited to `resolution` dpi, JPEG at `quality` (0…1).
    static func filterProperties(resolution: Int, quality: Double) -> [String: Any] {
        ["Domains": ["Applications": true, "Printing": true],
         "FilterType": 1,
         "Name": "MacToys Optimizer",
         "FilterData": [
             "ColorSettings": [
                 "ImageSettings": [
                     "Compression Quality": min(1, max(0.1, quality)),
                     "ImageCompression": "ImageJPEGCompress",
                     "ImageScaleSettings": [
                         "ImageResolution": max(36, resolution),
                         "ImageScaleInterpolate": true,
                         "ImageSizeMax": 10_000,
                         "ImageSizeMin": 0,
                     ] as [String: Any],
                 ] as [String: Any],
             ],
         ] as [String: Any]]
    }

    /// Writes the optimized copy of `source` to `output` (which must not be `source`).
    static func optimize(_ source: URL, to output: URL, resolution: Int, quality: Double) throws -> Result {
        guard let document = PDFDocument(url: source) else { throw Failure.unreadable }
        guard !document.isLocked, !document.isEncrypted else { throw Failure.locked }
        let filterURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoys-optimizer-\(UUID().uuidString).qfilter")
        defer { try? FileManager.default.removeItem(at: filterURL) }
        let plist = try PropertyListSerialization.data(fromPropertyList: filterProperties(resolution: resolution, quality: quality),
                                                       format: .xml, options: 0)
        try plist.write(to: filterURL)
        guard let filter = QuartzFilter(url: filterURL) else { throw Failure.failed }

        let written = document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        guard written, let result = PDFDocument(url: output) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.failed
        }
        guard keepsText(original: document, result: result) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.lostText
        }
        return Result(pageCount: result.pageCount)
    }

    /// The result has (nearly) all of the original's text.
    static func keepsText(original: PDFDocument, result: PDFDocument) -> Bool {
        func letters(_ d: PDFDocument) -> Int { (d.string ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }
        let before = letters(original)
        guard before > 0 else { return true }
        return result.pageCount == original.pageCount && Double(letters(result)) >= Double(before) * 0.98
    }
}
