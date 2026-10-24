import Foundation

/// Splits source text into colored tokens. Works on UTF-8 bytes and only ever splits at ASCII
/// characters, so multi-byte characters stay intact; concatenating the token texts gives back
/// the input exactly.
public enum SyntaxHighlighter {
    public static func tokenize(_ text: String, language: Language) -> [Token] {
        var s = Scanner(bytes: Array(text.utf8), language: language)
        switch language.mode {
        case .generic, .makefile: s.scanGeneric()
        case .markup: s.scanMarkup()
        case .css: s.scanCSS()
        case .json: s.scanJSON()
        case .yaml: s.scanYAML()
        case .ini: s.scanINI()
        case .diff: s.scanDiff()
        case .markdown: s.scanMarkdown()
        case .plain: s.emit(.plain, s.bytes.count)
        }
        s.flush()
        return s.tokens
    }
}

/// Byte classes used by the scanners.
enum Byte {
    static func isLetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    static func isHexDigit(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66) }
    static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0C }
    static func isWord(_ b: UInt8) -> Bool { isLetter(b) || isDigit(b) || b == 0x5F || b >= 0x80 }
}

struct Scanner {
    let bytes: [UInt8]
    let lang: Language
    var i = 0
    var tokens: [Token] = []
    private var pendingPlain: Int?
    let keywords: Set<String>
    let types: Set<String>
    let literals: Set<String>
    let builtins: Set<String>
    /// Last non-blank thing seen, for regex-vs-division decisions.
    var lastByte: UInt8 = 0
    var lastWord: String?
    var atLineStart = true

    init(bytes: [UInt8], language: Language) {
        self.bytes = bytes
        self.lang = language
        func fold(_ s: Set<String>) -> Set<String> { language.caseInsensitive ? Set(s.map { $0.lowercased() }) : s }
        keywords = fold(language.keywords)
        types = fold(language.types)
        literals = fold(language.literals)
        builtins = fold(language.builtins)
    }

    var n: Int { bytes.count }

    func peek(_ offset: Int = 0) -> UInt8 {
        let j = i + offset
        return j >= 0 && j < bytes.count ? bytes[j] : 0
    }

    func matches(_ s: String, at j: Int) -> Bool {
        var k = j
        for b in s.utf8 {
            guard k < bytes.count, bytes[k] == b else { return false }
            k += 1
        }
        return true
    }

    func text(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }

    func isIdentStart(_ b: UInt8) -> Bool {
        Byte.isLetter(b) || b == 0x5F || b >= 0x80 || (lang.identifierExtras.contains(b) && (b == UInt8(ascii: "$") || b == UInt8(ascii: "@")))
    }

    func isIdentPart(_ b: UInt8) -> Bool { Byte.isWord(b) || lang.identifierExtras.contains(b) }

    // MARK: Emitting

    /// Emits bytes `i..<end` as `kind` and advances.
    mutating func emit(_ kind: TokenKind, _ end: Int) {
        let end = min(end, n)
        guard end > i else { return }
        if kind == .plain {
            if pendingPlain == nil { pendingPlain = i }
        } else {
            flush()
            tokens.append(Token(kind, text(i, end)))
        }
        i = end
    }

    mutating func flush() {
        if let start = pendingPlain, start < i {
            tokens.append(Token(.plain, text(start, i)))
        }
        pendingPlain = nil
    }

    /// Appends tokens produced by another scanner (embedded languages) at the current position.
    mutating func append(_ more: [Token], advancingTo end: Int) {
        flush()
        tokens.append(contentsOf: more)
        i = end
    }

    // MARK: Shared pieces

    func lineEnd(from j: Int) -> Int {
        var k = j
        while k < n && bytes[k] != 0x0A { k += 1 }
        return k
    }

