import Foundation

/// A menu bar item as the search list shows it.
struct SearchEntry: Identifiable, Equatable, Sendable {
    /// `MenuBarLayout.itemKey`.
    var id: String
    /// The item's own name (its accessibility title or description), or the app's name.
    var title: String
    var appName: String
    var section: MenuBarSection
}

/// Ranks menu bar items for a query: whole-title and prefix matches first, then word starts
/// (including camelCase words: "AirDrop" for "drop"), then substrings, initials and finally loose
/// in-order letters. The app's name counts a little less than the item's own name. Every word of
/// the query must match somewhere.
enum MenuBarSearch {
    /// One item per app, its rightmost (usually its main) one, in menu bar order: what search can
    /// tell apart when items have no names of their own.
    static func onePerApp(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var seen: Set<String> = []
        return items.reversed().filter { seen.insert($0.bundleID).inserted }.reversed()
    }

    static func rank(_ entries: [SearchEntry], query: String) -> [SearchEntry] {
        let tokens = normalize(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return entries.sorted { a, b in
                if a.appName.localizedCaseInsensitiveCompare(b.appName) != .orderedSame {
                    return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
                }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        let scored: [(SearchEntry, Int)] = entries.compactMap { e in
            score(tokens: tokens, title: e.title, appName: e.appName).map { (e, $0) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
            return a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
        }.map(\.0)
    }

    /// Combined score of every query word; nil when one of them matches nothing.
    static func score(tokens: [String], title: String, appName: String) -> Int? {
        let t = normalize(title), a = normalize(appName)
        let tWords = words(title), aWords = words(appName)
        let tInitials = initials(title), aInitials = initials(appName)
        var total = 0
        for token in tokens {
            let best = max(match(token, in: t, words: tWords, initials: tInitials) ?? -1,
                           (match(token, in: a, words: aWords, initials: aInitials) ?? -1) - 60)
            guard best >= 0 else { return nil }
            total += best
        }
        return total
    }

    /// Score of one query word against one normalized string.
    static func match(_ q: String, in s: String, words: [String], initials: String) -> Int? {
        guard !q.isEmpty, !s.isEmpty else { return nil }
        let compact = s.replacingOccurrences(of: " ", with: "")
        if s == q || compact == q { return 1000 }
        if s.hasPrefix(q) || compact.hasPrefix(q) { return 800 }
        if words.contains(where: { $0.hasPrefix(q) }) { return 650 }
        if s.contains(q) || compact.contains(q) { return 450 }
        if q.count >= 2, initials.hasPrefix(q) { return 350 }
        return subsequence(q, in: compact)
    }

    /// Loose match: the query's letters appear in order. Tighter matches score higher.
    static func subsequence(_ q: String, in s: String) -> Int? {
        let chars = Array(s)
        var i = 0
        var gaps = 0
        var last = -1
        for c in q {
            var found = false
            while i < chars.count {
                if chars[i] == c {
                    if last >= 0 { gaps += i - last - 1 }
                    last = i
                    i += 1
                    found = true
                    break
                }
                i += 1
            }
            guard found else { return nil }
        }
        return max(1, 200 - gaps * 10)
    }

    /// Lowercased, accent- and width-folded; punctuation and dashes become spaces.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Normalized words, also split at camelCase boundaries ("AirDrop" → air, drop, airdrop).
    static func words(_ s: String) -> [String] {
        var result = parts(s)
        for raw in s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let whole = normalize(String(raw))
            if !whole.isEmpty && !result.contains(whole) { result.append(whole) }
        }
        return result
    }

    /// First letters of the words ("Tailscale VPN" → "tv", "AirDrop" → "ad").
    static func initials(_ s: String) -> String {
        String(parts(s).compactMap(\.first))
    }

    /// Words split at spaces, punctuation and camelCase boundaries, normalized.
    static func parts(_ s: String) -> [String] {
        var result: [String] = []
        for raw in s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var current = ""
            var previousLower = false
            for ch in raw {
                if ch.isUppercase && previousLower && !current.isEmpty {
                    result.append(normalize(current))
                    current = ""
                }
                current.append(ch)
                previousLower = ch.isLowercase
            }
            if !current.isEmpty { result.append(normalize(current)) }
        }
        return result.filter { !$0.isEmpty }
    }
}
