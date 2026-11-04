import ApplicationServices
import Foundation
import MacToysCore

/// An Accessibility element of a menu item, kept so the item can be pressed later.
struct MenuElement: @unchecked Sendable, Equatable {
    let element: AXUIElement
    static func == (a: MenuElement, b: MenuElement) -> Bool { CFEqual(a.element, b.element) }
}

/// One item of an app's menu bar as read through Accessibility.
struct MenuNode: Equatable, Sendable {
    var title: String
    var enabled = true
    /// Keycaps of its key equivalent, e.g. `["⇧", "⌘", "T"]`; empty when it has none.
    var keys: [String] = []
    /// Shown with a check mark (a selected option or a visible panel).
    var checked = false
    /// nil for a command; the items of its submenu otherwise (empty while the app hasn't filled it).
    var children: [MenuNode]?
    var element: MenuElement?
}

/// A runnable menu command: a leaf of the menu tree with its path from the menu bar.
struct MenuCommand: Identifiable, Equatable, Sendable {
    /// Titles from the top-level menu down to the item: `["File", "Export To", "PDF…"]`.
    var path: [String]
    var enabled: Bool
    var keys: [String]
    var checked: Bool
    var element: MenuElement?
    /// The path joined with U+001F; a number is appended when an app repeats a title.
    var id: String

    var title: String { path.last ?? "" }
    /// The top-level menu ("File").
    var menu: String { path.first ?? "" }
    /// "File › Export To".
    var parentPath: String { path.dropLast().joined(separator: " › ") }
    /// "File › Export To › PDF…".
    var fullPath: String { path.joined(separator: " › ") }
}

/// Flattens menu trees into commands.
enum MenuFlattener {
    /// `menus` are the top-level menus (the app menu, File, Edit…), each with its items as children.
    static func flatten(_ menus: [MenuNode]) -> [MenuCommand] {
        var out: [MenuCommand] = []
        var seen: [String: Int] = [:]
        func walk(_ node: MenuNode, path: [String]) {
            let title = node.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            let here = path + [title]
            if let children = node.children {
                for child in children { walk(child, path: here) }
                return
            }
            var id = here.joined(separator: "\u{1F}")
            let n = seen[id, default: 0]
            seen[id] = n + 1
            if n > 0 { id += "\u{1F}#\(n + 1)" }
            out.append(MenuCommand(path: here, enabled: node.enabled, keys: node.keys, checked: node.checked,
                                   element: node.element, id: id))
        }
        for menu in menus {
            let title = menu.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            for child in menu.children ?? [] { walk(child, path: [title]) }
        }
        return out
    }
}

/// Converts the Accessibility description of a menu item's key equivalent into keycaps.
enum MenuKeycaps {
    // AXMenuItemCmdModifiers bits (the Carbon kMenu…Modifier values).
    static let shiftBit = 1 << 0
    static let optionBit = 1 << 1
    static let controlBit = 1 << 2
    /// Set when the shortcut doesn't use ⌘ (0 alone means "⌘ only").
    static let noCommandBit = 1 << 3
    /// Set for 🌐/fn key equivalents (Enter Full Screen: fn F).
    static let functionBit = 1 << 4

    /// Modifier keycaps in Apple's order: fn ⌃ ⌥ ⇧ ⌘.
    static func modifiers(_ mask: Int) -> [String] {
        var out: [String] = []
        if mask & functionBit != 0 { out.append("fn") }
        if mask & controlBit != 0 { out.append("⌃") }
        if mask & optionBit != 0 { out.append("⌥") }
        if mask & shiftBit != 0 { out.append("⇧") }
        if mask & noCommandBit == 0 { out.append("⌘") }
        return out
    }

