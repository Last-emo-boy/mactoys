import AppKit
import ApplicationServices
import MacToysCore

/// Reads an app's keyboard shortcuts from its menu bar through Accessibility:
/// AXMenuBar → top menus → items (and submenus), using each item's AXMenuItemCmd* attributes.
/// Safe to call off the main thread.
enum MenuReader {
    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
                                     kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute] as CFArray

    /// Shortcut groups by top-level menu (the Apple menu is left to the macOS tab).
    static func read(pid: pid_t) -> [ShortcutGroup] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.75)
        guard let bar: AXUIElement = app.ax(kAXMenuBarAttribute) else { return [] }
        var groups: [ShortcutGroup] = []
        for (index, top) in bar.children.enumerated() where index > 0 {
            let title: String = top.ax(kAXTitleAttribute) ?? ""
            guard !title.isEmpty, let menu = top.children.first else { continue }
            var items: [ShortcutItem] = []
            collect(menu, prefix: "", depth: 0, into: &items)
            var seen = Set<String>()
            items = items.filter { seen.insert($0.id).inserted }
            if !items.isEmpty { groups.append(ShortcutGroup(title, items)) }
        }
        return groups
    }

    private static func collect(_ menu: AXUIElement, prefix: String, depth: Int, into items: inout [ShortcutItem]) {
        for item in menu.children {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                         &values) == .success,
                  let list = values as? [Any], list.count == 7 else { continue }
            let title = (value(list[0]) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }   // separators and custom views
            let enabled = (value(list[1]) as? Bool) ?? true
            let children = (value(list[6]) as? [AXUIElement]) ?? []
            if let submenu = children.first, depth < 3 {
                collect(submenu, prefix: prefix + title + " › ", depth: depth + 1, into: &items)
                continue
            }
            let keys = MenuGlyphs.keys(char: value(list[2]) as? String,
                                       virtualKey: (value(list[3]) as? NSNumber)?.intValue,
                                       glyph: (value(list[4]) as? NSNumber)?.intValue,
                                       modifiers: (value(list[5]) as? NSNumber)?.intValue)
            if let keys { items.append(ShortcutItem(prefix + title, keys, enabled: enabled)) }
        }
    }

    /// Missing attributes come back as AXValues of type `.axError`.
    private static func value(_ v: Any) -> Any? {
        let ref = v as CFTypeRef
        if CFGetTypeID(ref) == AXValueGetTypeID(), AXValueGetType(ref as! AXValue) == .axError { return nil }
        return v
    }
}
