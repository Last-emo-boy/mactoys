import Foundation

extension TextFormat {
    /// Small words title case leaves lowercase unless they start the name (as PowerToys).
    static let titleCaseExceptions: Set<String> = [
        "a", "an", "to", "the", "at", "by", "for", "in", "of", "on", "up", "and", "as", "but", "or", "nor",
    ]

    /// Applies the format to one part of a name (a stem or an extension).
    public func apply(_ text: String) -> String {
        switch self {
        case .none: return text
        case .lowercase: return text.lowercased()
        case .uppercase: return text.uppercased()
        case .titleCase: return Self.words(text) { word, isFirst in
            let lower = word.lowercased()
            return !isFirst && Self.titleCaseExceptions.contains(lower) ? lower : Self.capitalizeFirst(lower)
        }
        case .capitalized: return Self.words(text) { word, _ in Self.capitalizeFirst(word.lowercased()) }
        }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c == "_" || c == "-"
    }

    /// Rewrites each run of non-separator characters, keeping the separators.
    private static func words(_ text: String, _ transform: (String, Bool) -> String) -> String {
        var out = ""
        var word = ""
        var isFirst = true
        func flush() {
            guard !word.isEmpty else { return }
            out += transform(word, isFirst)
            isFirst = false
            word = ""
        }
        for c in text {
            if isSeparator(c) { flush(); out.append(c) } else { word.append(c) }
        }
        flush()
        return out
    }
}
