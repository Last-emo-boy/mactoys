import AppKit
import ApplicationServices
import MacToysCore

/// Reads an app's menu bar through Accessibility and presses its items. Every call is bounded:
/// each element answers within a short messaging timeout and a read stops at a size and time
/// budget, so a slow or enormous menu never hangs the launcher. Call off the main thread.
enum MenuReader {
    struct Budget: Sendable {
        var maxItems = 4000
        var maxDepth = 6
        var seconds: TimeInterval = 1.5
        /// Seconds one element may take to answer.
        var timeout: Float = 0.35
    }

    struct Snapshot: Sendable {
        var menus: [MenuNode]
        var commands: [MenuCommand]
        /// The budget ran out before every menu was read.
        var truncated: Bool
    }

    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
                                     kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXMenuItemMarkCharAttribute,
                                     kAXChildrenAttribute] as CFArray

    /// The app's menus without the Apple menu, as a tree and as commands.
    static func read(pid: pid_t, budget: Budget = Budget()) -> Snapshot {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, budget.timeout)
        guard let bar: AXUIElement = app.ax(kAXMenuBarAttribute) else { return Snapshot(menus: [], commands: [], truncated: false) }
        AXUIElementSetMessagingTimeout(bar, budget.timeout)
        var state = ReadState(budget: budget)
        var menus: [MenuNode] = []
        for (index, top) in bar.children.enumerated() where index > 0 {
            guard !state.exhausted else { break }
            AXUIElementSetMessagingTimeout(top, budget.timeout)
            let title: String = top.ax(kAXTitleAttribute) ?? ""
            guard !title.isEmpty, let menu = top.children.first else { continue }
            menus.append(MenuNode(title: title, children: items(of: menu, depth: 1, state: &state)))
        }
        return Snapshot(menus: menus, commands: MenuFlattener.flatten(menus), truncated: state.exhausted)
    }

    private struct ReadState {
        let budget: Budget
        let deadline: TimeInterval
        var count = 0
        var exhausted = false

        init(budget: Budget) {
            self.budget = budget
            deadline = ProcessInfo.processInfo.systemUptime + budget.seconds
        }

        mutating func spend() -> Bool {
            count += 1
            if count > budget.maxItems || ProcessInfo.processInfo.systemUptime > deadline { exhausted = true }
            return !exhausted
        }
    }

    private static func items(of menu: AXUIElement, depth: Int, state: inout ReadState) -> [MenuNode] {
        AXUIElementSetMessagingTimeout(menu, state.budget.timeout)
        var out: [MenuNode] = []
        for item in menu.children {
            guard state.spend() else { break }
            AXUIElementSetMessagingTimeout(item, state.budget.timeout)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 8 else { continue }
            let title = (value(list[0]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }   // separators, search fields and custom views
            var node = MenuNode(title: title, element: MenuElement(element: item))
            node.enabled = (value(list[1]) as? Bool) ?? true
            node.keys = MenuKeycaps.keys(char: value(list[2]) as? String, virtualKey: (value(list[3]) as? NSNumber)?.intValue,
                                         glyph: (value(list[4]) as? NSNumber)?.intValue,
                                         modifiers: (value(list[5]) as? NSNumber)?.intValue)
            let mark = (value(list[6]) as? String) ?? ""
            node.checked = !mark.trimmingCharacters(in: .whitespaces).isEmpty
            if let submenu = ((value(list[7]) as? [AXUIElement]) ?? []).first {
                node.children = depth < state.budget.maxDepth ? items(of: submenu, depth: depth + 1, state: &state) : []
            }
            out.append(node)
        }
        return out
    }

    /// Missing attributes come back as AXValues of type `.axError`.
    private static func value(_ v: Any) -> Any? {
        let ref = v as CFTypeRef
        if CFGetTypeID(ref) == AXValueGetTypeID(), AXValueGetType(ref as! AXValue) == .axError { return nil }
        return v
    }

    enum PressResult: Equatable {
        case pressed
        /// The item is gone and wasn't found again by its path.
        case notFound
        case disabled
    }

    /// Presses a command. When its element went stale (the app rebuilt its menus), the menus are
    /// read again and the item is found by its path. A timeout counts as pressed: an item that opens
    /// a dialog answers only after the dialog closes, and pressing again would run it twice.
    static func press(_ command: MenuCommand, pid: pid_t, budget: Budget = Budget()) -> PressResult {
        if let element = command.element?.element {
            AXUIElementSetMessagingTimeout(element, 1)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result != .invalidUIElement && result != .illegalArgument { return .pressed }
        }
        let fresh = read(pid: pid, budget: budget)
        guard let match = fresh.commands.first(where: { $0.path == command.path }) else { return .notFound }
        guard match.enabled else { return .disabled }
        guard let element = match.element?.element else { return .notFound }
        AXUIElementSetMessagingTimeout(element, 1)
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return .pressed
    }
}
