import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Auto Tiling: every standard window that opens is placed into its display's layout at once;
/// when one closes, minimizes or hides, the others re-flow. Grid, Columns, Rows and Side layouts
/// per display, stacks when a display is full, drag to swap, minimum-size learning, highlight
/// borders, and Focus, No peek, Clean Space and Tab View.
///
/// URL actions (`mactoys://autotile/<action>`): `pause`, `resume`, `toggle`, `retile`,
/// `layout?kind=grid|columns|rows|side[&display=N]`, `make-main`, `swap?dir=left|right|up|down`,
/// `float`, `next-in-stack`, `previous-in-stack`, `send-to-display`, `focus`, `no-peek`,
/// `clean-space`, `tab-view`, `settings`.
@MainActor
public final class AutoTilingModule: ToyModule {
    public let info = ModuleInfo(
        id: "autotile", name: "Auto Tiling",
        summary: "Tile every window automatically as it opens, with a layout for each display.",
        symbol: "rectangle.split.2x2.fill", tint: .indigo, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["tiling", "tile", "window manager", "layout", "grid", "columns", "rows", "stack", "focus",
                   "no peek", "clean space", "tab view", "gaps", "aerospace", "yabai"])

    let settings = Persisted("autotile", default: AutoTilingSettings())
    /// Minimum window sizes learned per app; kept on this Mac only.
    let learned = Persisted("minimum-sizes", default: [String: LearnedSize](),
                            store: SettingsStore(directory: Paths.data(for: "autotile")))

