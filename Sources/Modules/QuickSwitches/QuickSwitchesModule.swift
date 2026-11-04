import AppKit
import MacToysCore
import SwiftUI

/// Quick Switches: hide desktop icons, show hidden files, connect AirPods and more, from the menu bar.
@MainActor
public final class QuickSwitchesModule: ToyModule {
    public let info = ModuleInfo(
        id: "switches", name: "Quick Switches",
        summary: "Hide desktop icons, show hidden files, connect AirPods and more, from the menu bar.",
        symbol: "switch.2", tint: .blue, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["toggle", "switch", "desktop icons", "hidden files", "dock", "menu bar", "dark mode", "bluetooth", "airpods",
                   "microphone", "mute", "screen saver", "lock", "trash", "low power", "do not disturb", "focus", "clean keyboard"])

    let settings: Persisted<SwitchesSettings>
    let engine: SwitchEngine
    private var running = false
    private var registeredHotkeys: Set<String> = []

    public convenience init() {
        self.init(store: .shared)
    }

    init(store: SettingsStore) {
        settings = Persisted("switches", default: SwitchesSettings(), store: store)
        engine = SwitchEngine(settings: settings)
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkeys()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
    }

    public func stop() {
        guard running else { return }
        running = false
        for id in registeredHotkeys { HotkeyCenter.shared.unregister(id) }
        registeredHotkeys.removeAll()
        engine.cleaner.stop()
        settings.flush()
    }

    /// One hotkey per enabled switch that has a shortcut.
    private func registerHotkeys() {
        let s = settings.value
        var wanted: Set<String> = []
        for kind in SwitchKind.allCases where s.isEnabled(kind) {
            guard let shortcut = s.shortcut(kind) else { continue }
            let id = "switches.\(kind.rawValue)"
            wanted.insert(id)
            HotkeyCenter.shared.register(id, shortcut) { [weak self] in self?.engine.activate(kind) }
        }
        for id in registeredHotkeys.subtracting(wanted) { HotkeyCenter.shared.unregister(id) }
        registeredHotkeys = wanted
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(SwitchesSettingsView(module: self))
    }

    /// Toggles as switches in the flyout (their state is read when it opens); actions as tiles.
    public var quickActions: [QuickAction] {
        let s = settings.value
        var out: [QuickAction] = []
        for kind in SwitchKind.allCases where s.isEnabled(kind) {
            if kind == .bluetooth {
                for d in engine.devices() {
                    out.append(QuickAction(id: "switches.bt.\(d.id)", title: d.name, symbol: d.kind.symbol, tint: .blue,
                                           isOn: { [weak self] in self?.engine.bluetooth.isConnected(d.id) ?? false },
                                           detail: { [weak self] in
                                               guard let self else { return "" }
                                               if self.engine.isConnecting(d.id) { return String(localized: "Connecting…") }
                                               return self.engine.bluetooth.isConnected(d.id) ? String(localized: "Connected", comment: "Bluetooth device state")
                                                   : String(localized: "Not connected", comment: "Bluetooth device state")
                                           },
                                           perform: { [weak self] in
                                               guard let self else { return }
                                               self.engine.setDevice(d.id, connected: !self.engine.bluetooth.isConnected(d.id))
                                           }))
                }
                continue
            }
            if kind.isToggle {
                // A second line only where there is something to say (otherwise the flyout row stays one line).
                let hasDetail = kind == .muteMicrophone || kind == .doNotDisturb || s.shortcut(kind) != nil
                var detail: (@MainActor () -> String)?
                if hasDetail {
                    detail = { [weak self] in
                        guard let self else { return "" }
                        return self.engine.detail(kind) ?? self.settings.value.shortcut(kind)?.description ?? ""
                    }
                }
                out.append(QuickAction(id: "switches.\(kind.rawValue)", title: kind.title, symbol: kind.symbol, tint: kind.tint,
                                       shortcut: s.shortcut(kind),
                                       isOn: { [weak self] in self?.engine.isOn(kind) ?? false },
                                       detail: detail,
                                       perform: { [weak self] in self?.engine.activate(kind) }))
            } else {
                out.append(QuickAction(id: "switches.\(kind.rawValue)", title: kind.title, symbol: kind.symbol, tint: kind.tint,
                                       shortcut: s.shortcut(kind), perform: { [weak self] in self?.engine.perform(kind) }))
            }
        }
        return out
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return SwitchKind.allCases.filter { s.isEnabled($0) && s.shortcut($0) != nil }
            .map { ShortcutBinding($0.title, s.shortcut($0)) }
            + [ShortcutBinding("Stop Clean Keyboard early", keys: ["esc", "esc", "esc"])]
    }

    /// `mactoys://switches/<switch>` toggles a switch or runs an action; `?on=true|false` sets it.
    /// Switch names: `desktop-icons`, `hidden-files`, `dock`, `menu-bar`, `dark-mode`, `keep-awake`, `microphone`,
    /// `do-not-disturb`, `low-power`, `screen-saver`, `lock`, `empty-trash`, `clean-keyboard?seconds=30`,
    /// `bluetooth?device=<address>&on=…`; plus `open`/`settings`.
    public func handle(_ command: AppCommand) -> Bool {
        let p = command.parameters
        let on = p["on"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) }
        switch command.action {
        case "open", "settings", "show":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        case "bluetooth":
            guard let address = p["device"] else { return false }
            engine.setDevice(address, connected: on ?? !engine.bluetooth.isConnected(address))
            return true
        case "clean-keyboard":
            if let seconds = p["seconds"].flatMap(Int.init) {
                engine.cleaner.start(seconds: min(max(seconds, SwitchesSettings.cleanRange.lowerBound), SwitchesSettings.cleanRange.upperBound))
            } else {
                engine.perform(.cleanKeyboard)
            }
            return true
        default:
            guard let kind = Self.kind(forAction: command.action) else { return false }
            if let on, kind.isToggle { engine.set(kind, on: on) } else { engine.activate(kind) }
            return true
        }
    }

    nonisolated static let actionNames: [SwitchKind: String] = [
        .hideDesktopIcons: "desktop-icons", .showHiddenFiles: "hidden-files", .autohideDock: "dock", .autohideMenuBar: "menu-bar",
        .darkMode: "dark-mode", .keepAwake: "keep-awake", .muteMicrophone: "microphone", .doNotDisturb: "do-not-disturb",
        .lowPowerMode: "low-power", .bluetooth: "bluetooth", .screenSaver: "screen-saver", .lockScreen: "lock",
        .emptyTrash: "empty-trash", .cleanKeyboard: "clean-keyboard",
    ]

    nonisolated static func kind(forAction action: String) -> SwitchKind? {
        actionNames.first { $0.value == action }?.key ?? SwitchKind(rawValue: action)
    }

    public var previewScenes: [PreviewScene] { SwitchesScenes.all }
}
