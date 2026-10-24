import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Shows the guide for the frontmost app without taking activation away from it.
@MainActor
final class ShortcutGuideController {
    private let settings: Persisted<ShortcutGuideSettings>
    private var panel: OverlayPanel?
    private var model: GuideModel?
    private var keyMonitor: Any?
    private var readTask: Task<Void, Never>?
    private var cache: (pid: pid_t, date: Date, groups: [ShortcutGroup])?
    /// Opened by holding ⌘ with "close when released" on.
    private(set) var closesOnRelease = false

    init(settings: Persisted<ShortcutGuideSettings>) {
        self.settings = settings
    }

    var isOpen: Bool { panel != nil }
    /// Has keyboard focus (opened by the shortcut, or the user clicked into it).
    var isKey: Bool { panel?.isKeyWindow ?? false }

    func toggle() {
        if isOpen { close() } else { open(byHold: false) }
    }

    func open(byHold: Bool) {
        guard !isOpen else { return }
        let s = settings.value
        let app = NSWorkspace.shared.frontmostApplication
        if s.excludedApps.matches(app: app) { return }
        closesOnRelease = byHold && s.closeOnRelease

        let bundleID = app?.bundleIdentifier ?? ""
        let model = GuideModel(appName: app?.localizedName ?? "App", appIcon: app?.icon, bundleID: bundleID,
                               systemGroups: SystemShortcuts.groups, macToysGroups: Self.macToysGroups(),
                               openedByHold: closesOnRelease, pinned: Set(s.pinned[bundleID] ?? []))
        model.onClose = { [weak self] in self?.close() }
        model.onTogglePin = { [weak self, weak model] item in
            guard let self, let model else { return }
            if model.pinned.contains(item.id) { model.pinned.remove(item.id) } else { model.pinned.insert(item.id) }
            self.settings.value.pinned[bundleID] = model.pinned.isEmpty ? nil : model.pinned.sorted()
        }
        self.model = model
        loadMenus(of: app, into: model)

        let screen = WindowRef.focused()?.frame.flatMap { ScreenGeometry.screen(forAX: $0) } ?? NSScreen.underMouse ?? NSScreen.main
        guard let screen else { return }
        let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
        let scheme: ColorScheme? = switch s.theme {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
        let host = FirstMouseHostingView(rootView: ShortcutGuideView(model: model, dimOpacity: s.dimOpacity, scheme: scheme))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        if closesOnRelease {
            // Held ⌘: keys keep going to the app (⌘W still closes its tab) and the guide closes.
            panel.orderFrontRegardless()
        } else {
            // A non-activating key panel: the app stays frontmost while the guide takes the keyboard.
            panel.makeKeyAndOrderFront(nil)
        }
        self.panel = panel
        installKeyMonitor()
    }

    func close() {
        readTask?.cancel()
        readTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        closesOnRelease = false
    }

    private func loadMenus(of app: NSRunningApplication?, into model: GuideModel) {
        guard let app else {
            model.loading = false
            model.tab = .macOS
            return
        }
        guard AXIsProcessTrusted() else {
            model.loading = false
            model.appMessage = "Allow Accessibility access in System Settings so Shortcut Guide can read \(model.appName)’s menus."
            return
        }
        let pid = app.processIdentifier
        if let cache, cache.pid == pid, Date().timeIntervalSince(cache.date) < 15 {
            model.appGroups = cache.groups
            model.loading = false
            return
        }
        readTask = Task { [weak self, weak model] in
            let groups = await Task.detached(priority: .userInitiated) { MenuReader.read(pid: pid) }.value
            guard !Task.isCancelled, let model else { return }
            model.appGroups = groups
            model.loading = false
            self?.cache = (pid, Date(), groups)
        }
    }

    /// Every enabled module's bound shortcuts, by utility.
    static func macToysGroups() -> [ShortcutGroup] {
        let registry = ModuleRegistry.shared
        return registry.modules
            .filter { registry.isEnabled($0.info.id) }
            .sorted { $0.info.name < $1.info.name }
            .compactMap { module in
                let items = module.shortcutBindings.filter { !$0.keys.isEmpty }.map { ShortcutItem($0.title, $0.keys) }
                return items.isEmpty ? nil : ShortcutGroup(module.info.name, items)
            }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, let panel = self.panel, event.window === panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            switch Int(event.keyCode) {
            case kVK_Escape:
                if !model.query.isEmpty { model.query = "" } else { self.close() }
                return nil
            case kVK_ANSI_F where mods == .command: model.searchFocusRequest += 1; return nil
            case kVK_ANSI_1 where mods == .command: model.tab = .app; return nil
            case kVK_ANSI_2 where mods == .command: model.tab = .macOS; return nil
            case kVK_ANSI_3 where mods == .command: model.tab = .macToys; return nil
            default:
                return event
            }
        }
    }
}

/// Clicks work on the first press even though the panel isn't key or MacToys isn't active.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
