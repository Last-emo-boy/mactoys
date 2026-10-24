import Foundation

/// What a run of source text is, for coloring.
public enum TokenKind: String, Sendable, CaseIterable {
    case plain, keyword, type, function, builtin, literal, string, number, comment, meta, attribute
    case tag, attrName, attrValue, variable, property, heading, section, inserted, deleted, regex, escape
    case emphasis, strong, link

    /// CSS class used by `CodeRenderer` (`nil` for plain text).
    public var cssClass: String? {
        switch self {
        case .plain: nil
        case .keyword: "kw"
        case .type: "ty"
        case .function: "fn"
        case .builtin: "bi"
        case .literal: "lit"
        case .string: "str"
        case .number: "num"
        case .comment: "com"
        case .meta: "meta"
        case .attribute: "at"
        case .tag: "tag"
        case .attrName: "an"
        case .attrValue: "av"
        case .variable: "var"
        case .property: "prop"
        case .heading: "head"
        case .section: "sec"
        case .inserted: "ins"
        case .deleted: "del"
        case .regex: "re"
        case .escape: "esc"
        case .emphasis: "em"
        case .strong: "strong"
        case .link: "link"
        }
    }
}

/// A colored run of source text.
public struct Token: Equatable, Sendable, CustomStringConvertible {
    public var kind: TokenKind
    public var text: String

    public init(_ kind: TokenKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var description: String { "\(kind.rawValue)(\(text.debugDescription))" }
}

/// A string literal form, e.g. `"…"` with backslash escapes or Python's `'''…'''`.
public struct StringRule: Sendable {
    public var open: String
    public var close: String
    /// Backslash escapes the next character.
    public var escapes: Bool
    /// May span lines.
    public var multiline: Bool
    /// Letters allowed right before `open` (`r`, `b`, `f`, `@`, `$`…), part of the literal.
    public var prefixes: [String]
    /// A short character literal (`'a'`); when no close quote follows within a few characters
    /// the quote is plain text (Rust lifetimes, Lisp quotes).
    public var isCharLiteral: Bool

    public init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false,
                prefixes: [String] = [], isCharLiteral: Bool = false) {
        self.open = open
        self.close = close ?? open
        self.escapes = escapes
        self.multiline = multiline
        self.prefixes = prefixes
        self.isCharLiteral = isCharLiteral
    }
}

/// How a language is scanned. Most use the configurable `.generic` scanner.
public enum ScanMode: Sendable {
    case generic, markup, css, json, yaml, ini, diff, markdown, makefile, plain
}

/// Everything the tokenizer needs to know about one language.
public struct Language: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Names accepted after a Markdown code fence (` ```js `).
    public var aliases: [String] = []
    /// File name extensions, lowercased, without the dot.
    public var extensions: [String] = []
    /// Exact file names (`Makefile`, `Dockerfile`, `.zshrc`).
    public var fileNames: [String] = []
    /// Interpreters named on a `#!` line.
    public var interpreters: [String] = []
    public var mode: ScanMode = .generic
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var literals: Set<String> = []
    public var builtins: Set<String> = []
    public var lineComments: [String] = []
    public var blockComments: [(open: String, close: String)] = []
    public var nestedComments = false
    public var strings: [StringRule] = []
    /// Keywords match regardless of case (SQL, Dockerfile instructions).
    public var caseInsensitive = false
    /// Extra identifier characters beyond letters, digits and `_`.
    public var identifierExtras: Set<UInt8> = []
    /// Sigils that start a variable: `$` (shell, PHP, Perl), `@` (Ruby instance variables).
    public var variableSigils: Set<UInt8> = []
    /// `@Name` is an attribute/decorator/annotation.
    public var atAttributes = false
    /// `#…` at the start of a line is a preprocessor directive (C family).
    public var preprocessor = false
    /// `#[…]` attributes (Rust).
    public var hashBracketAttributes = false
    /// `name(` is colored as a function call.
    public var functionCalls = true
    /// Capitalized identifiers are types (Swift, Java, Kotlin, Rust…).
    public var capitalizedTypes = false
    /// `/…/flags` regular expression literals (JavaScript, Ruby, Perl).
    public var regexLiterals = false
    /// `:symbol` literals (Ruby).
    public var symbols = false
    /// Line comments only count at the start of a word (`#` in shell after whitespace).
    public var commentNeedsWordBoundary = false
    /// Embedded languages inside `<script>`/`<style>` (HTML).
    public var embedsScriptAndStyle = false

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
