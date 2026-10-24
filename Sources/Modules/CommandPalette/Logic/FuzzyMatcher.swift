import Foundation

/// Scores how well a query matches a candidate string, the way launchers rank results:
/// exact > prefix > word start > acronym > substring > subsequence.
///
/// Matching is case- and diacritic-insensitive. Multi-word queries match when every word
/// matches somewhere in the candidate ("code vis" finds "Visual Studio Code").
/// Scores are roughly 0…1000; `nil` means no match.
enum FuzzyMatcher {
    static let exact = 1000.0
    static let prefix = 900.0
    static let wordStart = 800.0
    static let acronym = 750.0
    static let substring = 600.0
    static let subsequence = 300.0

    /// Lowercased, diacritic-free form used for comparisons.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The score of `query` against `candidate`, or nil when it doesn't match.
    static func score(_ query: String, _ candidate: String) -> Double? {
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let c = Candidate(candidate)
        let words = q.split(separator: " ").map(String.init)
        if words.count > 1 {
            // The whole query as one phrase scores best; otherwise every word must match.
            if let whole = c.score(Array(q)) { return whole }
            var total = 0.0
            for w in words {
                guard let s = c.score(Array(w)) else { return nil }
                total += s
            }
            return total / Double(words.count) * 0.9
        }
        return c.score(Array(q))
    }

    /// The best score of `query` against a title and extra keywords (keywords weigh a bit less).
    static func best(_ query: String, title: String, keywords: [String] = []) -> Double? {
        var best = score(query, title)
        for k in keywords {
            guard let s = score(query, k).map({ $0 * 0.92 }) else { continue }
            if s > (best ?? -.infinity) { best = s }
        }
        return best
    }

    /// Pre-split candidate: characters plus word-start positions.
    private struct Candidate {
        let chars: [Character]
        /// Indices where a word starts: after a separator, at a lower→upper case change, at a digit run.
        let starts: [Int]

        init(_ raw: String) {
            let original = Array(raw)
            chars = Array(FuzzyMatcher.normalize(raw))
            var s: [Int] = []
            // Folding can change length (ß → ss); only use case boundaries when lengths agree.
            let aligned = original.count == chars.count
            for i in chars.indices {
                if i == 0 { s.append(0); continue }
                let prev = chars[i - 1]
                let cur = chars[i]
                let separator = !(prev.isLetter || prev.isNumber)
                let camel = aligned && original[i].isUppercase && original[i - 1].isLowercase
                let digitStart = cur.isNumber && !prev.isNumber
                if (separator && (cur.isLetter || cur.isNumber)) || camel || digitStart { s.append(i) }
            }
            starts = s
        }

        func score(_ q: [Character]) -> Double? {
            guard !q.isEmpty, !chars.isEmpty else { return nil }
            let lengthPenalty = Double(max(0, chars.count - q.count)) * 0.5
            if chars == q { return FuzzyMatcher.exact }
            if chars.starts(with: q) { return FuzzyMatcher.prefix - min(lengthPenalty, 60) }
            for (n, start) in starts.enumerated() where n > 0 && chars[start...].starts(with: q) {
                return FuzzyMatcher.wordStart - Double(n) * 8 - min(lengthPenalty, 40)
            }
            if q.count >= 2, matchesAcronym(q) { return FuzzyMatcher.acronym - min(lengthPenalty, 40) }
            if let r = firstRange(of: q) {
                return FuzzyMatcher.substring - Double(r) * 4 - min(lengthPenalty, 40)
            }
            return subsequenceScore(q)
        }

        /// Every query character is the first letter of consecutive-or-later words, in order:
        /// "vsc" → Visual Studio Code, "pt" → PowerToys.
        private func matchesAcronym(_ q: [Character]) -> Bool {
            var qi = 0
            for start in starts where qi < q.count {
                if chars[start] == q[qi] { qi += 1 }
            }
            return qi == q.count
        }

        private func firstRange(of q: [Character]) -> Int? {
            guard q.count <= chars.count else { return nil }
            for i in 0...(chars.count - q.count) where chars[i] == q[0] && Array(chars[i..<(i + q.count)]) == q {
                return i
            }
            return nil
        }

        /// Greedy left-to-right subsequence match rewarding consecutive runs and word starts.
        private func subsequenceScore(_ q: [Character]) -> Double? {
            let startSet = Set(starts)
            var qi = 0
            var last = -1
            var bonus = 0.0
            var gaps = 0
            for i in chars.indices where qi < q.count {
                guard chars[i] == q[qi] else { continue }
                if last >= 0 {
                    if i == last + 1 { bonus += 12 } else { gaps += i - last - 1 }
                }
                if startSet.contains(i) { bonus += 18 }
                last = i
                qi += 1
            }
            guard qi == q.count else { return nil }
            let value = FuzzyMatcher.subsequence + bonus - Double(gaps) * 3 - Double(chars.count - q.count) * 0.5
            return max(value, 20)
        }
    }
}
