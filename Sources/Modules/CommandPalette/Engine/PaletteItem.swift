import AppKit
import MacToysCore
import SwiftUI

/// What an item shows as its icon. Codable so pins, history and hotkeys can store it.
enum ItemIcon: Codable, Hashable, Sendable {
    /// A tinted tile with a white SF Symbol, like the module icons.
    case symbol(String, Tint)
    /// The Finder icon of a file, folder or app bundle.
    case file(String)
    /// An emoji drawn as text (script commands).
    case emoji(String)
}

/// One labelled value in the detail pane: `Unix · 1792852868`.
struct DetailRow: Hashable {
    var label: String
    var value: String
    var monospaced = true
}

/// The detail pane of the selected item.
struct ItemDetails {
    var icon: ItemIcon?
    var title: String
    /// Large bold title (a time, a result) instead of a normal headline.
    var largeTitle = false
    var subtitle: String?
    var rows: [DetailRow] = []
    /// Text preview (clipboard text, command output).
    var body: String?
    var bodyMonospaced = false
    /// Image preview (clipboard images).
    var image: NSImage?
    /// A file to show a Quick Look thumbnail of.
    var previewFile: URL?
}

/// What the front end does after an action ran.
enum ActionOutcome {
    /// Hide the launcher.
    case dismiss
    /// Hide the launcher, give focus back to the app that was in front, then run this (paste, focus a window).
    case dismissThen(@MainActor () -> Void)
    /// Keep the launcher open as it is.
    case stay
    /// Keep it open and search again (after deleting or toggling something).
    case refresh
    /// Open a nested list page.
    case push(ListPage)
    /// Replace the search text.
    case setQuery(String)
    /// Go back one page.
    case back
    /// Ask first; the confirmation's own action decides what happens next.
    case confirm(Confirmation)
}

/// An inline "Are you sure?" prompt.
struct Confirmation {
    var title: String
    var message: String
    var confirmTitle: String
    var destructive = true
    var perform: @MainActor () -> ActionOutcome
    /// An optional third choice ("Always Allow").
    var alternateTitle: String?
    var alternate: (@MainActor () -> ActionOutcome)?
}

/// One thing the user can do with an item.
struct PaletteAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    /// Key equivalent while the item is selected (and shown in the actions menu).
    var shortcut: Shortcut?
    var destructive = false
    /// Meta actions (pin, alias, hotkey) don't count as using the item.
    var recordsUsage = true
    var perform: @MainActor () -> ActionOutcome

    init(id: String, title: String, symbol: String, shortcut: Shortcut? = nil, destructive: Bool = false,
         recordsUsage: Bool = true, perform: @escaping @MainActor () -> ActionOutcome) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.destructive = destructive
        self.recordsUsage = recordsUsage
        self.perform = perform
    }
}

/// A search result or command.
struct PaletteItem: Identifiable {
    /// Stable id, prefixed with the provider id (`apps:/Applications/Safari.app`). Used for ranking,
    /// pins, aliases, hotkeys, history and command links.
    var id: String
    var title: String
    var subtitle: String = ""
    var icon: ItemIcon
    var providerID: String
    /// Section heading in the palette; defaults to the provider's name.
    var section: String?
    /// The short label on the right of the row ("App", "Copy", "Open").
    var accessory: String?
    var score: Double = 0
    var primary: PaletteAction
    var actions: [PaletteAction] = []
    /// Further actions built only when the item is selected (they may touch the disk).
    var moreActions: (@MainActor () -> [PaletteAction])?
    var details: ItemDetails?
    /// Loaded when the item is selected (file metadata, `brew info`).
    var loadDetails: (@MainActor () async -> ItemDetails?)?
    /// Web search and similar catch-alls: always listed after real matches.
    var isFallback = false
    /// Whether the provider can rebuild it from its id (needed for pins, hotkeys and aliases).
    var isPinnable = true
    /// Extra words matched by the palette's command search.
    var keywords: [String] = []
    /// Text Tab puts in the search field (a folder path to browse into).
    var autocomplete: String?

    /// Every action, primary first.
    @MainActor func allActions() -> [PaletteAction] { [primary] + actions + (moreActions?() ?? []) }
}

