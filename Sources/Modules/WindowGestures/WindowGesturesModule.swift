import AppKit
import MacToysCore
import SwiftUI

/// Window Gestures: two-finger swipes, pinches and double-taps on a window's title bar tile it to
/// halves, thirds, quarters and sixths, fill, restore, minimize, close or move it to another
/// display, with a live glass preview of the target and haptic feedback. Optional gestures on Dock
/// icons (show or hide the app) and on the menu bar (fill the front window).
///
/// URL actions (`mactoys://gestures/<action>`):
/// - `open` (also `show`, `settings`) — the settings page
/// - `cheatsheet` — show or hide the gesture cheat sheet
/// - `toggle[?on=true|false]` — pause or resume gestures (also `pause`, `resume`)
/// - `gesture?name=<swipe-left|swipe-right|swipe-up|swipe-down|swipe-left-up|…|display-left|…|pinch-in|pinch-out|double-tap>`
///   — apply a gesture to the focused window, as if made on its title bar
@MainActor
public final class WindowGesturesModule: ToyModule {
    public let info = ModuleInfo(
        id: "gestures", name: "Window Gestures",
        summary: "Swipe, pinch or double-tap on a title bar with two fingers to tile, fill, minimize, close or move a window.",
        symbol: "hand.draw.fill", tint: .cyan, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["gesture", "trackpad", "swipe", "pinch", "title bar", "snap", "tile", "halves", "thirds",
                   "quarters", "dock", "magic mouse"])

    let settings = Persisted("gestures", default: WindowGesturesSettings())
    private lazy var controller = GestureController(settings: settings)
    private let cheatSheet = CheatSheetController()
    private var running = false
    private var registeredShortcut: Shortcut?

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.controller.refreshConfig()
            self.registerHotkey()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        controller.start()
        registerHotkey()
    }

    public func stop() {
        guard running else { return }
        running = false
        controller.stop()
        cheatSheet.tearDown()
        HotkeyCenter.shared.unregister("gestures.cheatsheet")
        registeredShortcut = nil
        settings.flush()
    }

    private func registerHotkey() {
        let wanted = running ? settings.value.cheatSheetShortcut : nil
        guard wanted != registeredShortcut else { return }
        registeredShortcut = wanted
        HotkeyCenter.shared.register("gestures.cheatsheet", wanted) { [weak self] in self?.toggleCheatSheet() }
    }

    func showCheatSheet() {
        cheatSheet.show(GestureCatalog.entries(settings.value))
    }

    func toggleCheatSheet() {
        cheatSheet.toggle(GestureCatalog.entries(settings.value))
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(WindowGesturesSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "gestures.active", title: "Window Gestures", symbol: "hand.draw", tint: .cyan,
                     isOn: { [weak self] in self?.settings.value.active ?? false },
                     detail: { [weak self] in
                         self?.settings.value.active == true
                             ? String(localized: "Swipe or pinch on a title bar", comment: "Menu bar switch detail: Window Gestures is on")
                             : String(localized: "Paused", comment: "Menu bar switch detail: Window Gestures is off")
                     },
                     perform: { [weak self] in self?.settings.value.active.toggle() }),
         QuickAction(id: "gestures.cheatsheet", title: "Gestures", symbol: "hand.draw", tint: .cyan,
                     shortcut: settings.value.cheatSheetShortcut) { [weak self] in self?.showCheatSheet() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = GestureCatalog.bindings(s)
        if let shortcut = s.cheatSheetShortcut {
            list.insert(ShortcutBinding("Show the gesture cheat sheet", shortcut), at: 0)
        }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        case "cheatsheet", "cheat-sheet":
            toggleCheatSheet()
            return true
        case "toggle", "pause", "resume":
            let explicit = command.parameters["on"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) }
            let on = command.action == "pause" ? false : command.action == "resume" ? true : explicit ?? !settings.value.active
            settings.value.active = on
            HUD.show(on ? "Window Gestures on" : "Window Gestures paused", symbol: "hand.draw")
            return true
        case "gesture":
            guard running, let gesture = command.parameters["name"].flatMap(NamedGesture.init) else { return false }
            return controller.perform(gesture: gesture)
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { WindowGesturesPreviews.scenes(settings.value) }
}
