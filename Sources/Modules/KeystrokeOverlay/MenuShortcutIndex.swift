import AppKit
import ApplicationServices
import MacToysCore

/// A menu item's key equivalent, normalized so a key press can find it.
public struct MenuKey: Hashable, Sendable {
    public var modifiers: Modifiers
    /// Upper-cased character, a special-key token (`KeyNames.token`), or `vk:<code>`.
    public var key: String

    public init(_ modifiers: Modifiers, _ key: String) {
        self.modifiers = modifiers
        self.key = key
    }
}

/// One menu item as Accessibility describes it.
public struct MenuItemInfo: Equatable, Sendable {
    public var title: String
    public var char: String?
    public var virtualKey: Int?
    public var glyph: Int?
    /// `AXMenuItemCmdModifiers`: shift 1, option 2, control 4, no-command 8 (fn 16).
    public var modifiers: Int?
    public var enabled: Bool

    public init(_ title: String, char: String? = nil, virtualKey: Int? = nil, glyph: Int? = nil, modifiers: Int? = nil,
                enabled: Bool = true) {
        self.title = title
        self.char = char
        self.virtualKey = virtualKey
        self.glyph = glyph
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

/// Shortcut → menu item title for one app, built from its menu bar.
public struct MenuShortcutIndex: Sendable {
    private var names: [MenuKey: String] = [:]

    /// Earlier items win; enabled items win over disabled ones (a disabled item does nothing).
    public init(items: [MenuItemInfo]) {
        var disabled: [MenuKey: String] = [:]
        for item in items {
            guard let key = Self.key(for: item) else { continue }
            if item.enabled {
                if names[key] == nil { names[key] = item.title }
            } else if disabled[key] == nil {
                disabled[key] = item.title
            }
        }
        names.merge(disabled) { enabled, _ in enabled }
    }

    public var count: Int { names.count }

    /// The menu item a press triggers, if any.
    public func name(for press: KeyPress, base: String?, shifted: String?) -> String? {
        for key in Self.candidates(for: press, base: base, shifted: shifted) {
            if let name = names[key] { return name }
        }
        return nil
    }

    /// Ways a press can be written as a key equivalent: the special-key token, or the character on
    /// the shortcut layout, or (with ⇧) the shifted character without ⇧, as in "⌘?" for Help.
    public static func candidates(for press: KeyPress, base: String?, shifted: String?) -> [MenuKey] {
        let mods = press.effectiveModifiers.intersection([.command, .control, .option, .shift, .function])
        var out: [MenuKey] = []
        if let token = KeyNames.token(press.keyCode) {
            out.append(MenuKey(mods, token))
        } else {
            if let base { out.append(MenuKey(mods, KeyNames.capital(base))) }
            if mods.contains(.shift), let shifted, shifted.uppercased() != base?.uppercased() {
                out.append(MenuKey(mods.subtracting(.shift), KeyNames.capital(shifted)))
            }
        }
        out.append(MenuKey(mods, "vk:\(press.keyCode)"))
        return out
    }

    /// The lookup key of a menu item, or nil when it has no shortcut.
    public static func key(for item: MenuItemInfo) -> MenuKey? {
        var key: String?
        if let glyph = item.glyph, glyph != 0 { key = glyphToken(glyph) }
        if key == nil, let char = item.char, !char.isEmpty { key = charToken(char) }
        if key == nil, let vk = item.virtualKey, (1..<128).contains(vk), item.char != nil || (item.glyph ?? 0) != 0 {
            key = KeyNames.token(UInt16(vk)) ?? "vk:\(vk)"
        }
        guard let key else { return nil }
        let mask = item.modifiers ?? 0
        var mods: Modifiers = []
        if mask & 1 != 0 { mods.insert(.shift) }
        if mask & 2 != 0 { mods.insert(.option) }
        if mask & 4 != 0 { mods.insert(.control) }
        if mask & 8 == 0 { mods.insert(.command) }
        if mask & 16 != 0 { mods.insert(.function) }
        return MenuKey(mods, key)
    }

    /// Carbon menu glyphs (`kMenu…Glyph`) as tokens.
    static func glyphToken(_ code: Int) -> String? {
        switch code {
        case 0x02: "⇥"
        case 0x04: "⌤"
        case 0x09: "Space"
        case 0x0A: "⌦"
        case 0x0B, 0x0C, 0x0D: "↩"
        case 0x17: "⌫"
        case 0x1B: "esc"
        case 0x1C: "⌧"
        case 0x62: "⇞"
        case 0x64: "←"
        case 0x65: "→"
        case 0x66: "↖"
        case 0x67: "Help"
        case 0x68: "↑"
        case 0x69: "↘"
        case 0x6A: "↓"
        case 0x6B: "⇟"
        case 0x6F...0x7A: "F\(code - 0x6F + 1)"
        case 0x87...0x89: "F\(code - 0x87 + 13)"
        case 0x8F...0x92: "F\(code - 0x8F + 16)"
        default: nil
        }
    }

    /// A key-equivalent character as a token: control and AppKit function-key characters become
    /// their key, letters are upper-cased.
    static func charToken(_ s: String) -> String? {
        guard let scalar = s.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x0A, 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x1B: return "esc"
        case 0x20: return "Space"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF717: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF739: return "⌧"
        case 0xF746: return "Help"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return KeyNames.capital(s)
        }
    }
}

/// Reads an app's menu bar through Accessibility. Runs off the main thread; touches no keyboard layouts.
enum MenuBarReader {
    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
                                     kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute] as CFArray
    private static let maxItems = 4000

