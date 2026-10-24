import Foundation
import MacToysCore

public struct PowerRenameSettings: Codable, Equatable, Sendable {
    /// Read by the Finder extension (`MacToys › PowerRename`).
    public var showInFinderMenu = true
    /// Only show the Finder menu item while ⌥ is held (the Mac take on Windows' extended context menu).
    public var finderMenuNeedsOption = false
    public var showFinderMenuIcon = true
    /// Reopen with the checkboxes and choices of the last use.
    public var restoreFlags = true
    /// Suggest earlier search and replace texts while typing.
    public var autoComplete = true
    /// How many earlier texts to keep (PowerToys' "Maximum number of items").
    public var historySize = 10
    /// Fill the fields with the last texts used.
    public var showRecentValues = false
    public var regexFlavor: RegexFlavor = .standard
    /// Optional shortcut that opens PowerRename with the Finder selection.
    public var activation: Shortcut?

    public var lastOptions = RenameOptions()
    public var searchHistory: [String] = []
    public var replaceHistory: [String] = []

    public init() {}

    /// Puts a text at the front of a history list, without duplicates, trimmed to `historySize`.
    public mutating func remember(search: String, replace: String) {
        searchHistory = Self.push(search, to: searchHistory, limit: historySize)
        replaceHistory = Self.push(replace, to: replaceHistory, limit: historySize)
    }

    static func push(_ value: String, to list: [String], limit: Int) -> [String] {
        guard !value.isEmpty else { return Array(list.prefix(max(0, limit))) }
        return Array(([value] + list.filter { $0 != value }).prefix(max(0, limit)))
    }

    /// The options a new window starts with.
    public var initialOptions: RenameOptions {
        var o = restoreFlags ? lastOptions : RenameOptions()
        o.search = showRecentValues ? (searchHistory.first ?? "") : ""
        o.replace = showRecentValues ? (replaceHistory.first ?? "") : ""
        return o
    }
}
