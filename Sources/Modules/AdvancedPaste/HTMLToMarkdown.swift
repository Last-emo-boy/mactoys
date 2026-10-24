import Foundation

/// Converts HTML (clipboard fragments, whole pages) to GitHub-flavored Markdown: headings,
/// paragraphs, emphasis (including Google Docs/Word inline styles), links, images, inline
/// code and fenced code blocks, nested and task lists, blockquotes and tables.
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String {
        render(html, plain: false)
    }

    /// Readable plain text: paragraphs, `•` bullets, tab-separated tables, no markup.
    public static func plainText(_ html: String) -> String {
        render(html, plain: true)
    }

    private static func render(_ html: String, plain: Bool) -> String {
        let root = HTMLParser.parse(html)
        let writer = MarkdownWriter()
        MarkdownRenderer(plain: plain).children(of: root, into: writer, Context())
        return writer.finish()
    }

    struct Context {
        var bold = false
        var italic = false
        var strike = false
        var link = false
        var table = false
        var listDepth = 0
    }
}

/// Accumulates Markdown, collapsing whitespace across nodes and turning block requests into
/// the right number of newlines.
final class MarkdownWriter {
    private(set) var out = ""
    private var pending = 0
    /// Fragments (inline element contents) keep a leading space so the caller can move it outside the markup.
    private let fragment: Bool

    init(fragment: Bool = false) {
        self.fragment = fragment
    }

    private var atLineStart: Bool { pending > 0 || (out.isEmpty ? !fragment : out.hasSuffix("\n")) }

    /// Asks for `n` newlines before the next content (1 = line break, 2 = paragraph).
    func block(_ n: Int) { pending = max(pending, n) }

    /// Markup or already-escaped text.
    func inline(_ s: String) {
        guard !s.isEmpty else { return }
        var s = Substring(s)
        if s.first == " ", atLineStart || out.hasSuffix(" ") {
            s = s.drop { $0 == " " }
            if s.isEmpty { return }
        }
        flush()
        out += s
    }

    /// Escaped document text; also escapes characters that would start a block at line start.
    func text(_ s: String) {
        guard !s.isEmpty else { return }
        var s = Substring(s)
        if s.first == " ", atLineStart || out.hasSuffix(" ") {
            s = s.drop { $0 == " " }
            if s.isEmpty { return }
        }
        if atLineStart { s = Substring(Self.escapeLineStart(String(s))) }
        flush()
        out += s
    }

    /// Verbatim text (code blocks, prebuilt list items).
    func raw(_ s: String) {
        flush()
        out += s
    }

    /// A Markdown hard line break.
    func hardBreak() {
        while out.hasSuffix(" ") { out.removeLast() }
        guard !out.isEmpty, pending == 0 else { return }
        out += "  \n"
    }

    private func flush() {
        guard pending > 0 else { return }
        if !out.isEmpty {
            while let last = out.last, last == " " || last == "\n" { out.removeLast() }
            if !out.isEmpty { out += String(repeating: "\n", count: pending) }
        }
        pending = 0
    }

    func finish() -> String {
        var s = out
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeLineStart(_ s: String) -> String {
        guard let first = s.first else { return s }
        if first == "#" || first == ">" { return "\\" + s }
        if (first == "-" || first == "+") && (s.count == 1 || s.dropFirst().first == " ") { return "\\" + s }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count < 10, s.dropFirst(digits.count).first == "." {
            return digits + "\\" + s.dropFirst(digits.count)
        }
        return s
    }
}

struct MarkdownRenderer {
    typealias Context = HTMLToMarkdown.Context
    let plain: Bool

    private static let skipped: Set<String> = ["head", "script", "style", "noscript", "template", "title", "meta", "link",
                                               "button", "select", "option", "datalist", "iframe", "object", "canvas",
                                               "audio", "video", "svg", "math", "map", "area", "colgroup", "col"]
    private static let containers: Set<String> = ["div", "section", "article", "header", "footer", "main", "aside", "nav",
                                                  "figure", "figcaption", "address", "details", "summary", "form",
                                                  "fieldset", "center", "hgroup", "dialog", "body", "html", "legend"]
    private static let blockLevel: Set<String> = containers.union(["p", "ul", "ol", "li", "table", "tr", "td", "th",
                                                                   "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
                                                                   "pre", "hr", "dl", "dt", "dd"])

