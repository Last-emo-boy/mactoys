import Foundation

/// Splits `= 2+2`, `>ls`, `cb foo` into a keyword target and the rest of the query.
///
/// Direct keywords apply as a plain prefix; the others need a following space or must be the
/// whole query, so typing "cbr" doesn't trigger "cb". By default symbolic keywords (`=`, `>`,
/// `//`, `%%`) are direct and keywords containing letters or digits (`cb`, `brew`) are not.
/// The longest matching keyword wins (`??` over `?`).
enum KeywordParser {
    struct Entry {
        let target: String
        let keyword: String
        let direct: Bool

        init(target: String, keyword: String, direct: Bool? = nil) {
            self.target = target
            self.keyword = keyword
            self.direct = direct ?? KeywordParser.isSymbolic(keyword)
        }
    }

    struct Match: Equatable {
        let target: String
        let keyword: String
        let rest: String
    }

    static func isSymbolic(_ keyword: String) -> Bool {
        !keyword.contains { $0.isLetter || $0.isNumber }
    }

    /// Empty keywords never match.
    static func match(_ raw: String, _ entries: [Entry]) -> Match? {
        let candidates = entries.filter { !$0.keyword.isEmpty }.sorted { $0.keyword.count > $1.keyword.count }
        let lowerRaw = raw.lowercased()
        for e in candidates {
            let lowerKey = e.keyword.lowercased()
            if e.direct {
                guard lowerRaw.hasPrefix(lowerKey) else { continue }
                return Match(target: e.target, keyword: e.keyword,
                             rest: String(raw.dropFirst(e.keyword.count)).trimmingCharacters(in: .whitespaces))
            }
            if lowerRaw == lowerKey {
                return Match(target: e.target, keyword: e.keyword, rest: "")
            }
            if lowerRaw.hasPrefix(lowerKey + " ") {
                return Match(target: e.target, keyword: e.keyword,
                             rest: String(raw.dropFirst(e.keyword.count + 1)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
