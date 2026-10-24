import AppKit
import CoreText

/// A page-like icon of a Markdown document: headings, text, lists and code drawn with CoreText
/// (thread-safe, no WebKit), for Finder thumbnails.
public enum MarkdownThumbnail {
    public static func render(_ text: String, size: CGSize) -> CGImage? {
        let w = max(16, Int(size.width)), h = max(16, Int(size.height))
        guard let ctx = ImageUtil.context(width: w, height: h) else { return nil }
        // A portrait sheet centered in the square.
        let pageW = CGFloat(min(w, Int(Double(h) * 0.78))), pageH = CGFloat(h)
        let page = CGRect(x: (CGFloat(w) - pageW) / 2, y: 0, width: pageW, height: pageH)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(page)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(max(1, pageW / 256))
        ctx.stroke(page.insetBy(dx: 0.5, dy: 0.5))

        let unit = pageW / 34     // body font size relative to the page
        let content = attributed(text, unit: unit)
        let inset = pageW * 0.09
        let frameRect = page.insetBy(dx: inset, dy: inset)
        let setter = CTFramesetterCreateWithAttributedString(content)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    static func attributed(_ text: String, unit: CGFloat) -> NSAttributedString {
        let parser = MDBlockParser(allowHTML: false)
        let blocks = parser.parse(MDBlockParser.lines(of: String(text.prefix(20_000))))
        let ctx = MDInlineContext(references: parser.references, footnoteLabels: [], allowHTML: false) { _ in nil }
        let out = NSMutableAttributedString()
        let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        let muted = NSColor(srgbRed: 0.40, green: 0.44, blue: 0.48, alpha: 1)
        let accent = NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 1)

        func para(_ spacing: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.lineBreakMode = .byWordWrapping
            return p
        }
        func add(_ s: String, font: NSFont, color: NSColor, spacing: CGFloat) {
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color,
                                                                          .paragraphStyle: para(spacing)]))
        }
        func plain(_ inline: String) -> String { MDInline.plainText(MDInline.render(inline, ctx)) }

        func walk(_ list: [MDBlock], depth: Int) {
            for block in list {
                guard out.length < 4000 else { return }
                switch block {
                case .heading(let level, let t):
                    let size = unit * max(1.1, 2.1 - CGFloat(level) * 0.25)
                    add(plain(t), font: .boldSystemFont(ofSize: size), color: level <= 2 ? ink : accent, spacing: unit * 0.6)
                case .paragraph(let t):
                    add(plain(t).replacingOccurrences(of: "\n", with: " "), font: .systemFont(ofSize: unit), color: ink, spacing: unit * 0.6)
                case .code(_, let t):
                    add(String(t.prefix(600)).trimmingCharacters(in: .newlines), font: .monospacedSystemFont(ofSize: unit * 0.85, weight: .regular),
                        color: muted, spacing: unit * 0.6)
                case .quote(let inner):
                    walk(inner, depth: depth + 1)
                case .list(let ordered, let start, _, let items):
                    for (i, item) in items.enumerated() {
                        let bullet = item.task.map { $0 ? "☑︎ " : "☐ " } ?? (ordered ? "\(start + i). " : "• ")
                        let first = item.blocks.first.map { b -> String in
                            if case .paragraph(let t) = b { return plain(t).replacingOccurrences(of: "\n", with: " ") }
                            return ""
                        } ?? ""
                        add(String(repeating: "   ", count: depth) + bullet + first, font: .systemFont(ofSize: unit), color: ink, spacing: unit * 0.25)
                        walk(Array(item.blocks.dropFirst()), depth: depth + 1)
                    }
                case .table(_, let header, let rows):
                    add(header.map(plain).joined(separator: "  │  "), font: .boldSystemFont(ofSize: unit * 0.9), color: ink, spacing: unit * 0.2)
                    for row in rows.prefix(8) {
                        add(row.map(plain).joined(separator: "  │  "), font: .systemFont(ofSize: unit * 0.9), color: muted, spacing: unit * 0.2)
                    }
                case .rule:
                    add("―――――――――", font: .systemFont(ofSize: unit), color: muted, spacing: unit * 0.4)
                case .html:
                    break
                }
            }
        }
        walk(blocks, depth: 0)
        if out.length == 0 { add(" ", font: .systemFont(ofSize: unit), color: ink, spacing: 0) }
        return out
    }
}
