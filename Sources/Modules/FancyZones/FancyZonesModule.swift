import AppKit
import MacToysCore
import SwiftUI

/// FancyZones: per-display zone layouts, snapping by dragging with ⇧ held or with ⌃⌥ arrows,
/// a full-screen layout editor and quick layout switching.
///
/// URL actions (`mactoys://fancyzones/<action>`):
/// - `editor` (also `open`, `show`), `close` — the layout editor
/// - `apply?layout=<quick key | id | name>[&display=<n>]` — apply a layout to the active (or n-th) display
/// - `move?direction=left|right|up|down`, `extend?direction=…` — keyboard snapping of the focused window
/// - `snap?zone=<n>` — snap the focused window to zone n (1-based)
/// - `settings`
@MainActor
public final class FancyZonesModule: ToyModule {
    public let info = ModuleInfo(
        id: "fancyzones", name: "FancyZones",
        summary: "Create window layouts and snap windows into zones by dragging with ⇧ held, or with the keyboard.",
        symbol: "rectangle.3.group.fill", tint: .blue, category: .windowing,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["zones", "layout", "snap", "tile", "grid", "window manager", "editor"])

    let settings = Persisted("fancyzones", default: FancyZonesSettings())
    let layouts = Persisted(LayoutLibrary.storageID, default: LayoutLibrary())
    let history = Persisted("app-zone-history", default: [String: ZoneHistoryEntry](),
                            store: SettingsStore(directory: Paths.data(for: "fancyzones")))

    lazy var engine = ZoneEngine(settings: settings, library: layouts, history: history)
    private lazy var drag = DragSnapper(engine: engine)
    private lazy var watcher = NewWindowWatcher(engine: engine)
    private lazy var editor = EditorController(engine: engine)
    private var running = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var screenWork: DispatchWorkItem?
    private var listeningForPermissions = false
    private var registeredHotkeys: [String: Shortcut] = [:]
    private var registeredQuickKeys: [Int] = []

