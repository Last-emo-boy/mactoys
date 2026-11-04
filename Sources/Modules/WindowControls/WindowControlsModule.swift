import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Window Controls: move and resize windows from the green title-bar button (a palette with a
/// resize grid and presets), from the keyboard (⌃⌥K), with custom controls and with saved layouts
/// that come back when a display arrangement returns.
///
/// URL actions (`mactoys://windowcontrols/<action>`):
/// - `keyboard` — keyboard mode for the focused window
/// - `control?name=<name or id>` — run a custom control on the focused window
/// - `save-layout[?name=…]` — save the windows on screen as a layout
/// - `restore-layout?name=<name or id>` — restore a saved layout (without a name: the newest one
///   for the displays connected now)
/// - `controls` — the custom controls editor; `open`, `settings` — the settings page
@MainActor
public final class WindowControlsModule: ToyModule {
    public let info = ModuleInfo(
        id: "windowcontrols", name: "Window Controls",
        summary: "Move and resize windows from the green button, the keyboard, or saved layouts you restore in one click.",
        symbol: "macwindow.on.rectangle", tint: .green, category: .windowing,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["window", "resize", "move", "zoom button", "green button", "halves", "thirds", "grid", "layout",
                   "snapshot", "keyboard", "displays"])

    let settings = Persisted("windowcontrols", default: WindowControlsSettings())
    let editorState = ControlsEditorState()

    private lazy var mover = WindowMover(settings: settings)
    private lazy var watcher = ZoomButtonWatcher()
    private lazy var palette = PaletteController(settings: settings, mover: mover)
    private lazy var keyboard = KeyboardMode(settings: settings, mover: mover)
    private lazy var automation = LayoutAutomation(settings: settings)
    private var editorWindow: HostedToolWindow?
    private var running = false
    private var registered: [String: Shortcut] = [:]
    private var externalObserver: NSObjectProtocol?
    private let log = Log.for("windowcontrols")

    public init() {
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        watcher.onHover = { [weak self] hit in self?.palette.show(for: hit) }
        watcher.onDoubleClick = { [weak self] hit in
            guard let self else { return }
            self.palette.hide()
            self.mover.toggleFill(hit.window)
        }
        watcher.isPaused = { [weak self] in self?.palette.isVisible ?? true }
        mover.onMove = { [weak self] _, _ in self?.automation.windowsMoved() }
        automation.restore = { [weak self] layout in self?.restore(layout, announce: true) }
        automation.start()
        syncWatcher()
        registerHotkeys()
        externalObserver = DistributedNotificationCenter.default().addObserver(
            forName: SettingsStore.externalChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.reload() }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        palette.tearDown()
        keyboard.tearDown()
        automation.stop()
        mover.onMove = nil
        mover.reset()
        HotkeyCenter.shared.unregister(prefix: "windowcontrols.")
        registered = [:]
        if let externalObserver { DistributedNotificationCenter.default().removeObserver(externalObserver) }
        externalObserver = nil
        editorWindow?.close()
        settings.flush()
    }

    private func settingsChanged() {
        guard running else { return }
        syncWatcher()
        registerHotkeys()
        automation.sync()
    }

    private func syncWatcher() {
        let s = settings.value
        watcher.configure(hover: s.paletteEnabled, doubleClick: s.doubleClickFills, delay: s.hoverDelay,
                          excluded: s.excludedApps)
        if !s.paletteEnabled { palette.hide() }
    }

    // MARK: Hotkeys

    private func desiredHotkeys() -> [String: Shortcut] {
        let s = settings.value
        var map: [String: Shortcut] = [:]
        map["windowcontrols.keyboard"] = s.keyboardShortcut
        map["windowcontrols.save-layout"] = s.saveLayoutShortcut
        map["windowcontrols.restore-layout"] = s.restoreLayoutShortcut
        for c in s.controls { map["windowcontrols.control.\(c.id.uuidString)"] = c.shortcut }
        return map
    }

    /// Registers only what changed (settings change often while a slider moves).
    private func registerHotkeys() {
        let wanted = running ? desiredHotkeys() : [:]
        guard wanted != registered else { return }
        let hk = HotkeyCenter.shared
        for id in registered.keys where wanted[id] == nil { hk.unregister(id) }
        for (id, shortcut) in wanted where registered[id] != shortcut {
            hk.register(id, shortcut) { [weak self] in self?.hotkeyPressed(id) }
        }
        registered = wanted
    }

    private func hotkeyPressed(_ id: String) {
        switch id {
        case "windowcontrols.keyboard": keyboard.toggle()
        case "windowcontrols.save-layout": saveLayout(name: nil)
        case "windowcontrols.restore-layout": restoreCurrentArrangement()
        default:
            let prefix = "windowcontrols.control."
            guard id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))),
                  let control = settings.value.controls.first(where: { $0.id == uuid }) else { return }
            run(control)
        }
    }

    // MARK: Actions

    private func requireAccessibility() -> Bool {
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return false
        }
        return true
    }

    /// Opens keyboard mode for the focused window.
    func enterKeyboardMode() {
        guard running else { return HUD.show("Window Controls is off", symbol: info.symbol) }
        keyboard.enter()
    }

    /// Runs a control on the focused window.
    func run(_ control: WindowControl) {
        guard running else { return HUD.show("Window Controls is off", symbol: info.symbol) }
        guard requireAccessibility() else { return }
        guard let w = WindowMover.focusedWindow(), mover.canArrange(w) else {
            return HUD.show("No window to arrange", symbol: "macwindow")
        }
        mover.run(control, on: w)
    }

    /// Saves the windows on screen as a new layout.
    func saveLayout(name: String?) {
        guard requireAccessibility() else { return }
        let s = settings.value
        let n = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? nextLayoutName()
        let layout = LayoutCapture.snapshot(name: n, excluded: s.excludedApps, accessibility: true)
        guard !layout.windows.isEmpty else {
            return HUD.show("No windows to save", symbol: "rectangle.dashed")
        }
        settings.value.layouts.append(layout)
        HUD.show(String(localized: "Saved “\(n)” · \(layout.windows.count) windows",
                        comment: "HUD after saving a window layout; %@ is its name, %lld the number of windows"),
                 symbol: "square.and.arrow.down")
    }

    /// Replaces a layout's windows with the windows on screen now (keeping its name and options).
    func updateLayout(_ id: UUID) {
        guard requireAccessibility(), let i = settings.value.layouts.firstIndex(where: { $0.id == id }) else { return }
        let old = settings.value.layouts[i]
        var fresh = LayoutCapture.snapshot(name: old.name, excluded: settings.value.excludedApps, accessibility: true)
        guard !fresh.windows.isEmpty else { return HUD.show("No windows to save", symbol: "rectangle.dashed") }
        fresh.id = old.id
        fresh.autoRestore = old.autoRestore
        settings.value.layouts[i] = fresh
        HUD.show("Updated “\(old.name)”", symbol: "square.and.arrow.down")
    }

    func restoreLayout(_ id: UUID) {
        guard let layout = settings.value.layouts.first(where: { $0.id == id }) else { return }
        restore(layout, announce: true)
    }

    /// Restores the newest layout saved for the displays connected now.
    func restoreCurrentArrangement() {
        let key = DisplayArrangement.key(Screens.layoutDisplays())
        guard let layout = settings.value.newestLayout(for: key) else {
            return HUD.show("No layout saved for these displays", symbol: "rectangle.dashed")
        }
        restore(layout, announce: true)
    }

    private func restore(_ layout: SavedLayout, announce: Bool) {
        guard running else { return HUD.show("Window Controls is off", symbol: info.symbol) }
        guard requireAccessibility() else { return }
        let result = LayoutCapture.restore(layout, mover: mover, excluded: settings.value.excludedApps)
        log.info("Restored \(layout.name, privacy: .public): \(result.moved) moved, \(result.missing) missing, \(result.tiled) tiled")
        guard announce else { return }
        if result.moved == 0 && result.tiled > 0 {
            HUD.show("Auto Tiling arranges these displays", symbol: "rectangle.split.2x2")
        } else if result.moved == 0 {
            HUD.show(String(localized: "None of the windows in “\(layout.name)” are open",
                            comment: "HUD: restoring a layout found none of its windows; %@ is the layout name"),
                     symbol: "rectangle.dashed")
        } else {
            HUD.show(String(localized: "Restored “\(layout.name)” · \(result.moved) windows",
                            comment: "HUD after restoring a layout; %@ is its name, %lld the number of windows moved"),
                     symbol: "rectangle.3.group")
        }
    }

    func deleteLayout(_ id: UUID) {
        settings.value.layouts.removeAll { $0.id == id }
    }

    private func nextLayoutName() -> String {
        var n = settings.value.layouts.filter { !$0.isAutomatic }.count + 1
        func name(_ n: Int) -> String {
            String(localized: "Layout \(n)", comment: "Default name of a saved window layout; %lld is a number")
        }
        while settings.value.layouts.contains(where: { $0.name == name(n) }) { n += 1 }
        return name(n)
    }

    // MARK: Controls editor

    func openControlsEditor(selecting id: UUID? = nil) {
        if let id { editorState.selection = id }
        if editorState.selection == nil { editorState.selection = settings.value.controls.first?.id }
        if let editorWindow {
            editorWindow.show()
            return
        }
        let window = HostedToolWindow(title: String(localized: "Custom Controls", comment: "Window title: the Window Controls editor"),
                                      size: CGSize(width: 860, height: 600), minSize: CGSize(width: 760, height: 480),
                                      autosaveName: "WindowControlsEditor",
                                      content: ControlsEditorView(settings: settings, state: editorState))
        window.onClose = { [weak self] in self?.editorWindow = nil }
        editorWindow = window
        window.show()
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView { AnyView(WindowControlsSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        let s = settings.value
        var actions = [
            QuickAction(id: "windowcontrols.keyboard", title: "Keyboard Mode", symbol: "keyboard", tint: info.tint,
                        shortcut: s.keyboardShortcut) { [weak self] in self?.enterKeyboardMode() },
            QuickAction(id: "windowcontrols.save-layout", title: "Save Window Layout", symbol: "square.and.arrow.down",
                        tint: info.tint, shortcut: s.saveLayoutShortcut) { [weak self] in self?.saveLayout(name: nil) },
        ]
        for layout in s.layouts {
            actions.append(QuickAction(id: "windowcontrols.restore.\(layout.id.uuidString)",
                                       title: String(localized: "Restore \(layout.name)",
                                                     comment: "Quick action: restore the window layout with this name"),
                                       symbol: "rectangle.3.group", tint: info.tint) { [weak self] in
                self?.restoreLayout(layout.id)
            })
        }
        return actions
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Arrange windows from the keyboard", s.keyboardShortcut)]
        if let sc = s.saveLayoutShortcut { list.append(ShortcutBinding("Save the window layout", sc)) }
        if let sc = s.restoreLayoutShortcut { list.append(ShortcutBinding("Restore the layout for these displays", sc)) }
        for c in s.controls {
            if let sc = c.shortcut { list.append(ShortcutBinding(c.displayName, sc)) }
        }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "keyboard":
            enterKeyboardMode()
        case "control":
            guard let query = command.parameters["name"] ?? command.parameters["id"],
                  let control = settings.value.control(named: query) else {
                HUD.show(String(localized: "No control named “\(command.parameters["name"] ?? "")”",
                                comment: "HUD: a URL asked for a custom control that doesn't exist; %@ is the name"),
                         symbol: "questionmark.square.dashed")
                return true
            }
            run(control)
        case "save-layout":
            guard running else { HUD.show("Window Controls is off", symbol: info.symbol); return true }
            saveLayout(name: command.parameters["name"])
        case "restore-layout":
            guard let query = command.parameters["name"] ?? command.parameters["id"] else {
                restoreCurrentArrangement()
                return true
            }
            guard let layout = settings.value.layout(named: query) else {
                HUD.show(String(localized: "No layout named “\(query)”",
                                comment: "HUD: a URL asked for a saved layout that doesn't exist; %@ is the name"),
                         symbol: "questionmark.square.dashed")
                return true
            }
            restore(layout, announce: true)
        case "controls", "editor":
            openControlsEditor()
        case "open", "show", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] { WindowControlsPreviews.scenes }
}
