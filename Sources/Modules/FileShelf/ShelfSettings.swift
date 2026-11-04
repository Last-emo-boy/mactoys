import Carbon.HIToolbox
import MacToysCore

/// Where a new shelf appears.
enum ShelfPlacement: String, Codable, CaseIterable, Sendable {
    case pointer, rightEdge, leftEdge

    var title: String {
        switch self {
        case .pointer: String(localized: "Under the pointer", comment: "Where new shelves appear")
        case .rightEdge: String(localized: "At the right edge of the screen", comment: "Where new shelves appear")
        case .leftEdge: String(localized: "At the left edge of the screen", comment: "Where new shelves appear")
        }
    }
}

/// How an expanded shelf lays out its items.
enum ShelfLayout: String, Codable, CaseIterable, Sendable {
    case grid, list

    var title: String {
        switch self {
        case .grid: String(localized: "Grid", comment: "Expanded shelf layout: thumbnails in a grid")
        case .list: String(localized: "List", comment: "Expanded shelf layout: one row per item")
        }
    }

    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

/// File Shelf's settings (`shelf.json`).
struct ShelfSettings: Codable, Equatable {
    var shakeToOpen = true
    var shakeSensitivity: ShakeSensitivity = .medium
    /// Apps (name or bundle id) in which shaking while dragging does nothing.
    var excludedApps: [String] = []

    var newShelfShortcut: Shortcut? = Shortcut(kVK_ANSI_S, [.control, .option])
    var clipboardShortcut: Shortcut?
    var reopenShortcut: Shortcut?

    var placement: ShelfPlacement = .pointer
    var showOnAllSpaces = true
    var layout: ShelfLayout = .grid

    var closeAfterDragOut = true
    var closeWhenEmptied = true
    var alwaysCopyOnDragOut = false
    var keepAcrossRestarts = true
}