/// A nested list: clipboard history, windows, a provider's own page, an "Open With" chooser.
struct ListPage: Identifiable {
    var id: String
    var title: String
    var placeholder: String
    var icon: ItemIcon
    var initialQuery = ""
    /// Items shown for a query (empty text lists everything).
    var search: @MainActor (String) async -> [PaletteItem]
}

/// The kind of launcher asking, for the few providers that differ (Run shows the plugin list).
enum FrontEnd: String, Sendable { case palette, run }

/// A query handed to a provider.
struct SearchQuery: Sendable {
    /// The text after any keyword or alias.
    var text: String
    /// True for keyword, filter and page searches: empty text should list everything sensible,
    /// and partial input (an unfinished expression) may show hints or errors.
    var scoped: Bool
    var frontEnd: FrontEnd
}

/// Action titles, row labels and section headings that many providers share: one catalog entry and
/// one translator comment each.
enum Labels {
    static var open: String { String(localized: "Open", comment: "Action or row label: open the selected item") }
    static var copy: String { String(localized: "Copy", comment: "Action or row label: copy the value") }
    static var paste: String { String(localized: "Paste", comment: "Action or row label: paste into the front app") }
    static var pasteResult: String { String(localized: "Paste Result", comment: "Action: paste the result into the front app") }
    static var ok: String { String(localized: "OK", comment: "Action of a hint or error row; it does nothing") }
    static var run: String { String(localized: "Run", comment: "Action: run the command or script") }
    static var use: String { String(localized: "Use", comment: "Action: put the example into the search field") }
    static var app: String { String(localized: "App", comment: "Row label or detail row: an application") }
    static var size: String { String(localized: "Size", comment: "Detail row: a file's size, or width × height of an image or window") }
    static var location: String { String(localized: "Where", comment: "Detail row: the folder that contains the item, like Finder's Get Info") }
    static var kind: String { String(localized: "Kind", comment: "Detail row: the type of a file, like in Finder's Get Info") }
    static var category: String { String(localized: "Category", comment: "Detail row: unit category such as Length, or a utility's category") }
    static var file: String { String(localized: "File", comment: "Label: a file (row label, detail row or clipboard entry kind)") }
    static var folder: String { String(localized: "Folder", comment: "Label: a folder (row label or detail row)") }
    static var showInFinder: String { String(localized: "Show in Finder", comment: "Action: reveal the file in Finder") }
    static var copyPath: String { String(localized: "Copy Path", comment: "Action: copy the file path") }
    static var copyURL: String { String(localized: "Copy URL", comment: "Action: copy the web address") }
    static var openSettings: String { String(localized: "Open Settings", comment: "Action: open the settings page") }
    static var removeFromHistory: String { String(localized: "Remove from History", comment: "Action: forget this history entry") }
    static var commands: String { String(localized: "Commands", comment: "Section heading: top-level commands") }
    static var command: String { String(localized: "Command", comment: "Result row label: the result is a command") }
    static var pinned: String { String(localized: "Pinned", comment: "Section heading: pinned items") }
    static var recent: String { String(localized: "Recent", comment: "Section heading: recently used items") }
    static var on: String { String(localized: "On", comment: "Status: the utility or option is turned on") }
    static var off: String { String(localized: "Off", comment: "Status: the utility or option is turned off") }
    static var notInstalled: String { String(localized: "Not installed", comment: "Status: the app is not installed") }
    /// "Open in Terminal", "Run in iTerm2".
    static func openIn(_ app: String) -> String {
        String(localized: "Open in \(app)", comment: "Action; %@ is an app name such as Terminal or Safari")
    }
    static func runIn(_ app: String) -> String {
        String(localized: "Run in \(app)", comment: "Action; %@ is a terminal app such as Terminal or iTerm2")
    }
}

extension Shortcut {
    /// Shortcut helper for action key equivalents: `.cmd(kVK_ANSI_C)`.
    static func cmd(_ key: Int, shift: Bool = false, option: Bool = false) -> Shortcut {
        var m: Modifiers = [.command]
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        return Shortcut(key, m)
    }
}