    /// End of a string literal whose opening delimiter ends at `j`, or nil when it isn't one.
    func stringEnd(_ rule: StringRule, contentStart j: Int) -> Int? {
        var k = j
        let close = Array(rule.close.utf8)
        if rule.isCharLiteral, j < n, bytes[j] != 0x5C {
            // One character (1–4 UTF-8 bytes) then the closing quote; otherwise it's a lifetime or a quote.
            guard bytes[j] != close[0], bytes[j] != 0x0A else { return nil }
            var len = 1
            let lead = bytes[j]
            if lead >= 0xF0 { len = 4 } else if lead >= 0xE0 { len = 3 } else if lead >= 0xC0 { len = 2 }
            return matches(rule.close, at: j + len) ? j + len + close.count : nil
        }
        let limit = rule.isCharLiteral ? min(n, j + 12) : n
        while k < limit {
            let b = bytes[k]
            if rule.escapes && b == 0x5C { k += 2; continue }
            if b == close[0] && matches(rule.close, at: k) { return k + close.count }
            if b == 0x0A && !rule.multiline { return rule.isCharLiteral ? nil : k }
            k += 1
        }
        return rule.isCharLiteral ? nil : n
    }

    /// Tries every string rule (with its prefixes) at the current position.
    func matchString() -> Int? {
        for rule in lang.strings {
            for prefix in [""] + rule.prefixes {
                let open = prefix + rule.open
                guard matches(open, at: i) else { continue }
                if !prefix.isEmpty, i > 0, isIdentPart(bytes[i - 1]) { continue }
                if prefix.isEmpty, rule.open.utf8.first.map(Byte.isLetter) == true, i > 0, isIdentPart(bytes[i - 1]) { continue }
                if let end = stringEnd(rule, contentStart: i + open.utf8.count) { return end }
            }
        }
        return nil
    }

    func numberEnd(at j: Int) -> Int? {
        guard j < n else { return nil }
        var k = j
        let b = bytes[k]
        if b == 0x2E { guard k + 1 < n, Byte.isDigit(bytes[k + 1]) else { return nil } }
        else if !Byte.isDigit(b) { return nil }
        if b == 0x30, k + 1 < n, [UInt8(ascii: "x"), UInt8(ascii: "X")].contains(bytes[k + 1]) {
            k += 2
            while k < n && (Byte.isHexDigit(bytes[k]) || bytes[k] == 0x5F) { k += 1 }
        } else if b == 0x30, k + 1 < n, [UInt8(ascii: "b"), UInt8(ascii: "B"), UInt8(ascii: "o"), UInt8(ascii: "O")].contains(bytes[k + 1]),
                  k + 2 < n, Byte.isDigit(bytes[k + 2]) {
            k += 2
            while k < n && (Byte.isDigit(bytes[k]) || bytes[k] == 0x5F) { k += 1 }
        } else {
            while k < n && (Byte.isDigit(bytes[k]) || bytes[k] == 0x5F) { k += 1 }
            if k + 1 < n, bytes[k] == 0x2E, Byte.isDigit(bytes[k + 1]) {
                k += 1
                while k < n && (Byte.isDigit(bytes[k]) || bytes[k] == 0x5F) { k += 1 }
            } else if b == 0x2E {
                k += 1
                while k < n && (Byte.isDigit(bytes[k]) || bytes[k] == 0x5F) { k += 1 }
            }
            if k < n, bytes[k] == 0x65 || bytes[k] == 0x45 {
                var e = k + 1
                if e < n, bytes[e] == 0x2B || bytes[e] == 0x2D { e += 1 }
                if e < n, Byte.isDigit(bytes[e]) {
                    k = e
                    while k < n && Byte.isDigit(bytes[k]) { k += 1 }
                }
            }
        }
        // Type suffixes: 10u, 1.5f, 42i32, 7n, 3L
        while k < n && (Byte.isLetter(bytes[k]) || Byte.isDigit(bytes[k])) { k += 1 }
        return k
    }

    func identEnd(at j: Int) -> Int {
        var k = j + 1
        while k < n && isIdentPart(bytes[k]) { k += 1 }
        // A trailing '-' is never part of an identifier (shell flags like `ls -`).
        while k > j + 1 && bytes[k - 1] == UInt8(ascii: "-") { k -= 1 }
        return k
    }

    /// Classifies an identifier.
    func classify(_ word: String, end: Int) -> TokenKind {
        let key = lang.caseInsensitive ? word.lowercased() : word
        if keywords.contains(key) { return .keyword }
        if literals.contains(key) { return .literal }
        if types.contains(key) { return .type }
        if let last = lastWord, ["func", "def", "fn", "function", "fun", "sub", "proc"].contains(last), keywords.contains(last) {
            return .function
        }
        if builtins.contains(key) { return .builtin }
        if lang.functionCalls, end < n, bytes[end] == UInt8(ascii: "(") { return .function }
        if lang.capitalizedTypes, let first = word.utf8.first, Byte.isUpper(first) {
            let allCaps = word.utf8.allSatisfy { Byte.isUpper($0) || Byte.isDigit($0) || $0 == 0x5F }
            return allCaps && word.utf8.count > 1 ? .literal : .type
        }
        return .plain
    }

