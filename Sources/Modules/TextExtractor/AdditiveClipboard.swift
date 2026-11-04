import Foundation

/// How added captures are separated on the additive clipboard.
public enum CaptureSeparator: String, Codable, CaseIterable, Sendable {
    case newline, blankLine, space

    public var text: String {
        switch self {
        case .newline: "\n"
        case .blankLine: "\n\n"
        case .space: " "
        }
    }

    public var title: String {
        switch self {
        case .newline: String(localized: "New line", comment: "Separator between captures added to the clipboard")
        case .blankLine: String(localized: "Blank line", comment: "Separator between captures added to the clipboard")
        case .space: String(localized: "Space", comment: "Separator between captures added to the clipboard: a space character")
        }
    }
}

/// Collects captures so each one is appended to the text Text Extractor last put on the
/// clipboard instead of replacing it. Copying anything else in between (the pasteboard's change
/// count moved on) starts a new collection, so an unrelated copy is never overwritten by old captures.
public struct AdditiveClipboard: Equatable, Sendable {
    public private(set) var pieces: [String] = []
    /// The pasteboard change count right after our last write.
    public private(set) var writtenChangeCount: Int?

    public init() {}

    /// Adds a capture; returns the text to put on the clipboard.
    public mutating func add(_ text: String, changeCount: Int, separator: CaptureSeparator) -> String {
        if writtenChangeCount != changeCount { pieces = [] }
        pieces.append(text)
        return combined(separator)
    }

    /// Replaces the newest capture (after re-laying it out); returns the text to put on the clipboard.
    public mutating func replaceLast(_ text: String, separator: CaptureSeparator) -> String {
        if pieces.isEmpty { pieces = [text] } else { pieces[pieces.count - 1] = text }
        return combined(separator)
    }

    /// Call after writing the combined text to the pasteboard.
    public mutating func didWrite(changeCount: Int) { writtenChangeCount = changeCount }

    /// Whether the clipboard still holds the collection (nothing else was copied since).
    public func isCurrent(changeCount: Int) -> Bool { !pieces.isEmpty && writtenChangeCount == changeCount }

    public mutating func reset() {
        pieces = []
        writtenChangeCount = nil
    }

    public func combined(_ separator: CaptureSeparator) -> String { pieces.joined(separator: separator.text) }
}
