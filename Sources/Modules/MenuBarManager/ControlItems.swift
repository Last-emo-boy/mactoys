import AppKit
import MacToysCore

/// Menu Bar Manager's own status items: the chevron that shows and hides, the hidden divider and the
/// optional always-hidden divider. A collapsed divider is simply very long, so every item to its
/// left is pushed past the screen's left edge — macOS's own layout does the hiding, and quitting
/// MacToys (or a crash) takes the dividers away and brings everything back.
@MainActor
final class ControlItems: NSObject {
    enum Role: String, CaseIterable {
        case chevron, hidden, alwaysHidden

        var autosaveName: String { "com.w33d.mactoys.menubar.\(rawValue)" }
    }

    /// Everything that decides how the items look; applied only when it changes.
    struct Look: Equatable {
        /// The hidden divider is collapsed (its items are off screen).
        var collapsed: Bool
        var alwaysHiddenCollapsed: Bool
        /// Hidden items show (in place or in the separate bar): the chevron points the other way.
        var chevronShowsOpen: Bool
        var chevron: ChevronStyle
        var divider: DividerStyle
        var arranging: Bool
        var collapsedLength: CGFloat
    }

    /// Called on a click: the item and the event (for ⌥ and right-clicks).
    var onAction: ((Role, NSEvent?) -> Void)?

    private var items: [Role: NSStatusItem] = [:]
    private var applied: [Role: Look] = [:]
    private let defaults = StatusItemDefaults(defaults: .standard)

    var isInstalled: Bool { items[.chevron] != nil }
    var hasAlwaysHidden: Bool { items[.alwaysHidden] != nil }
    var chevronButton: NSStatusBarButton? { items[.chevron]?.button }
    nonisolated static var autosaveNames: [String] { Role.allCases.map(\.autosaveName) }

    /// Creates the missing items. New status items appear at the far left of the status items, so
    /// creating chevron → divider → always-hidden divider lines them up as `‖ | ›` left of everything
    /// the user has: nothing is hidden until the user drags icons across a divider. Positions the user
    /// arranged earlier come back from `cached`.
    func install(alwaysHidden: Bool, cached: [String: Double]) {
        let roles: [Role] = alwaysHidden ? [.chevron, .hidden, .alwaysHidden] : [.chevron, .hidden]
        defaults.restore(cached, names: roles.map(\.autosaveName))
        for role in roles where items[role] == nil { create(role) }
        if !alwaysHidden { remove(.alwaysHidden) }
    }

    /// Removes every item. AppKit forgets a removed item's position, so it's captured first and
    /// written back; the captured positions are returned for safekeeping.
    @discardableResult
    func removeAll() -> [String: Double] {
        let positions = defaults.capture(Self.autosaveNames)
        for role in Role.allCases { remove(role) }
        return positions
    }

    /// Positions AppKit currently stores for the items.
    func positions() -> [String: Double] { defaults.capture(Self.autosaveNames) }

    /// Forgets every stored position so re-created items start at the far left again.
    func clearPositions() {
        for name in Self.autosaveNames { defaults.setPosition(nil, for: name) }
    }

