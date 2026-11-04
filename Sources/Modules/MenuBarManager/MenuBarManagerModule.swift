import AppKit
import MacToysCore
import SwiftUI

/// Menu Bar Manager: hides the menu bar icons you rarely need behind a divider and brings them back
/// with a click, a hover, a shortcut or a search — in the menu bar or in a separate bar below it.
///
/// Hiding uses only public API: a divider status item grows long enough to push every icon to its
/// left off the screen. Users arrange icons with macOS's own ⌘-drag. Turning the module off, quitting
/// or a crash removes the dividers, and everything comes back.
@MainActor
public final class MenuBarManagerModule: ToyModule {
    public let info = ModuleInfo(
        id: "menubar", name: "Menu Bar Manager",
        summary: "Hide the menu bar icons you rarely need and bring them back with a click, a hover or a shortcut.",
        symbol: "menubar.rectangle", tint: .cyan, category: .systemTools,
        permissions: [], enabledByDefault: false,
        keywords: ["menu bar", "status items", "hide icons", "notch", "clutter", "divider", "chevron", "tidy", "tint", "search"])

    let settings = Persisted("menubar", default: MenuBarSettings())
    /// Item and divider positions, kept apart from the settings (they change as the menu bar does).
    private lazy var hints = Persisted("hints", default: OrderHints(), store: SettingsStore(directory: Paths.data(for: "menubar")))
    private(set) lazy var controller = MenuBarController(settings: settings, hints: hints)
    private var running = false

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.controller.settingsChanged()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        controller.start()
    }

    public func stop() {
        guard running else { return }
        running = false
        controller.stop()
        settings.flush()
    }

    /// Asks for Accessibility when the user turns on something that needs it (search, the bar).
    func requestAccessibilityIfNeeded() {
        if !PermissionCenter.shared.isGranted(.accessibility) { PermissionCenter.shared.request(.accessibility) }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(MenuBarSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        var actions = [
            QuickAction(id: "menubar.toggle", title: "Hidden Menu Bar Icons", symbol: "menubar.arrow.up.rectangle", tint: .cyan,
                        shortcut: settings.value.toggleShortcut,
                        isOn: { [weak self] in self?.controller.state.revealed ?? false },
                        detail: { [weak self] in self?.quickDetail ?? "" },
                        perform: { [weak self] in self?.perform { $0.toggle() } }),
        ]
        if settings.value.searchEnabled {
            actions.append(QuickAction(id: "menubar.search", title: "Search Menu Bar", symbol: "magnifyingglass", tint: .cyan,
                                       shortcut: settings.value.searchShortcut,
                                       perform: { [weak self] in self?.perform { $0.showSearch() } }))
        }
        return actions
    }

    private var quickDetail: String {
        let state = controller.state
        guard state.isRunning, !state.items.isEmpty else { return "" }
        let hidden = state.count(.hidden)
        return state.revealed
            ? String(localized: "Showing \(hidden) icons", comment: "Quick action detail; the number counts hidden menu bar icons now shown")
            : String(localized: "\(hidden) icons hidden", comment: "Quick action detail; the number counts hidden menu bar icons")
    }

    public var shortcutBindings: [ShortcutBinding] {
        var b = [
            ShortcutBinding("Show or hide menu bar icons", settings.value.toggleShortcut),
            ShortcutBinding("Hide or show a menu bar icon",
                            keys: ["⌘", String(localized: "Drag", comment: "Keycap-style label: drag with the mouse")]),
        ]
        if settings.value.alwaysHiddenSection {
            b.append(ShortcutBinding("Show always-hidden menu bar icons", settings.value.alwaysHiddenShortcut))
            b.append(ShortcutBinding("Show always-hidden icons from the chevron",
                                     keys: ["⌥", String(localized: "Click", comment: "Keycap-style label: click with the mouse")]))
        }
        if settings.value.searchEnabled {
            b.append(ShortcutBinding("Search menu bar icons", settings.value.searchShortcut))
        }
        return b
    }

    /// `mactoys://menubar/<action>`:
    /// - `toggle`: shows or hides the hidden icons (`always=1` includes the always-hidden ones).
    /// - `show` (`reveal`), `hide` (`collapse`), `show-all` (both sections).
    /// - `search`: opens menu bar search.
    /// - `arrange`: opens the arrangement card; `reset`: puts the dividers back at the far left.
    /// - `open`/`settings`: the settings page.
    public func handle(_ command: AppCommand) -> Bool {
        let known = ["toggle", "show", "reveal", "hide", "collapse", "show-all", "search", "arrange", "reset", "open", "settings"]
        guard known.contains(command.action) else { return false }
        if command.action == "open" || command.action == "settings" {
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        }
        let always = ["1", "true", "yes", "on"].contains(command.parameters["always"]?.lowercased() ?? "")
        perform { c in
            switch command.action {
            case "toggle": c.toggle(alwaysHidden: always)
            case "show", "reveal": c.reveal(.manual, alwaysHidden: always)
            case "hide", "collapse": c.collapse()
            case "show-all": c.reveal(.manual, alwaysHidden: true)
            case "search": c.showSearch()
            case "arrange": c.beginArranging()
            case "reset": c.resetPositions()
            default: break
            }
        }
        return true
    }

    /// Runs an action, or explains that the module is off.
    private func perform(_ action: (MenuBarController) -> Void) {
        guard running else {
            HUD.show("Menu Bar Manager is turned off in MacToys settings", symbol: "menubar.rectangle")
            return
        }
        action(controller)
    }

    public var previewScenes: [PreviewScene] { MenuBarScenes.all }
}