    lazy var engine = TilingEngine(settings: settings, learned: learned)
    private lazy var mouse = MouseController(engine: engine)
    private lazy var tabView = TabSwitcher(engine: engine)
    private var running = false
    private var lastSettings: AutoTilingSettings
    private var registered: [String: Shortcut] = [:]
    private var listeningForPermissions = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {
        lastSettings = settings.value
        settings.onChange { [weak self] new in self?.settingsChanged(new) }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        engine.onLayout = { [weak self] in self?.mouse.layoutChanged() }
        Services.autoTilingManagesDisplay = { [weak self] id in self?.engine.manages(displayID: id) ?? false }
        engine.start()
        mouse.start(settings.value)
        tabView.configure(shortcut: settings.value.keyboardShortcuts ? settings.value.tabViewShortcut : nil, running: true)
        registerHotkeys()
        let token = DistributedNotificationCenter.default().addObserver(
            forName: SettingsStore.externalChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.reload() }
        }
        observers.append((DistributedNotificationCenter.default(), token))
        if !listeningForPermissions {
            listeningForPermissions = true
            PermissionCenter.shared.onChange { [weak self] granted in
                guard let self, self.running, granted.contains(.accessibility) else { return }
                self.engine.accessibilityGranted()
            }
        }
        engine.publish()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "autotile.")
        registered = [:]
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tabView.stop()
        mouse.stop()
        engine.stop()
        engine.onLayout = nil
        Services.autoTilingManagesDisplay = nil
        settings.flush()
        learned.flush()
    }

    private func settingsChanged(_ new: AutoTilingSettings) {
        let old = lastSettings
        lastSettings = new
        engine.settingsChanged(from: old, to: new)
        guard running else { return }
        mouse.configure(new)
        tabView.configure(shortcut: new.keyboardShortcuts ? new.tabViewShortcut : nil, running: true)
        registerHotkeys()
    }

    // MARK: Hotkeys

    private func desiredHotkeys() -> [String: Shortcut] {
        let s = settings.value
        guard running, s.keyboardShortcuts else { return [:] }
        var map: [String: Shortcut?] = [:]
        for k in TileLayoutKind.allCases { map["autotile.layout.\(k.rawValue)"] = s.layoutShortcut(k) }
        for d in TileDirection.allCases { map["autotile.swap.\(d.rawValue)"] = s.swapShortcut(d) }
        map["autotile.pause"] = s.pauseShortcut
        map["autotile.main"] = s.makeMainShortcut
        map["autotile.stack.next"] = s.nextInStackShortcut
        map["autotile.stack.previous"] = s.previousInStackShortcut
        map["autotile.float"] = s.floatShortcut
        map["autotile.send"] = s.sendToDisplayShortcut
        map["autotile.focus"] = s.focusModeShortcut
        map["autotile.nopeek"] = s.noPeekShortcut
        map["autotile.clean"] = s.cleanSpaceShortcut
        return map.compactMapValues { $0 }
    }

    /// Registers only what changed (settings change often while a slider moves).
    private func registerHotkeys() {
        let wanted = desiredHotkeys()
        guard wanted != registered else { return }
        let hk = HotkeyCenter.shared
        for id in registered.keys where wanted[id] == nil { hk.unregister(id) }
        for (id, shortcut) in wanted where registered[id] != shortcut {
            hk.register(id, shortcut) { [weak self] in self?.hotkeyPressed(id) }
        }
        registered = wanted
    }

    private func hotkeyPressed(_ id: String) {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return }
        let command: TilingCommand?
        switch parts[1] {
        case "layout": command = parts.count > 2 ? TileLayoutKind(rawValue: parts[2]).map { .layout($0, display: nil) } : nil
        case "swap": command = parts.count > 2 ? TileDirection(rawValue: parts[2]).map { .swap($0) } : nil
        case "pause": command = .togglePause
        case "main": command = .makeMain
        case "stack": command = .cycleStack(forward: parts.count > 2 && parts[2] == "next")
        case "float": command = .toggleFloat
        case "send": command = .sendToNextDisplay
        case "focus": command = .focusMode
        case "nopeek": command = .noPeek
        case "clean": command = .cleanSpace
        default: command = nil
        }
        if let command { perform(command) }
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: TilingCommand) -> Bool {
        switch command {
        case .settings:
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        case .pause:
            setPaused(true)
            return true
        case .resume:
            setPaused(false)
            return true
        case .togglePause:
            setPaused(!settings.value.paused)
            return true
        case .layout(let kind, let number):
            var target: TileDisplay?
            if let number {
                guard let d = (engine.displays.isEmpty ? TileDisplay.current() : engine.displays).first(where: { $0.number == number })
                else { return false }
                target = d
            }
            if running && AXIsProcessTrusted() {
                engine.applyLayout(kind, on: target)
            } else if let d = target ?? TileDisplay.current().first(where: \.isMain) {
                // Off or without Accessibility: remember the choice for when tiling runs.
                settings.value.layouts[d.key, default: settings.value.defaultLayout].kind = kind
            }
            return true
        default:
            guard running else {
                HUD.show("Auto Tiling is off", symbol: info.symbol)
                return true
            }
            withAccessibility { engine in
                guard engine.isActive else {
                    HUD.show(engine.isStageManagerOn ? "Auto Tiling waits while Stage Manager is on" : "Auto Tiling is paused",
                             symbol: "pause.rectangle")
                    return
                }
                switch command {
                case .retile: engine.retileNow()
                case .makeMain: engine.makeMainFocused()
                case .swap(let d): engine.swapFocused(d)
                case .toggleFloat: engine.toggleFloat()
                case .cycleStack(let forward): engine.cycleStack(forward: forward)
                case .sendToNextDisplay: engine.sendToNextDisplay()
                case .focusMode: engine.toggleFocusMode()
                case .noPeek: engine.toggleNoPeek()
                case .cleanSpace: engine.toggleCleanSpace()
                case .tabView: tabView.show(hold: [])
                default: break
                }
            }
            return true
        }
    }

    func setPaused(_ paused: Bool) {
        guard settings.value.paused != paused else { return }
        settings.value.paused = paused
        guard running else { return }
        if paused {
            HUD.show("Auto Tiling paused", symbol: "pause.rectangle")
        } else if engine.isStageManagerOn {
            HUD.show("Auto Tiling resumes when Stage Manager is off", symbol: "pause.rectangle")
        } else {
            HUD.show("Auto Tiling resumed", symbol: "rectangle.split.2x2")
        }
    }

    private func withAccessibility(_ action: (TilingEngine) -> Void) {
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        if !engine.isRunning { engine.start() }
        action(engine)
    }

    /// The app the "Tile <app>" switch is about: the frontmost one other than MacToys.
    var subjectApp: NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return app
        }
        return engine.lastExternalApp
    }

    func isTiled(app: NSRunningApplication) -> Bool {
        !AppList.contains(settings.value.excludedApps, bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
    }

    func setTiled(_ on: Bool, app: NSRunningApplication) {
        let name = app.localizedName ?? ""
        if on {
            settings.value.excludedApps = AppList.removing(settings.value.excludedApps, bundleID: app.bundleIdentifier, name: name)
        } else if isTiled(app: app) {
            settings.value.excludedApps.append(app.bundleIdentifier ?? name)
        }
    }

    /// One line for the menu bar switch.
    var statusLine: String {
        guard running else { return String(localized: "Off", comment: "Auto Tiling status: the utility is turned off") }
        guard AXIsProcessTrusted() else { return String(localized: "Needs Accessibility access") }
        if engine.isStageManagerOn { return String(localized: "Paused while Stage Manager is on") }
        if settings.value.paused { return String(localized: "Windows stay where they are") }
        guard let d = engine.status.mainDisplay ?? engine.status.displays.first else { return "" }
        let count = d.tiles.count
        return String(localized: "\(d.kind.title) · \(count) windows",
                      comment: "Auto Tiling status: the main display's layout name, then how many windows it tiles")
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView { AnyView(AutoTilingSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        let s = settings.value
        var list = [QuickAction(id: "autotile.pause", title: "Pause tiling", symbol: "pause.rectangle", tint: info.tint,
                                shortcut: s.pauseShortcut,
                                isOn: { [weak self] in self?.settings.value.paused ?? false },
                                detail: { [weak self] in self?.statusLine ?? "" },
                                perform: { [weak self] in self?.perform(.togglePause) })]
        if running, let app = subjectApp, let name = app.localizedName {
            list.append(QuickAction(id: "autotile.app", title: String(localized: "Tile \(name)", comment: "Menu bar switch; %@ is the frontmost app"),
                                    symbol: "macwindow", tint: info.tint,
                                    isOn: { [weak self] in self?.isTiled(app: app) ?? true },
                                    detail: { [weak self] in
                                        (self?.isTiled(app: app) ?? true)
                                            ? String(localized: "Its windows join the layout")
                                            : String(localized: "Its windows are left alone")
                                    },
                                    perform: { [weak self] in
                                        guard let self else { return }
                                        self.setTiled(!self.isTiled(app: app), app: app)
                                    }))
        }
        for kind in TileLayoutKind.allCases {
            list.append(QuickAction(id: "autotile.layout.\(kind.rawValue)", title: kind.title, symbol: kind.symbol, tint: info.tint,
                                    shortcut: s.layoutShortcut(kind)) { [weak self] in self?.perform(.layout(kind, display: nil)) })
        }
        return list
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        let drag = String(localized: "Drag", comment: "Keycap label: drag a window with the mouse")
        let hold = String(localized: "Hold", comment: "Keycap label: hold down the keys that follow")
        var list: [ShortcutBinding] = []
        guard s.keyboardShortcuts else {
            return s.dragToSwap ? [ShortcutBinding("Swap two tiled windows", keys: [drag])] : []
        }
        for kind in TileLayoutKind.allCases {
            list.append(ShortcutBinding(String(localized: "Use the \(kind.title) layout", comment: "Shortcut list; %@ is a layout name"),
                                        s.layoutShortcut(kind)))
        }
        list.append(ShortcutBinding("Swap with the window on the left", s.swapLeft))
        list.append(ShortcutBinding("Swap with the window on the right", s.swapRight))
        list.append(ShortcutBinding("Swap with the window above", s.swapUp))
        list.append(ShortcutBinding("Swap with the window below", s.swapDown))
        list.append(ShortcutBinding("Make the focused window the main one", s.makeMainShortcut))
        list.append(ShortcutBinding("Pause or resume tiling", s.pauseShortcut))
        let optional: [(String, Shortcut?)] = [
            (String(localized: "Next window in the stack"), s.nextInStackShortcut),
            (String(localized: "Previous window in the stack"), s.previousInStackShortcut),
            (String(localized: "Float or tile the focused window"), s.floatShortcut),
            (String(localized: "Send the focused window to the next display"), s.sendToDisplayShortcut),
            (String(localized: "Focus: fill the display with one window"), s.focusModeShortcut),
            (String(localized: "No peek: darken the other windows"), s.noPeekShortcut),
            (String(localized: "Clean Space: hide everything else for sharing"), s.cleanSpaceShortcut),
        ]
        for (title, shortcut) in optional where shortcut != nil { list.append(ShortcutBinding(title, shortcut)) }
        if let t = s.tabViewShortcut {
            list.append(ShortcutBinding("Tab View: switch windows on a map", keys: [hold] + t.modifiers.symbols + [KeyCodes.name(for: t.keyCode)]))
        }
        if s.dragToSwap { list.append(ShortcutBinding("Swap two tiled windows", keys: [drag])) }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        guard let c = TilingCommand.parse(action: command.action, parameters: command.parameters) else { return false }
        return perform(c)
    }

    public var previewScenes: [PreviewScene] { AutoTilingPreviews.scenes(module: self) }
}
