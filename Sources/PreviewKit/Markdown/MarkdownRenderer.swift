import Foundation

/// Markdown rendering options.
public struct MarkdownOptions: Sendable, Equatable {
    /// Pass raw HTML blocks and inline tags through (scripts never run: the page's CSP blocks them).
    /// When false they are shown as text.
    public var allowHTML: Bool
    /// Color fenced code blocks with `SyntaxHighlighter`.
    public var highlightCode: Bool

    public init(allowHTML: Bool = true, highlightCode: Bool = true) {
        self.allowHTML = allowHTML
        self.highlightCode = highlightCode
    }
}

/// GitHub-flavored Markdown → HTML: headings (with ids), emphasis, strikethrough, links, autolinks,
/// images, lists and task lists, fenced code with highlighting, tables, block quotes, rules,
/// footnotes and (optionally) raw HTML.
public enum MarkdownRenderer {
    /// The article HTML (no `<html>` wrapper). `image` maps each image source to the URL to use,
    /// or nil to show a placeholder instead.
    public static func body(_ text: String, options: MarkdownOptions = MarkdownOptions(),
                            image: @escaping (String) -> String? = { $0 }) -> String {
        let parser = MDBlockParser(allowHTML: options.allowHTML)
        let blocks = parser.parse(MDBlockParser.lines(of: text))
        let ctx = MDInlineContext(references: parser.references, footnoteLabels: Set(parser.footnotes.keys),
                                  allowHTML: options.allowHTML, image: image)
        var writer = MDWriter(ctx: ctx, options: options)
        var html = writer.blocks(blocks, tight: false)
        // Footnote bodies may reference further footnotes, so keep going until all are written.
        var written = 0
        var notes = ""
        while written < ctx.footnoteOrder.count {
            let label = ctx.footnoteOrder[written]
            written += 1
            let id = HTML.escape(HTML.slug(label))
            let content = writer.blocks(parser.footnotes[label] ?? [], tight: false,
                                        trailer: " <a href=\"#fnref-\(id)\" class=\"fnback\">↩</a>")
            notes += "<li id=\"fn-\(id)\">\n\(content)</li>\n"
        }
        if !notes.isEmpty { html += "<section class=\"footnotes\"><ol>\n\(notes)</ol></section>\n" }
        return html
    }

    /// Every image source referenced by the document, in order, without duplicates.
    public static func imageSources(in text: String, options: MarkdownOptions = MarkdownOptions()) -> [String] {
        var seen: [String] = []
        _ = body(text, options: options) { src in
            if !seen.contains(src) { seen.append(src) }
            return nil
        }
        return seen
    }

    /// A complete themed page.
    public static func page(_ text: String, title: String, theme: PreviewTheme = .auto, fontSize: Double = 14,
                            options: MarkdownOptions = MarkdownOptions(), allowRemoteImages: Bool = false,
                            image: @escaping (String) -> String? = { $0 }) -> String {
        let article = "<article class=\"markdown-body\">\n\(body(text, options: options, image: image))</article>"
        return HTML.document(title: title, body: article, theme: theme, extraCSS: Styles.markdown,
                             allowRemoteImages: allowRemoteImages, fontSize: fontSize)
    }
}

private struct MDWriter {
    let ctx: MDInlineContext
    let options: MarkdownOptions
    var usedIDs: [String: Int] = [:]

    init(ctx: MDInlineContext, options: MarkdownOptions) {
        self.ctx = ctx
        self.options = options
    }

    mutating func blocks(_ list: [MDBlock], tight: Bool, prefix: String = "", trailer: String = "") -> String {
        var out = ""
        for (index, block) in list.enumerated() {
            let first = index == 0
            let last = index == list.count - 1
            switch block {
            case .paragraph(let text):
                let inner = (first ? prefix : "") + MDInline.render(text, ctx) + (last ? trailer : "")
                out += tight ? inner + (last ? "" : "\n") : "<p>\(inner)</p>\n"
            default:
                if first && !prefix.isEmpty { out += prefix }
                out += self.block(block)
                if last && !trailer.isEmpty { out += trailer }
            }
        }
        return out
    }

    mutating func block(_ block: MDBlock) -> String {
        switch block {
        case .paragraph(let text):
            return "<p>\(MDInline.render(text, ctx))</p>\n"
        case .heading(let level, let text):
            let inner = MDInline.render(text, ctx)
            let id = uniqueID(HTML.slug(MDInline.plainText(inner)))
            return "<h\(level) id=\"\(HTML.escape(id))\">\(inner)</h\(level)>\n"
        case .code(let info, let text):
            let langName = info.split(separator: " ").first.map(String.init) ?? ""
            let language = langName.isEmpty ? nil : Language.named(langName)
            let cls = langName.isEmpty ? "" : " class=\"language-\(HTML.escape(langName))\""
            let code: String
            if options.highlightCode, let language {
                code = CodeRenderer.inline(CodeRenderer.tokens(for: text, language: language))
            } else {
                code = HTML.escape(text)
            }
            return "<pre><code\(cls)>\(code)</code></pre>\n"
        case .html(let raw):
            return options.allowHTML ? raw + "\n" : "<p>\(HTML.escape(raw))</p>\n"
        case .quote(let inner):
            return "<blockquote>\n\(blocks(inner, tight: false))</blockquote>\n"
        case .list(let ordered, let start, let tight, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
            var out = "<\(tag)\(startAttr)>\n"
            for item in items {
                if let checked = item.task {
                    let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    out += "<li class=\"task\">\(blocks(item.blocks, tight: tight, prefix: box))</li>\n"
                } else {
                    out += "<li>\(blocks(item.blocks, tight: tight))</li>\n"
                }
            }
            return out + "</\(tag)>\n"
        case .table(let align, let header, let rows):
            func style(_ i: Int) -> String {
                switch i < align.count ? align[i] : .none {
                case .none: ""
                case .left: " style=\"text-align:left\""
                case .center: " style=\"text-align:center\""
                case .right: " style=\"text-align:right\""
                }
            }
            var out = "<table>\n<thead>\n<tr>"
            for (i, cell) in header.enumerated() { out += "<th\(style(i))>\(MDInline.render(cell, ctx))</th>" }
            out += "</tr>\n</thead>\n"
            if !rows.isEmpty {
                out += "<tbody>\n"
                for row in rows {
                    out += "<tr>"
                    for (i, cell) in row.enumerated() { out += "<td\(style(i))>\(MDInline.render(cell, ctx))</td>" }
                    out += "</tr>\n"
                }
                out += "</tbody>\n"
            }
            return out + "</table>\n"
        case .rule:
            return "<hr>\n"
        }
    }

    private mutating func uniqueID(_ base: String) -> String {
        let key = base.isEmpty ? "section" : base
        let n = usedIDs[key, default: 0]
        usedIDs[key] = n + 1
        return n == 0 ? key : "\(key)-\(n)"
    }
}