    func children(of node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        for child in node.children { render(child, into: w, ctx) }
    }

    func render(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        switch node.kind {
        case .root: children(of: node, into: w, ctx)
        case .text:
            let t = Self.collapse(node.text)
            if plain { w.inline(t) } else { w.text(Self.escape(t, table: ctx.table)) }
        case .element: element(node, into: w, ctx)
        }
    }

    private func element(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        let name = node.name
        if Self.skipped.contains(name) { return }
        if Self.containers.contains(name) {
            w.block(1)
            children(of: node, into: w, ctx)
            w.block(1)
            return
        }
        switch name {
        case "br":
            if ctx.table { w.inline(plain ? " " : "<br>") } else if plain { w.raw("\n") } else { w.hardBreak() }
        case "hr":
            w.block(2)
            if !plain { w.raw("---") }
            w.block(2)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let inner = fragment(node, ctx).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { return }
            if ctx.table { w.inline(" " + inner + " "); return }
            let level = Int(String(name.dropFirst())) ?? 1
            w.block(2)
            w.raw(plain ? inner : String(repeating: "#", count: level) + " " + inner)
            w.block(2)
        case "p":
            w.block(2)
            children(of: node, into: w, ctx)
            w.block(2)
        case "blockquote": blockquote(node, into: w, ctx)
        case "pre": codeBlock(node, into: w, ctx)
        case "ul", "ol": list(node, ordered: name == "ol", into: w, ctx)
        case "li":
            // A list item outside a list.
            w.block(1)
            w.raw(plain ? "• " : "- ")
            children(of: node, into: w, ctx)
            w.block(1)
        case "dl":
            w.block(2)
            children(of: node, into: w, ctx)
            w.block(2)
        case "dt":
            w.block(1)
            emphasis(node, open: "**", close: "**", into: w, ctx) { $0.bold = true }
            w.block(1)
        case "dd":
            w.block(1)
            if !plain { w.raw(": ") }
            children(of: node, into: w, ctx)
            w.block(1)
        case "table": table(node, into: w, ctx)
        case "a": link(node, into: w, ctx)
        case "img": image(node, into: w)
        case "strong", "b", "em", "i", "cite", "dfn", "var", "del", "s", "strike", "span", "font", "u", "ins", "mark":
            styled(node, into: w, ctx)
        case "code", "kbd", "samp", "tt": inlineCode(node, into: w, ctx)
        case "input":
            if node["type"]?.lowercased() == "checkbox" { w.inline(node["checked"] != nil ? "[x] " : "[ ] ") }
        case "q":
            w.inline("“")
            children(of: node, into: w, ctx)
            w.inline("”")
        default:
            children(of: node, into: w, ctx)
        }
    }

    // MARK: Inline

    /// `<b>`, `<i>`, `<s>` and `<span style="font-weight:700">` — the style attribute wins,
    /// so Google Docs' `<b style="font-weight:normal">` wrapper adds nothing.
    private func styled(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        let style = Self.inlineStyle(node["style"])
        let name = node.name
        let bold = style.bold ?? (name == "strong" || name == "b")
        let italic = style.italic ?? ["em", "i", "cite", "dfn", "var"].contains(name)
        let strike = style.strike ?? ["del", "s", "strike"].contains(name)
        var open = "", close = ""
        var inner = ctx
        if bold && !ctx.bold { open += "**"; close = "**" + close; inner.bold = true }
        if italic && !ctx.italic { open += "*"; close = "*" + close; inner.italic = true }
        if strike && !ctx.strike { open += "~~"; close = "~~" + close; inner.strike = true }
        if open.isEmpty || plain || hasBlockDescendant(node) {
            children(of: node, into: w, ctx)
            return
        }
        let content = fragment(node, inner)
        wrap(content, open: open, close: close, into: w)
    }

