import AppKit
import ApplicationServices
import MacToysCore

/// One status item as Accessibility describes it (an `AXMenuBarItem` in an app's `AXExtrasMenuBar`).
struct AXStatusItem: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    /// Global top-left coordinates.
    let frame: CGRect
    /// The best human-readable name: title, description or help text.
    let name: String?
    let identifier: String?
}

/// Accessibility reads and actions for menu bar items. Every call returns nothing (and never
/// prompts) while MacToys isn't trusted; each app gets a short messaging timeout so a hung app
/// can't stall the caller.
enum MenuBarAX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app's status items, left to right.
    static func items(pid: pid_t) -> [AXStatusItem] {
        guard isTrusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar: AXUIElement = app.ax("AXExtrasMenuBar") else { return [] }
        let items: [AXUIElement] = bar.ax(kAXChildrenAttribute) ?? []
        return items.compactMap { el -> AXStatusItem? in
            guard let frame = frame(of: el) else { return nil }
            let title: String? = el.ax(kAXTitleAttribute)
            let description: String? = el.ax(kAXDescriptionAttribute)
            let help: String? = el.ax(kAXHelpAttribute)
            let name = [title, description, help].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return AXStatusItem(element: el, pid: pid, frame: frame, name: name, identifier: el.ax(kAXIdentifierAttribute))
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The right edge of the front app's menus (the last `AXMenuBarItem` of its menu bar).
    static func appMenuMaxX(pid: pid_t) -> CGFloat? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar: AXUIElement = app.ax(kAXMenuBarAttribute) else { return nil }
        let menus: [AXUIElement] = bar.ax(kAXChildrenAttribute) ?? []
        return menus.compactMap { frame(of: $0)?.maxX }.max()
    }

    /// Presses an item: opens its menu or runs its action.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let pv: AXValue = element.ax(kAXPositionAttribute), let sv: AXValue = element.ax(kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Matches each window to the app's AX item at the same place, or failing that the one at the same
    /// position in order (both lists are left to right).
    static func match(windows: [StatusWindow], items: [AXStatusItem]) -> [CGWindowID: AXStatusItem] {
        var result: [CGWindowID: AXStatusItem] = [:]
        var unused = items
        for w in windows {
            if let i = unused.firstIndex(where: { abs($0.frame.minX - w.frame.minX) < 3 && abs($0.frame.width - w.frame.width) < 6 }) {
                result[w.id] = unused.remove(at: i)
            }
        }
        if result.count < windows.count && windows.count == items.count {
            for (w, item) in zip(windows, items) where result[w.id] == nil { result[w.id] = item }
        }
        return result
    }

    /// Fills in names and identifiers of `items` from Accessibility, one app at a time. Safe to call
    /// off the main thread.
    static func describe(_ items: [MenuBarItem]) -> [MenuBarItem] {
        guard isTrusted else { return items }
        var byPid: [pid_t: [StatusWindow]] = [:]
        for item in items { byPid[item.pid, default: []].append(item.window) }
        var named: [CGWindowID: AXStatusItem] = [:]
        for (pid, windows) in byPid {
            named.merge(match(windows: windows.sorted { $0.frame.minX < $1.frame.minX }, items: Self.items(pid: pid))) { a, _ in a }
        }
        return items.map { item in
            var copy = item
            if let ax = named[item.window.id] {
                copy.name = ax.name
                copy.identifier = ax.identifier
            }
            return copy
        }
    }

    /// The AX element for an item right now (positions change as sections show and hide).
    static func element(for item: MenuBarItem, in windows: [StatusWindow]) -> AXStatusItem? {
        let own = windows.filter { $0.pid == item.pid }
        let axItems = items(pid: item.pid)
        if let current = own.first(where: { $0.id == item.window.id }), let hit = match(windows: own, items: axItems)[current.id] {
            return hit
        }
        if let identifier = item.identifier { return axItems.first { $0.identifier == identifier } }
        if let name = item.name { return axItems.first { $0.name == name } }
        return axItems.count == 1 ? axItems.first : nil
    }
}

/// SF Symbols for Apple's own menu bar items, which all belong to one system process and so would
/// otherwise share one app icon.
enum SystemItemSymbols {
    private static let table: [(String, String)] = [
        ("wifi", "wifi"), ("battery", "battery.75percent"), ("bluetooth", "dot.radiowaves.left.and.right"),
        ("sound", "speaker.wave.2.fill"), ("volume", "speaker.wave.2.fill"), ("focus", "moon.fill"),
        ("controlcenter", "switch.2"), ("clock", "clock"), ("spotlight", "magnifyingglass"), ("siri", "waveform"),
        ("display", "sun.max.fill"), ("nowplaying", "play.fill"), ("screenmirroring", "rectangle.on.rectangle"),
        ("textinput", "keyboard"), ("timemachine", "clock.arrow.circlepath"), ("vpn", "network.badge.shield.half.filled"),
        ("user", "person.crop.circle"), ("accessibility", "accessibility"), ("airdrop", "dot.radiowaves.up.forward"),
        ("keyboardbrightness", "light.max"), ("stagemanager", "squares.leading.rectangle"), ("weather", "cloud.sun.fill"),
        ("hearing", "ear"), ("airplay", "airplayvideo"),
    ]

    static func symbol(for identifier: String?) -> String? {
        guard let id = identifier?.lowercased(), id.hasPrefix("com.apple.") else { return nil }
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        return table.first { tail.contains($0.0) }?.1
    }
}