    /// Carbon menu glyph codes (`kMenu…Glyph`) as keycaps.
    static func glyph(_ code: Int) -> String? {
        switch code {
        case 0x02: "⇥"
        case 0x03: "⇤"
        case 0x04: "⌤"
        case 0x09: "␣"
        case 0x0A: "⌦"
        case 0x0B, 0x0C, 0x0D: "↩"
        case 0x10: "⇣"
        case 0x17: "⌫"
        case 0x1B: "⎋"
        case 0x1C: "⌧"
        case 0x62: "⇞"
        case 0x63: "⇪"
        case 0x64: "←"
        case 0x65: "→"
        case 0x66: "↖"
        case 0x68: "↑"
        case 0x69: "↘"
        case 0x6A: "↓"
        case 0x6B: "⇟"
        case 0x6F...0x7A: "F\(code - 0x6F + 1)"
        case 0x87...0x89: "F\(code - 0x87 + 13)"
        case 0x8C: "⏏"
        case 0x8F...0x92: "F\(code - 0x8F + 16)"
        default: nil
        }
    }

    /// A key-equivalent character as a keycap: control characters and AppKit's function-key
    /// characters become symbols, letters are upper-cased.
    static func character(_ s: String) -> String? {
        guard let scalar = s.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x19: return "⇤"
        case 0x0A, 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x1B: return "⎋"
        case 0x20: return "␣"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71B: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF739: return "⌧"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return s.uppercased()
        }
    }

    /// Keycaps for a menu item, or `[]` when it has no key equivalent.
    static func keys(char: String?, virtualKey: Int?, glyph: Int?, modifiers mask: Int?) -> [String] {
        var key: String?
        if let glyph, glyph != 0 { key = self.glyph(glyph) }
        if key == nil, let char, !char.isEmpty { key = character(char) }
        // Some apps describe the key only by its virtual key code (0 also means "none", so it's skipped).
        if key == nil, let virtualKey, (1..<128).contains(virtualKey), char != nil || (glyph ?? 0) != 0 {
            key = KeyCodes.name(for: UInt16(virtualKey))
        }
        guard let key else { return [] }
        return modifiers(mask ?? 0) + [key]
    }
}

/// Ranks menu commands: fuzzy match on the title and the whole path, raised by how often and how
/// recently the command was run in this app; commands that can't run now sink below those that can.
enum MenuRanker {
    struct Usage: Codable, Equatable, Sendable {
        var count: Int
        var last: Date
    }

    static let disabledPenalty = 150.0

    /// Match score of a command for a query (nil: no match).
    static func match(_ command: MenuCommand, _ query: String) -> Double? {
        FuzzyMatcher.best(query, title: command.title, keywords: [command.path.joined(separator: " ")])
    }

    /// Bonus for commands run often or lately (0…~140).
    static func boost(_ usage: Usage?, now: Date) -> Double {
        guard let usage else { return 0 }
        let frequency = min(20 * log2(1 + Double(usage.count)), 100)
        let age = now.timeIntervalSince(usage.last)
        let recency: Double = age < 3600 ? 40 : age < 86400 ? 25 : age < 7 * 86400 ? 10 : 0
        return frequency + recency
    }

    /// Matching commands, best first; ties keep menu order.
    static func rank(_ commands: [MenuCommand], query: String, usage: [String: Usage], now: Date = Date())
        -> [(command: MenuCommand, score: Double)] {
        commands.enumerated().compactMap { i, c -> (Int, MenuCommand, Double)? in
            guard var s = match(c, query) else { return nil }
            s += boost(usage[c.id], now: now)
            if !c.enabled { s -= disabledPenalty }
            return (i, c, s)
        }
        .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
        .map { ($0.1, $0.2) }
    }

    /// The commands run most recently in this app, newest first.
    static func recent(_ commands: [MenuCommand], usage: [String: Usage], limit: Int) -> [MenuCommand] {
        commands.filter { usage[$0.id] != nil }
            .sorted { (usage[$0.id]?.last ?? .distantPast) > (usage[$1.id]?.last ?? .distantPast) }
            .prefix(limit).map { $0 }
    }
}
