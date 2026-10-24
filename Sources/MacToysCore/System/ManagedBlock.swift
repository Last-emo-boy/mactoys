import Foundation

/// A region MacToys owns inside a user's text file (shell startup files such as `~/.zshenv`):
///
///     # >>> MacToys Environment Variables >>>
///     …
///     # <<< MacToys Environment Variables <<<
///
/// Inserting replaces the first block in place (dropping duplicates) or appends one; removing
/// undoes exactly what appending added. Everything outside the markers is kept byte for byte.
public struct ManagedBlock: Sendable {
    public let begin: String
    public let end: String
    /// For a begin marker without an end: which following lines are ours and go with it.
    private let isOwnLine: @Sendable (String) -> Bool

    public init(name: String, isOwnLine: @escaping @Sendable (String) -> Bool = { _ in false }) {
        begin = "# >>> MacToys \(name) >>>"
        end = "# <<< MacToys \(name) <<<"
        self.isOwnLine = isOwnLine
    }

    public func contains(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == begin }
    }

    /// The first block's body lines, or nil when there is no block.
    public func body(in text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let b = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }) else { return nil }
        let e = lines[(b + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == end } ?? lines.count
        return Array(lines[(b + 1)..<e])
    }

    /// The text with one block holding `body`.
    public func insert(_ body: [String], into text: String) -> String {
        let blockLines = [begin] + body + [end]
        var (lines, position) = stripped(text)
        if let position {
            lines.insert(contentsOf: blockLines, at: position)
            return lines.joined(separator: "\n")
        }
        // Append, keeping one blank line between the user's content and the block.
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        return out + blockLines.joined(separator: "\n") + "\n"
    }

    /// The text without any block.
    public func remove(from text: String) -> String {
        let (lines, position) = stripped(text)
        guard let position else { return text }
        var out = lines
        // A block appended after a blank separator at the end of the file takes the separator with it.
        if position == out.count - 1, out.last == "", position > 0, out[position - 1] == "" {
            out.remove(at: position - 1)
        }
        return out.joined(separator: "\n")
    }

    /// Lines without any block, and where the first block started.
    private func stripped(_ text: String) -> ([String], Int?) {
        var lines = text.components(separatedBy: "\n")
        var first: Int?
        var i = 0
        while i < lines.count {
            guard lines[i].trimmingCharacters(in: .whitespaces) == begin else { i += 1; continue }
            if first == nil { first = i }
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != end { j += 1 }
            if j < lines.count {
                lines.removeSubrange(i...j)
            } else {
                lines.remove(at: i)
                while i < lines.count, isOwnLine(lines[i]) { lines.remove(at: i) }
            }
        }
        return (lines, first)
    }
}
