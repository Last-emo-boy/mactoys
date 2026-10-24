import Foundation

/// Display options for source listings.
public struct CodeOptions: Sendable, Equatable {
    public var theme: PreviewTheme
    public var lineNumbers: Bool
    public var wrap: Bool
    public var fontSize: Double

    public init(theme: PreviewTheme = .auto, lineNumbers: Bool = true, wrap: Bool = false, fontSize: Double = 12) {
        self.theme = theme
        self.lineNumbers = lineNumbers
        self.wrap = wrap
        self.fontSize = fontSize
    }
}

/// Turns tokens into HTML: one `<div class="l">` per line so line numbers and wrapping work
/// with plain CSS, and copying the text gives back the original lines.
public enum CodeRenderer {
    /// Files larger than this are shown without colors (tokenizing stays fast, the page stays light).
    public static let highlightLimit = 4 * 1024 * 1024

    /// The listing block (`<div class="code …">…</div>`).
    public static func listing(_ tokens: [Token], lineNumbers: Bool, wrap: Bool) -> String {
        var out = "<div class=\"code\(lineNumbers ? " ln" : "")\(wrap ? " wrap" : "")\">"
        out.reserveCapacity(tokens.reduce(0) { $0 + $1.text.utf8.count } * 2 + 64)
        var line = 1
        var lineOpen = false
        func openLine() {
            out += "<div class=\"l\" data-n=\"\(line)\"><span class=\"c\">"
            lineOpen = true
        }
        func closeLine() {
            out += "</span></div>"
            lineOpen = false
            line += 1
        }
        for token in tokens {
            let pieces = token.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    if !lineOpen { openLine() }
                    closeLine()
                }
                guard !piece.isEmpty else { continue }
                if !lineOpen { openLine() }
                out += span(token.kind, piece)
            }
        }
        if lineOpen { closeLine() }
        if line == 1 { openLine(); closeLine() }
        out += "</div>"
        return out
    }

    /// Spans only, newlines kept (for `<pre><code>` blocks in Markdown).
    public static func inline(_ tokens: [Token]) -> String {
        tokens.map { span($0.kind, $0.text) }.joined()
    }

    private static func span(_ kind: TokenKind, _ text: some StringProtocol) -> String {
        guard let cls = kind.cssClass else { return HTML.escape(text) }
        return "<span class=\"\(cls)\">\(HTML.escape(text))</span>"
    }

    /// Highlights `text` (or leaves it plain past `highlightLimit`).
    public static func tokens(for text: String, language: Language?) -> [Token] {
        guard let language, text.utf8.count <= highlightLimit else { return [Token(.plain, text)] }
        return SyntaxHighlighter.tokenize(text, language: language)
    }

    /// A complete page for a source file. `notice` adds a one-line banner (e.g. "Formatted").
    public static func page(text: String, language: Language?, title: String, options: CodeOptions,
                            notice: String? = nil) -> String {
        var body = ""
        if let notice { body += "<div class=\"notice\">\(HTML.escape(notice))</div>" }
        body += listing(tokens(for: text, language: language), lineNumbers: options.lineNumbers, wrap: options.wrap)
        return HTML.document(title: title, body: body, theme: options.theme, extraCSS: Styles.code,
                             fontSize: options.fontSize)
    }
}