    /// Whether a `/` here starts a regex literal rather than division.
    func regexAllowed() -> Bool {
        if let w = lastWord { return ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await", "and", "or", "not", "if", "unless", "when", "split", "grep"].contains(w) }
        if lastByte == 0 { return true }
        return Array("(,=:[!&|?{};+-*%<>~^".utf8).contains(lastByte)
    }

    func regexEnd(at j: Int) -> Int? {
        var k = j + 1
        var inClass = false
        guard k < n, bytes[k] != UInt8(ascii: "/"), bytes[k] != UInt8(ascii: "*"), bytes[k] != 0x20 else { return nil }
        while k < n {
            let b = bytes[k]
            if b == 0x0A { return nil }
            if b == 0x5C { k += 2; continue }
            if b == UInt8(ascii: "[") { inClass = true }
            else if b == UInt8(ascii: "]") { inClass = false }
            else if b == UInt8(ascii: "/") && !inClass {
                k += 1
                while k < n && Byte.isLetter(bytes[k]) { k += 1 }
                return k
            }
            k += 1
        }
        return nil
    }

    /// `$name`, `${…}`, `$(…)` (Makefile), `$1`, `@ivar`, `@@cvar`.
    func variableEnd(at j: Int) -> Int? {
        guard j + 1 < n else { return nil }
        let sigil = bytes[j]
        var k = j + 1
        if sigil == UInt8(ascii: "@") && bytes[k] == UInt8(ascii: "@") { k += 1 }
        guard k < n else { return nil }
        let c = bytes[k]
        if c == UInt8(ascii: "{") || (c == UInt8(ascii: "(") && lang.mode == .makefile) {
            let close = c == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: ")")
            var depth = 0
            while k < n && bytes[k] != 0x0A {
                if bytes[k] == c { depth += 1 } else if bytes[k] == close { depth -= 1; if depth == 0 { return k + 1 } }
                k += 1
            }
            return nil
        }
        if Byte.isLetter(c) || c == 0x5F || c >= 0x80 {
            k += 1
            while k < n && Byte.isWord(bytes[k]) { k += 1 }
            return k
        }
        if sigil == UInt8(ascii: "$") && (Byte.isDigit(c) || Array("@*#?$!-_<^".utf8).contains(c)) { return k + 1 }
        return nil
    }

    mutating func noteSignificant(_ kind: TokenKind, word: String?, last: UInt8) {
        lastByte = last
        lastWord = kind == .keyword ? word : nil
        atLineStart = false
    }

    // MARK: Generic scanner

    mutating func scanGeneric() {
        while i < n {
            let b = bytes[i]
            if b == 0x0A { emit(.plain, i + 1); atLineStart = true; continue }
            if Byte.isSpace(b) { emit(.plain, i + 1); continue }
            if scanGenericToken() { continue }
            noteSignificant(.plain, word: nil, last: b)
            emit(.plain, i + 1)
        }
    }

