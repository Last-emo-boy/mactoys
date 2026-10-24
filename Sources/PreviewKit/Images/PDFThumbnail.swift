import AppKit
import PDFKit

/// First-page rendering of PDF documents.
public enum PDFThumbnail {
    /// The first page drawn on white, fitting `maxSize` pixels. Nil for locked or unreadable PDFs.
    public static func firstPage(of url: URL, maxSize: CGSize) -> CGImage? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
        return render(page, maxSize: maxSize)
    }

    public static func firstPage(data: Data, maxSize: CGSize) -> CGImage? {
        guard let doc = PDFDocument(data: data), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
        return render(page, maxSize: maxSize)
    }

    public static func pageCount(of url: URL) -> Int? {
        PDFDocument(url: url)?.pageCount
    }

    private static func render(_ page: PDFPage, maxSize: CGSize) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let s = min(maxSize.width / pageSize.width, maxSize.height / pageSize.height)
        let w = max(1, Int(pageSize.width * s)), h = max(1, Int(pageSize.height * s))
        guard let ctx = ImageUtil.context(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }
}