    public init() {
        let repaired = layouts.value.normalized()
        if repaired != layouts.value { layouts.value = repaired }
        settings.onChange { [weak self] _ in self?.settingsChanged() }
        layouts.onChange { [weak self] library in
            self?.registerQuickKeys()
            self?.editor.libraryChanged(library)
        }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        engine.onLayoutChange = { [weak self] display in self?.drag.layoutChanged(on: display) }
        drag.start()
        syncWatcher()
        registerHotkeys()
        Services.snapFocusedWindowToZone = { [weak self] index in self?.engine.snapFocusedWindow(toZone: index) }

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.screensChanged()
        }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) { [weak self] in
            guard let self else { return }
            self.settings.reload()
            self.layouts.reload()
            let repaired = self.layouts.value.normalized()
            if repaired != self.layouts.value { self.layouts.value = repaired }
        }
        if !listeningForPermissions {
            listeningForPermissions = true
            PermissionCenter.shared.onChange { [weak self] granted in
                guard let self, self.running, granted.contains(.accessibility) else { return }
                self.watcher.rewatchAll()
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        drag.stop()
        watcher.stop()
        editor.close()
        HotkeyCenter.shared.unregister(prefix: "fancyzones.")
        registeredHotkeys = [:]
        registeredQuickKeys = []
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        screenWork?.cancel()
        screenWork = nil
        engine.onLayoutChange = nil
        engine.reset()
        Services.snapFocusedWindowToZone = nil
        layouts.flush()
        history.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    private func settingsChanged() {
        guard running else { return }
        registerHotkeys()
        syncWatcher()
    }

    private func syncWatcher() {
        let s = settings.value
        if s.moveNewWindowsToLastZone || s.moveNewWindowsToActiveDisplay { watcher.start() } else { watcher.stop() }
    }

    /// Display arrangement, resolution or Dock size changed: rebuild overlays, keep windows in zones.
    private func screensChanged() {
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.engine.overlay.tearDown()
            self.editor.close()
            if self.settings.value.keepWindowsOnDisplayChange { self.engine.refitAll() }
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Hotkeys

    /// Every bound shortcut except quick layout keys, by hotkey id.
    private func desiredHotkeys() -> [String: Shortcut] {
        let s = settings.value
        var map: [String: Shortcut] = [:]
        map["fancyzones.editor"] = s.editorShortcut
        if s.moveWithKeyboard {
            // Zone-index mode only takes ← and →, leaving ↑ and ↓ to the apps (as PowerToys does).
            for d in ZoneDirection.allCases where s.moveMode == .relativePosition || d == .left || d == .right {
                map["fancyzones.move.\(d.rawValue)"] = s.moveShortcut(d)
                if s.moveMode == .relativePosition { map["fancyzones.extend.\(d.rawValue)"] = s.extendShortcut(d) }
            }
        }
        if s.switchWindowsInZone {
            map["fancyzones.next-window"] = s.nextWindowShortcut
            map["fancyzones.previous-window"] = s.previousWindowShortcut
        }
        return map
    }

    /// Registers what changed since last time (settings change often while a slider moves).
    private func registerHotkeys() {
        let wanted = running ? desiredHotkeys() : [:]
        if wanted != registeredHotkeys {
            let hk = HotkeyCenter.shared
            for id in registeredHotkeys.keys where wanted[id] == nil { hk.unregister(id) }
            for (id, shortcut) in wanted where registeredHotkeys[id] != shortcut {
                hk.register(id, shortcut) { [weak self] in self?.hotkeyPressed(id) }
            }
            registeredHotkeys = wanted
        }
        registerQuickKeys()
    }

    private func hotkeyPressed(_ id: String) {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return }
        let direction = parts.count > 2 ? ZoneDirection(rawValue: parts[2]) : nil
        switch parts[1] {
        case "editor": editor.toggle()
        case "move": if let direction { withAccessibility { $0.engine.moveFocusedWindow(direction) } }
        case "extend": if let direction { withAccessibility { $0.engine.extendFocusedWindow(direction) } }
        case "next-window": withAccessibility { $0.engine.cycleWindowsInZone(forward: true) }
        case "previous-window": withAccessibility { $0.engine.cycleWindowsInZone(forward: false) }
        default: break
        }
    }

    /// ⌃⌥⇧<n> for every layout with a quick key (only those, so other apps keep the rest).
    /// Skips the work when the set of keys is unchanged (assignments change the library often).
    private func registerQuickKeys() {
        let keys = running && settings.value.quickLayoutSwitch ? layouts.value.all.compactMap(\.quickKey).sorted() : []
        guard keys != registeredQuickKeys else { return }
        let hk = HotkeyCenter.shared
        hk.unregister(prefix: "fancyzones.quick.")
        registeredQuickKeys = keys
        for key in keys {
            hk.register("fancyzones.quick.\(key)", quickLayoutShortcut(key)) { [weak self] in
                self?.engine.applyQuickKey(key)
            }
        }
    }

    private func withAccessibility(_ action: (FancyZonesModule) -> Void) {
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        action(self)
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(FancyZonesSettingsView(module: self))
    }

    /// Opens the layout editor.
    public func openEditor() { editor.open() }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "fancyzones.editor", title: "Launch layout editor", symbol: "rectangle.3.group",
                     tint: .blue, shortcut: settings.value.editorShortcut) { [weak self] in self?.openEditor() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Launch layout editor", s.editorShortcut),
                    ShortcutBinding("Snap a window into zones", keys: s.holdShiftToActivate ? ["Hold", "⇧", "Drag"] : ["Drag"]),
                    ShortcutBinding("Span several zones while dragging", keys: ["Hold", "⌘"])]
        if s.moveWithKeyboard {
            for d in ZoneDirection.allCases where s.moveMode == .relativePosition || d == .left || d == .right {
                list.append(ShortcutBinding("Move window to the zone \(Self.arrowName(d))", s.moveShortcut(d)))
            }
            if s.moveMode == .relativePosition {
                for d in ZoneDirection.allCases {
                    list.append(ShortcutBinding("Extend window to the zone \(Self.arrowName(d))", s.extendShortcut(d)))
                }
            }
        }
        if s.switchWindowsInZone {
            list.append(ShortcutBinding("Next window in zone", s.nextWindowShortcut))
            list.append(ShortcutBinding("Previous window in zone", s.previousWindowShortcut))
        }
        if s.quickLayoutSwitch {
            for l in layouts.value.all.filter({ $0.quickKey != nil }).sorted(by: { ($0.quickKey ?? 0) < ($1.quickKey ?? 0) }) {
                if let k = l.quickKey { list.append(ShortcutBinding("Apply layout \(k) · \(l.name)", quickLayoutShortcut(k))) }
            }
        }
        return list
    }

    private static func arrowName(_ d: ZoneDirection) -> String {
        switch d {
        case .left: "on the left"
        case .right: "on the right"
        case .up: "above"
        case .down: "below"
        }
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "editor", "open", "show":
            // The editor belongs to a running FancyZones; when it's off, show its settings instead.
            if running { openEditor() } else { ModuleRegistry.shared.showSettings?(info.id) }
            return true
        case "close":
            editor.close()
            return true
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        case "apply":
            guard let query = command.parameters["layout"], let layout = layouts.value.resolve(query) else { return false }
            let displays = engine.displays
            let target = command.parameters["display"].flatMap(Int.init).flatMap { n in displays.first { $0.number == n } }
                ?? engine.activeDisplay()
            guard let target else { return false }
            engine.apply(layout, to: target, announce: running)   // no overlays while FancyZones is off
            return true
        case "move", "extend":
            guard running, let d = command.parameters["direction"].flatMap(ZoneDirection.init(rawValue:)) else { return false }
            withAccessibility { command.action == "move" ? $0.engine.moveFocusedWindow(d) : $0.engine.extendFocusedWindow(d) }
            return true
        case "snap":
            guard running, let n = command.parameters["zone"].flatMap(Int.init), n >= 1 else { return false }
            withAccessibility { $0.engine.snapFocusedWindow(toZone: n - 1) }
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { FancyZonesPreviews.scenes }
}