    /// App menus first, the Apple menu last (so an app's own item wins a shared shortcut).
    static func items(pid: pid_t) -> [MenuItemInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = app.ax(kAXMenuBarAttribute) else { return [] }
        let tops = bar.children
        guard !tops.isEmpty else { return [] }
        var items: [MenuItemInfo] = []
        for top in tops.dropFirst() + tops.prefix(1) {
            guard let menu = top.children.first else { continue }
            collect(menu, depth: 0, into: &items)
            if items.count >= maxItems { break }
        }
        return items
    }

    private static func collect(_ menu: AXUIElement, depth: Int, into items: inout [MenuItemInfo]) {
        for element in menu.children {
            guard items.count < maxItems else { return }
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                         &values) == .success,
                  let list = values as? [Any], list.count == 7 else { continue }
            let title = (value(list[0]) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }
            if let submenu = (value(list[6]) as? [AXUIElement])?.first, depth < 3 {
                collect(submenu, depth: depth + 1, into: &items)
                continue
            }
            items.append(MenuItemInfo(title, char: value(list[2]) as? String,
                                      virtualKey: (value(list[3]) as? NSNumber)?.intValue,
                                      glyph: (value(list[4]) as? NSNumber)?.intValue,
                                      modifiers: (value(list[5]) as? NSNumber)?.intValue,
                                      enabled: (value(list[1]) as? Bool) ?? true))
        }
    }

    /// Missing attributes come back as AXValues of type `.axError`.
    private static func value(_ v: Any) -> Any? {
        let ref = v as CFTypeRef
        if CFGetTypeID(ref) == AXValueGetTypeID(), AXValueGetType(ref as! AXValue) == .axError { return nil }
        return v
    }
}

/// Menu indexes per running app, built in the background and refreshed now and then (menus change).
@MainActor
final class MenuNames {
    private struct Entry {
        var index: MenuShortcutIndex?
        var built: Date
        var building: Bool
    }

    private var entries: [pid_t: Entry] = [:]
    private var waiting: [pid_t: [(MenuShortcutIndex) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.w33d.mactoys.keystrokes.menus", qos: .utility)
    private static let maxAge: TimeInterval = 60

    /// The index if it's ready; otherwise starts a build and calls `whenReady` with it.
    func index(for pid: pid_t, whenReady: ((MenuShortcutIndex) -> Void)? = nil) -> MenuShortcutIndex? {
        let entry = entries[pid]
        if let entry, let index = entry.index, Date().timeIntervalSince(entry.built) < Self.maxAge { return index }
        if let whenReady { waiting[pid, default: []].append(whenReady) }
        build(pid)
        return entry?.index
    }

    /// Reads the app's menus ahead of the first shortcut.
    func prefetch(_ pid: pid_t) { _ = index(for: pid) }

    func forget(_ pid: pid_t) {
        entries[pid] = nil
        waiting[pid] = nil
    }

    func clear() {
        entries.removeAll()
        waiting.removeAll()
    }

    private func build(_ pid: pid_t) {
        guard AXIsProcessTrusted(), entries[pid]?.building != true else { return }
        entries[pid] = Entry(index: entries[pid]?.index, built: entries[pid]?.built ?? .distantPast, building: true)
        queue.async { [weak self] in
            let index = MenuShortcutIndex(items: MenuBarReader.items(pid: pid))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.entries[pid] != nil else { return }
                    self.entries[pid] = Entry(index: index, built: Date(), building: false)
                    let callbacks = self.waiting.removeValue(forKey: pid) ?? []
                    for callback in callbacks { callback(index) }
                }
            }
        }
    }
}
