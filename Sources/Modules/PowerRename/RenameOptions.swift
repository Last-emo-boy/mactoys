import Foundation

/// Which part of a name the search and replace works on.
public enum RenameScope: String, Codable, CaseIterable, Sendable {
    /// The name without its extension (`IMG_4821` of `IMG_4821.HEIC`).
    case name
    /// Only the extension, without the dot (`HEIC`).
    case `extension`
    /// The whole file name.
    case both

    public var title: String {
        switch self {
        case .name: String(localized: "Name", comment: "PowerRename: apply to the file name without its extension")
        case .extension: String(localized: "Extension", comment: "PowerRename: apply to the file extension only")
        case .both: String(localized: "Both", comment: "PowerRename: apply to both name and extension")
        }
    }
}

/// Case conversion applied after replacing.
public enum TextFormat: String, Codable, CaseIterable, Sendable {
    case none, lowercase, uppercase, titleCase, capitalized

    /// The short button label used in the window ("aa", "AA", "Aa", "Aa Bb").
    public var label: String {
        switch self {
        case .none: ""
        case .lowercase: "aa"
        case .uppercase: "AA"
        case .titleCase: "Aa"
        case .capitalized: "Aa Bb"
        }
    }

    public var title: String {
        switch self {
        case .none: String(localized: "None", comment: "PowerRename text format: no case change")
        case .lowercase: String(localized: "Lowercase")
        case .uppercase: String(localized: "Uppercase")
        case .titleCase: String(localized: "Title case")
        case .capitalized: String(localized: "Capitalize every word")
        }
    }
}

/// Which file date the `$YYYY`-style variables read.
public enum RenameDateSource: String, Codable, CaseIterable, Sendable {
    case created, modified, accessed

    public var title: String {
        switch self {
        case .created: String(localized: "Date created")
        case .modified: String(localized: "Date modified")
        case .accessed: String(localized: "Date last opened")
        }
    }
}

/// How the *Replace with* text is read when regular expressions are on.
public enum RegexFlavor: String, Codable, CaseIterable, Sendable {
    /// ECMAScript rules, as PowerToys uses by default: `$1`, `$&`, `` $` ``, `$'`, `$$`; a backslash is literal.
    case standard
    /// Perl/Boost rules (PowerToys' "Use Boost library"): additionally `${1}`, `${name}`, `$+{name}`,
    /// backslash escapes and case conversion with `\U … \E`, `\L … \E`, `\u`, `\l`.
    case extended

    public var title: String {
        switch self {
        case .standard: String(localized: "Standard (ECMAScript)", comment: "PowerRename regular expression syntax; ECMAScript is a name")
        case .extended: String(localized: "Extended (Perl / Boost)", comment: "PowerRename regular expression syntax; Perl and Boost are names")
        }
    }
}

/// Everything the user sets in the PowerRename window.
public struct RenameOptions: Codable, Equatable, Sendable {
    public var search = ""
    public var replace = ""
    public var useRegex = false
    public var matchAll = false
    public var caseSensitive = false
    public var scope: RenameScope = .name
    public var includeFiles = true
    public var includeFolders = true
    public var includeSubfolders = true
    public var textFormat: TextFormat = .none
    /// Enables `${}`, `${start=…,increment=…,padding=…}` counters.
    public var enumerate = true
    /// Enables `${rstringalnum=N}`, `${rstringalpha=N}`, `${rstringdigit=N}` and `${ruuidv4}`.
    public var randomize = false
    public var dateSource: RenameDateSource = .created
    /// Glob patterns (`*.tmp, .DS_Store`) separated by commas, semicolons or new lines; matching items are left alone.
    public var exclude = ""

    public init() {}
}
