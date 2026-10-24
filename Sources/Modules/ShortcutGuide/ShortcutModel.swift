import Foundation
import MacToysCore

/// One shortcut row: a menu item, a system shortcut or a MacToys binding.
public struct ShortcutItem: Identifiable, Equatable, Sendable {
    public var title: String
    /// Keycaps, e.g. `["⇧", "⌘", "N"]`.
    public var keys: [String]
    public var enabled: Bool

    public init(_ title: String, _ keys: [String], enabled: Bool = true) {
        self.title = title
        self.keys = keys
        self.enabled = enabled
    }

    public var id: String { title + "\u{1F}" + keys.joined(separator: " ") }
}

public struct ShortcutGroup: Identifiable, Equatable, Sendable {
    public var title: String
    public var items: [ShortcutItem]

    public init(_ title: String, _ items: [ShortcutItem]) {
        self.title = title
        self.items = items
    }

    public var id: String { title }
}

/// Converts the Accessibility description of a menu item's key equivalent into keycaps.
public enum MenuGlyphs {
    // AXMenuItemCmdModifiers bits (Carbon kMenu*Modifier / AXMenuItemModifiers).
    public static let shiftBit = 1 << 0
    public static let optionBit = 1 << 1
    public static let controlBit = 1 << 2
    /// Set when the shortcut does not use ⌘ (0 alone means "⌘ only").
    public static let noCommandBit = 1 << 3
    /// Set by AppKit for 🌐/fn key equivalents (e.g. Enter Full Screen, fn F).
    public static let functionBit = 1 << 4

    /// Modifier keycaps in Apple's order: fn ⌃ ⌥ ⇧ ⌘.
    public static func modifiers(_ mask: Int) -> [String] {
        var out: [String] = []
        if mask & functionBit != 0 { out.append("fn") }
        if mask & controlBit != 0 { out.append("⌃") }
        if mask & optionBit != 0 { out.append("⌥") }
        if mask & shiftBit != 0 { out.append("⇧") }
        if mask & noCommandBit == 0 { out.append("⌘") }
        return out
    }

    /// Carbon menu glyph codes (`kMenu…Glyph`) as keycaps.
    public static func glyph(_ code: Int) -> String? {
        switch code {
        case 0x02: "⇥"
        case 0x03: "⇤"
        case 0x04: "⌤"
        case 0x05: "⇧"
        case 0x06: "⌃"
        case 0x07: "⌥"
        case 0x09: "Space"
        case 0x0A: "⌦"
        case 0x0B, 0x0C, 0x0D: "↩"
        case 0x10: "⇣"
        case 0x11: "⌘"
        case 0x17: "⌫"
        case 0x18: "⇠"
        case 0x19: "⇡"
        case 0x1A: "⇢"
        case 0x1B: "⎋"
        case 0x1C: "⌧"
        case 0x1D: "『"
        case 0x1E: "』"
        case 0x62: "⇞"
        case 0x63: "⇪"
        case 0x64: "←"
        case 0x65: "→"
        case 0x66: "↖"
        case 0x67: "Help"
        case 0x68: "↑"
        case 0x69: "↘"
        case 0x6A: "↓"
        case 0x6B: "⇟"
        case 0x6E: "⌽"
        case 0x6F...0x7A: "F\(code - 0x6F + 1)"
        case 0x87...0x89: "F\(code - 0x87 + 13)"
        case 0x8C: "⏏"
        case 0x8D: "英数"
        case 0x8E: "かな"
        case 0x8F...0x92: "F\(code - 0x8F + 16)"
        default: nil
        }
    }

    /// A key-equivalent character as a keycap: control characters and AppKit's private-use
    /// function-key characters become symbols, letters are upper-cased.
    public static func character(_ s: String) -> String? {
        guard let scalar = s.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x19: return "⇤"
        case 0x0A, 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
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
        case 0xF746: return "Help"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return s.uppercased()
        }
    }

    /// Keycaps for a menu item, or nil when it has no shortcut.
    public static func keys(char: String?, virtualKey: Int?, glyph: Int?, modifiers mask: Int?) -> [String]? {
        var key: String?
        if let glyph, glyph != 0 { key = self.glyph(glyph) }
        if key == nil, let char, !char.isEmpty { key = character(char) }
        // Some apps describe the key only by virtual key code (0 also means "none", so it's skipped).
        if key == nil, let virtualKey, (1..<128).contains(virtualKey), char != nil || (glyph ?? 0) != 0 {
            key = KeyCodes.name(for: UInt16(virtualKey))
        }
        guard let key else { return nil }
        return modifiers(mask ?? 0) + [key]
    }
}

/// Search in the guide: every word must match the title, the group, or a key
/// (`cmd`, `shift`, `opt`, `ctrl` match the symbols).
public enum ShortcutFilter {
    static let aliases: [String: String] = [
        "cmd": "⌘", "command": "⌘", "shift": "⇧", "opt": "⌥", "option": "⌥", "alt": "⌥",
        "ctrl": "⌃", "control": "⌃", "fn": "fn", "globe": "fn", "return": "↩", "enter": "↩",
        "esc": "⎋", "escape": "⎋", "tab": "⇥", "delete": "⌫", "space": "Space",
    ]

    public static func matches(_ item: ShortcutItem, group: String, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let title = (item.title + " " + group).lowercased()
        let keys = item.keys.map { $0.lowercased() }
        return words.allSatisfy { word in
            if title.contains(word) { return true }
            if let symbol = aliases[word] { return keys.contains(symbol.lowercased()) }
            return keys.contains(word) || keys.joined().contains(word)
        }
    }

    public static func filter(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        return groups.compactMap { g in
            let items = g.items.filter { matches($0, group: g.title, query: query) }
            return items.isEmpty ? nil : ShortcutGroup(g.title, items)
        }
    }
}

/// Splits groups into reading-order columns of similar height.
public enum ColumnLayout {
    /// Groups never split; a header counts as about two rows. A group goes into the current column
    /// while at least half of it fits under that column's share of what's left.
    public static func distribute(_ groups: [ShortcutGroup], columns: Int) -> [[ShortcutGroup]] {
        guard columns > 1, !groups.isEmpty else { return [groups] }
        func weight(_ g: ShortcutGroup) -> Int { g.items.count + 2 }
        var remaining = groups.reduce(0) { $0 + weight($1) }
        var index = 0
        var result: [[ShortcutGroup]] = []
        for column in 0..<columns {
            let target = Double(remaining) / Double(columns - column)
            var list: [ShortcutGroup] = []
            var height = 0
            while index < groups.count {
                let w = weight(groups[index])
                if column < columns - 1, !list.isEmpty, Double(height) + Double(w) / 2 > target { break }
                list.append(groups[index])
                height += w
                index += 1
            }
            remaining -= height
            if !list.isEmpty { result.append(list) }
        }
        return result
    }
}