    /// One token of the generic grammar at `i`; false when nothing special starts here.
    mutating func scanGenericToken() -> Bool {
        let b = bytes[i]
        let start = i
        if lang.mode == .makefile && atLineStart && scanMakefileLineStart() { return true }
        for bc in lang.blockComments where matches(bc.open, at: i) {
            if Byte.isLetter(bc.open.utf8.dropFirst().first ?? 0), b == UInt8(ascii: "="), !atLineStart { continue }
            emit(.comment, blockCommentEnd(open: bc.open, close: bc.close))
            atLineStart = false
            return true
        }
        for lc in lang.lineComments where matches(lc, at: i) {
            if lang.commentNeedsWordBoundary, i > 0, !Byte.isSpace(bytes[i - 1]), bytes[i - 1] != 0x0A, bytes[i - 1] != UInt8(ascii: ";") { continue }
            emit(.comment, lineEnd(from: i))
            return true
        }
        if lang.preprocessor && atLineStart && b == UInt8(ascii: "#") {
            var k = i
            while k < n {
                k = lineEnd(from: k)
                if k > 0, k < n, bytes[k - 1] == 0x5C { k += 1; continue }
                break
            }
            emit(.meta, k)
            atLineStart = false
            return true
        }
        if lang.hashBracketAttributes && b == UInt8(ascii: "#") && (peek(1) == UInt8(ascii: "[") || (peek(1) == UInt8(ascii: "!") && peek(2) == UInt8(ascii: "["))) {
            var k = i, depth = 0
            while k < n {
                if bytes[k] == UInt8(ascii: "[") { depth += 1 }
                else if bytes[k] == UInt8(ascii: "]") { depth -= 1; if depth == 0 { k += 1; break } }
                k += 1
            }
            emit(.attribute, k)
            noteSignificant(.attribute, word: nil, last: UInt8(ascii: "]"))
            return true
        }
        if let end = matchString() {
            emit(.string, end)
            noteSignificant(.string, word: nil, last: 0x22)
            return true
        }
        if lang.variableSigils.contains(b), let end = variableEnd(at: i) {
            emit(.variable, end)
            noteSignificant(.variable, word: nil, last: 0x61)
            return true
        }
        if lang.atAttributes && b == UInt8(ascii: "@") && isIdentStart(peek(1)) {
            var k = i + 2
            while k < n && (Byte.isWord(bytes[k]) || bytes[k] == UInt8(ascii: ".")) { k += 1 }
            emit(.attribute, k)
            noteSignificant(.attribute, word: nil, last: 0x61)
            return true
        }
        if (start == 0 || !isIdentPart(bytes[start - 1])), let end = numberEnd(at: i) {
            emit(.number, end)
            noteSignificant(.number, word: nil, last: 0x30)
            return true
        }
        if lang.regexLiterals && b == UInt8(ascii: "/") && regexAllowed(), let end = regexEnd(at: i) {
            emit(.regex, end)
            noteSignificant(.regex, word: nil, last: 0x61)
            return true
        }
        if lang.symbols && b == UInt8(ascii: ":") && isIdentStart(peek(1)) && (i == 0 || (!isIdentPart(bytes[i - 1]) && bytes[i - 1] != UInt8(ascii: ":"))) {
            emit(.literal, identEnd(at: i + 1))
            noteSignificant(.literal, word: nil, last: 0x61)
            return true
        }
        if isIdentStart(b) {
            let end = identEnd(at: i)
            let word = text(i, end)
            let kind = classify(word, end: end)
            emit(kind, end)
            noteSignificant(kind, word: word, last: 0x61)
            return true
        }
        return false
    }

    func blockCommentEnd(open: String, close: String) -> Int {
        var k = i + open.utf8.count
        var depth = 1
        while k < n {
            if lang.nestedComments && matches(open, at: k) { depth += 1; k += open.utf8.count; continue }
            if matches(close, at: k) {
                depth -= 1
                k += close.utf8.count
                if depth == 0 { return k }
                continue
            }
            k += 1
        }
        return n
    }

    /// Makefile: `target: deps` and `VAR := value` at the start of a line.
    mutating func scanMakefileLineStart() -> Bool {
        guard bytes[i] != 0x09 else { return false }    // recipe line
        let end = lineEnd(from: i)
        var k = i
        while k < end && (Byte.isWord(bytes[k]) || Array("./%-$(){}".utf8).contains(bytes[k])) { k += 1 }
        guard k > i else { return false }
        var m = k
        while m < end && Byte.isSpace(bytes[m]) { m += 1 }
        guard m < end else { return false }
        let c = bytes[m]
        let next = m + 1 < end ? bytes[m + 1] : 0
        if c == UInt8(ascii: "=") || (Array(":?+!".utf8).contains(c) && next == UInt8(ascii: "=")) || (c == UInt8(ascii: ":") && next == UInt8(ascii: ":") && m + 2 < end && bytes[m + 2] == UInt8(ascii: "=")) {
            let word = text(i, k)
            if keywords.contains(word) { return false }
            emit(.property, k)
            atLineStart = false
            return true
        }
        if c == UInt8(ascii: ":") {
            let word = text(i, k)
            if keywords.contains(word) { emit(.keyword, k) } else { emit(.function, k) }
            atLineStart = false
            return true
        }
        return false
    }
}