    private func create(_ role: Role) {
        defaults.markVisible(role.autosaveName)
        let item = NSStatusBar.system.statusItem(withLength: role == .chevron ? NSStatusItem.variableLength : 14)
        item.autosaveName = role.autosaveName
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
            button.imagePosition = .imageOnly
        }
        items[role] = item
        applied[role] = nil
    }

    private func remove(_ role: Role) {
        guard let item = items[role] else { return }
        let saved = defaults.position(role.autosaveName)
        NSStatusBar.system.removeStatusItem(item)
        defaults.setPosition(saved, for: role.autosaveName)
        items[role] = nil
        applied[role] = nil
    }

    /// Re-applies even unchanged looks (after a display change or wake, when macOS re-lays out).
    func invalidate() { applied.removeAll() }

    func apply(_ look: Look) {
        for (role, item) in items where applied[role] != look {
            applied[role] = look
            switch role {
            case .chevron:
                item.length = NSStatusItem.variableLength
                item.button?.image = Self.chevronImage(look.chevron, collapsed: !look.chevronShowsOpen)
                let label = !look.chevronShowsOpen
                    ? String(localized: "Show hidden menu bar items", comment: "Menu Bar Manager chevron: accessibility label and tooltip")
                    : String(localized: "Hide menu bar items", comment: "Menu Bar Manager chevron: accessibility label and tooltip")
                item.button?.toolTip = label
                item.button?.setAccessibilityLabel(label)
                item.button?.contentTintColor = nil
            case .hidden:
                configureDivider(item, collapsed: look.collapsed, look: look, double: false)
            case .alwaysHidden:
                configureDivider(item, collapsed: look.collapsed || look.alwaysHiddenCollapsed, look: look, double: true)
            }
        }
    }

    private func configureDivider(_ item: NSStatusItem, collapsed: Bool, look: Look, double: Bool) {
        if collapsed {
            item.button?.image = nil
            item.length = look.collapsedLength
        } else {
            let style = look.arranging && look.divider == .none ? .line : look.divider
            item.length = MenuBarLayout.expandedLength(style: style, arranging: look.arranging)
            item.button?.image = style == .none ? nil : Self.dividerImage(style, double: double)
        }
        // While arranging, the dividers glow in the accent color so they're easy to drag icons across.
        item.button?.contentTintColor = look.arranging && !collapsed ? .controlAccentColor : nil
        let label = double
            ? String(localized: "Always-hidden divider: icons to its left stay hidden", comment: "Menu Bar Manager divider: accessibility label")
            : String(localized: "Divider: icons to its left are hidden", comment: "Menu Bar Manager divider: accessibility label")
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
    }

    // MARK: Geometry

    /// The items' window frames, global top-left coordinates.
    var frames: ControlFrames {
        func frame(_ role: Role) -> CGRect? {
            guard let window = items[role]?.button?.window, window.frame != .zero else { return nil }
            return ScreenGeometry.toAX(window.frame)
        }
        return ControlFrames(chevron: frame(.chevron), hidden: frame(.hidden), alwaysHidden: frame(.alwaysHidden))
    }

    /// Window numbers of the items, so scans can leave them out.
    var windowIDs: Set<CGWindowID> {
        Set(items.values.compactMap { $0.button?.window.map { CGWindowID($0.windowNumber) } })
    }

    /// The display whose menu bar shows the items.
    var screen: NSScreen? { items[.chevron]?.button?.window?.screen ?? NSScreen.screens.first }

    /// The chevron's frame in Cocoa coordinates, for placing panels under it.
    var chevronScreenFrame: CGRect? {
        guard let button = items[.chevron]?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Shows a menu from the chevron, highlighted like any status item menu.
    func popUp(_ menu: NSMenu) {
        guard let item = items[.chevron] else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let role = Role(rawValue: sender.identifier?.rawValue ?? "") ?? .chevron
        onAction?(role, NSApp.currentEvent)
    }

    // MARK: Images

    static func chevronImage(_ style: ChevronStyle, collapsed: Bool) -> NSImage? {
        let pointSize: CGFloat = style == .dot ? 9 : 13
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: style.symbol(collapsed: collapsed),
                            accessibilityDescription: String(localized: "Menu Bar Manager"))?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// A thin vertical line, a column of dots, or (always-hidden) a double line.
    static func dividerImage(_ style: DividerStyle, double: Bool) -> NSImage {
        let size = CGSize(width: double ? 8 : 4, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.75).setFill()
            switch style {
            case .dots:
                let d: CGFloat = 2.6
                let xs: [CGFloat] = double ? [rect.midX - 2, rect.midX + 2] : [rect.midX]
                for x in xs {
                    for i in -1...1 {
                        NSBezierPath(ovalIn: CGRect(x: x - d / 2, y: rect.midY + CGFloat(i) * 4.4 - d / 2, width: d, height: d)).fill()
                    }
                }
            case .line, .none:
                let w: CGFloat = 1.6, h: CGFloat = 14
                let xs: [CGFloat] = double ? [rect.midX - 1.9, rect.midX + 1.9] : [rect.midX]
                for x in xs {
                    NSBezierPath(roundedRect: CGRect(x: x - w / 2, y: rect.midY - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