    private func emphasis(_ node: HTMLNode, open: String, close: String, into w: MarkdownWriter, _ ctx: Context,
                          _ mark: (inout Context) -> Void) {
        var inner = ctx
        mark(&inner)
        if plain || hasBlockDescendant(node) { children(of: node, into: w, ctx); return }
        wrap(fragment(node, inner), open: open, close: close, into: w)
    }

    /// Puts markup around trimmed content, keeping surrounding spaces outside it.
    private func wrap(_ content: String, open: String, close: String, into w: MarkdownWriter) {
        let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else {
            if !content.isEmpty { w.inline(" ") }
            return
        }
        let lead = content.first?.isWhitespace == true ? " " : ""
        let trail = content.last?.isWhitespace == true ? " " : ""
        w.inline(lead + open + core + close + trail)
    }

    private func link(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        let href = (node["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var inner = ctx
        inner.link = true
        if ctx.link || plain || href.isEmpty || href.lowercased().hasPrefix("javascript:") || hasBlockDescendant(node) {
            children(of: node, into: w, ctx)
            return
        }
        let content = fragment(node, inner)
        let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return }
        let lead = content.first?.isWhitespace == true ? " " : ""
        let trail = content.last?.isWhitespace == true ? " " : ""
        let visible = Self.collapse(node.textContent).trimmingCharacters(in: .whitespaces)
        let title = node["title"].map { " \"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? ""
        if visible == href, title.isEmpty, href.contains(":"), !ctx.table {
            w.inline(lead + "<" + href + ">" + trail)
        } else {
            w.inline(lead + "[" + core + "](" + Self.destination(href) + title + ")" + trail)
        }
    }

    private func image(_ node: HTMLNode, into w: MarkdownWriter) {
        let src = (node["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = Self.collapse(node["alt"] ?? "").trimmingCharacters(in: .whitespaces)
        if plain { w.inline(alt); return }
        guard !src.isEmpty else { return }
        let title = node["title"].map { " \"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? ""
        let escapedAlt = alt.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        w.inline("![" + escapedAlt + "](" + Self.destination(src) + title + ")")
    }

    private func inlineCode(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        var content = node.textContent.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        content = content.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if plain { w.inline(content); return }
        if ctx.table { content = content.replacingOccurrences(of: "|", with: "\\|") }
        let fence = String(repeating: "`", count: Self.longestRun(of: "`", in: content) + 1)
        let pad = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
        w.inline(fence + pad + content + pad + fence)
    }

    // MARK: Blocks

    private func codeBlock(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        var code = node.textContent.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        if code.hasPrefix("\n") { code.removeFirst() }
        while let last = code.last, last.isWhitespace { code.removeLast() }
        guard !code.isEmpty else { return }
        if ctx.table {
            inlineCode(node, into: w, ctx)
            return
        }
        w.block(2)
        if plain {
            w.raw(code)
        } else {
            let fence = String(repeating: "`", count: max(3, Self.longestRun(of: "`", in: code) + 1))
            w.raw(fence + language(of: node) + "\n" + code + "\n" + fence)
        }
        w.block(2)
    }

    private func language(of pre: HTMLNode) -> String {
        let classes = ([pre["class"]] + pre.elementChildren.filter { $0.name == "code" }.map { $0["class"] })
            .compactMap { $0 }.flatMap { $0.split(separator: " ") }
        for c in classes {
            for prefix in ["language-", "lang-"] where c.hasPrefix(prefix) { return String(c.dropFirst(prefix.count)) }
        }
        return pre["data-language"] ?? pre["lang"] ?? ""
    }

    private func blockquote(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        let content = blocks(node, ctx)
        guard !content.isEmpty else { return }
        w.block(2)
        w.raw(plain ? content : content.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
        w.block(2)
    }

    private func list(_ node: HTMLNode, ordered: Bool, into w: MarkdownWriter, _ ctx: Context) {
        var inner = ctx
        inner.listDepth += 1
        var number = ordered ? Int(node["start"] ?? "") ?? 1 : 1
        var items: [String] = []
        var widths: [Int] = []
        for child in node.children {
            switch child.kind {
            case .text:
                let t = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                items.append(item(marker: bullet(ordered, number), content: plain ? t : Self.escape(t, table: false)))
                widths.append(bullet(ordered, number).count)
                number += 1
            case .element where child.name == "li":
                let marker = bullet(ordered, number)
                items.append(item(marker: marker, content: blocks(child, inner)))
                widths.append(marker.count)
                number += 1
            case .element where child.name == "ul" || child.name == "ol":
                // A nested list placed directly in the list belongs to the previous item.
                let nested = blocks(child, inner, wrapInElement: true)
                guard !nested.isEmpty else { continue }
                if let last = items.indices.last {
                    let pad = String(repeating: " ", count: widths[last])
                    items[last] += "\n" + nested.components(separatedBy: "\n").map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n")
                } else {
                    items.append(nested)
                    widths.append(0)
                }
            default:
                let content = blocks(child, inner, wrapInElement: true)
                guard !content.isEmpty else { continue }
                items.append(item(marker: bullet(ordered, number), content: content))
                widths.append(bullet(ordered, number).count)
                number += 1
            }
        }
        guard !items.isEmpty else { return }
        let loose = items.contains { $0.contains("\n\n") }
        w.block(ctx.listDepth == 0 ? 2 : 1)
        w.raw(items.joined(separator: loose ? "\n\n" : "\n"))
        w.block(ctx.listDepth == 0 ? 2 : 1)
    }

    private func bullet(_ ordered: Bool, _ n: Int) -> String {
        ordered ? "\(n). " : (plain ? "• " : "- ")
    }

    private func item(marker: String, content: String) -> String {
        let pad = String(repeating: " ", count: marker.count)
        let lines = content.components(separatedBy: "\n")
        let rest = lines.dropFirst().map { $0.isEmpty ? "" : pad + $0 }
        return ([marker + (lines.first ?? "")] + rest).joined(separator: "\n")
    }

    private func table(_ node: HTMLNode, into w: MarkdownWriter, _ ctx: Context) {
        struct Cell { var text: String; var align: String?; var span: Int; var node: HTMLNode }
        var rows: [[Cell]] = []
        var caption: HTMLNode?
        var nested = false
        func collect(_ n: HTMLNode) {
            for child in n.elementChildren {
                switch child.name {
                case "thead", "tbody", "tfoot": collect(child)
                case "caption": caption = child
                case "tr":
                    var cells: [Cell] = []
                    for cell in child.elementChildren where cell.name == "td" || cell.name == "th" {
                        if cell.descendants(named: "table") { nested = true }
                        var cctx = ctx
                        cctx.table = true
                        let text = fragment(cell, cctx).replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let span = max(1, min(50, Int(cell["colspan"] ?? "") ?? 1))
                        cells.append(Cell(text: text, align: Self.alignment(cell), span: span, node: cell))
                    }
                    if !cells.isEmpty { rows.append(cells) }
                default: break
                }
            }
        }
        collect(node)
        guard !rows.isEmpty else { return }
        let width = rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0

        // Layout tables (one column, or tables inside cells) read better as plain blocks.
        if width <= 1 || nested {
            for row in rows {
                for cell in row {
                    w.block(1)
                    children(of: cell.node, into: w, ctx)
                    w.block(1)
                }
            }
            return
        }

        var grid: [[String]] = []
        var aligns = [String?](repeating: nil, count: width)
        for (r, row) in rows.enumerated() {
            var line: [String] = []
            for cell in row {
                if r == 0, line.count < width { aligns[line.count] = cell.align }
                line.append(cell.text)
                line += Array(repeating: "", count: cell.span - 1)
            }
            line += Array(repeating: "", count: max(0, width - line.count))
            grid.append(line)
        }

        w.block(2)
        if let caption {
            let c = fragment(caption, ctx).trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { w.raw(c); w.block(2) }
        }
        if plain {
            w.raw(grid.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            w.block(2)
            return
        }
        var widths = [Int](repeating: 3, count: width)
        for line in grid { for (i, cell) in line.enumerated() { widths[i] = max(widths[i], cell.count) } }
        func pad(_ s: String, _ i: Int) -> String {
            let space = widths[i] - s.count
            switch aligns[i] {
            case "right": return String(repeating: " ", count: space) + s
            case "center": return String(repeating: " ", count: space / 2) + s + String(repeating: " ", count: space - space / 2)
            default: return s + String(repeating: " ", count: space)
            }
        }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { pad($1, $0) }.joined(separator: " | ") + " |"
        }
        let separator = "| " + widths.enumerated().map { i, n -> String in
            switch aligns[i] {
            case "right": return String(repeating: "-", count: n - 1) + ":"
            case "center": return ":" + String(repeating: "-", count: n - 2) + ":"
            case "left": return ":" + String(repeating: "-", count: n - 1)
            default: return String(repeating: "-", count: n)
            }
        }.joined(separator: " | ") + " |"
        var lines = [line(grid[0]), separator]
        lines += grid.dropFirst().map(line)
        w.raw(lines.joined(separator: "\n"))
        w.block(2)
    }

    // MARK: Helpers

    /// Renders an element's children inline into a string.
    private func fragment(_ node: HTMLNode, _ ctx: Context) -> String {
        let sub = MarkdownWriter(fragment: true)
        children(of: node, into: sub, ctx)
        return sub.out
    }

    /// Renders an element's children as blocks into a trimmed string.
    private func blocks(_ node: HTMLNode, _ ctx: Context, wrapInElement: Bool = false) -> String {
        let sub = MarkdownWriter()
        if wrapInElement { render(node, into: sub, ctx) } else { children(of: node, into: sub, ctx) }
        return sub.finish()
    }

    private func hasBlockDescendant(_ node: HTMLNode) -> Bool {
        node.children.contains { $0.kind == .element && (Self.blockLevel.contains($0.name) || hasBlockDescendant($0)) }
    }

    static func collapse(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var space = false
        for ch in s {
            if ch.isWhitespace {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(ch)
                space = false
            }
        }
        return out
    }

    static func escape(_ s: String, table: Bool) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "\\", "`", "*", "_", "[", "]": out.append("\\"); out.append(ch)
            case "|" where table: out += "\\|"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Link destinations: spaces and parentheses percent-encoded so the URL stays one token.
    static func destination(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    static func longestRun(of c: Character, in s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            if ch == c { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }

    static func alignment(_ cell: HTMLNode) -> String? {
        if let a = cell["align"]?.lowercased(), ["left", "right", "center"].contains(a) { return a }
        let style = declarations(cell["style"])
        if let a = style["text-align"], ["left", "right", "center"].contains(a) { return a }
        return nil
    }

    static func declarations(_ style: String?) -> [String: String] {
        var out: [String: String] = [:]
        for part in (style ?? "").split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return out
    }

    static func inlineStyle(_ style: String?) -> (bold: Bool?, italic: Bool?, strike: Bool?) {
        let d = declarations(style)
        var bold: Bool?
        if let w = d["font-weight"] {
            if ["bold", "bolder", "600", "700", "800", "900"].contains(w) { bold = true }
            else if ["normal", "lighter", "100", "200", "300", "400", "500"].contains(w) { bold = false }
        }
        var italic: Bool?
        if let s = d["font-style"] { italic = s.contains("italic") || s.contains("oblique") }
        var strike: Bool?
        if let t = d["text-decoration"] ?? d["text-decoration-line"] { strike = t.contains("line-through") }
        return (bold, italic, strike)
    }
}

extension HTMLNode {
    func descendants(named name: String) -> Bool {
        children.contains { $0.kind == .element && ($0.name == name || $0.descendants(named: name)) }
    }
}
