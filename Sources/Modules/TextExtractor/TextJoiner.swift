import Foundation

/// Joins the wrapped lines of plain text into paragraphs, for text that has no layout to go by
/// (a PDF text layer, an older capture, text that was already copied with its line breaks).
///
/// Lines of a paragraph are joined with a space (none between CJK characters) and words split
/// across a line with a hyphen are rejoined. Blank lines separate paragraphs and are kept, and
/// list items (`•`, `-`, `1.`, `a)`) keep starting on a line of their own.
public enum TextJoiner {
    public static func joinLines(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var out = ""
        var current = ""
        var pendingBreak = "\n"
        func flush() {
            guard !current.isEmpty else { return }
            out += (out.isEmpty ? "" : pendingBreak) + current
            current = ""
            pendingBreak = "\n"
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                if !out.isEmpty { pendingBreak = "\n\n" }
                continue
            }
            if isListItem(line) { flush() }
            current = current.isEmpty ? line : TextLayout.join(current, line, rejoinHyphen: true)
        }
        flush()
        return out
    }

    /// Whether a line starts a list item: a bullet or dash, `12.` / `12)`, or `a)`.
    public static func isListItem(_ line: String) -> Bool {
        let chars = Array(line)
        guard chars.count >= 2 else { return false }
        if "•◦▪‣●○■□–—-*·".contains(chars[0]) { return chars[1] == " " }
        var i = 0
        while i < chars.count, i < 3, chars[i].isASCII, chars[i].isNumber { i += 1 }
        if i > 0 {
            return i + 1 < chars.count && (chars[i] == "." || chars[i] == ")") && chars[i + 1] == " "
        }
        return chars.count >= 3 && chars[0].isLetter && chars[1] == ")" && chars[2] == " "
    }
}
