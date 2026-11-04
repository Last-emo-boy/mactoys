import AppKit
import MacToysCore
import SwiftUI

/// Charge Limit: keeps a MacBook's battery between limits to slow its aging. A small root helper
/// (installed on request, with one administrator prompt) switches charging; MacToys only reads.
@MainActor
public final class ChargeLimitModule: ToyModule {
    public let info = ModuleInfo(
        id: "chargelimit", name: "Charge Limit",
        summary: "Keep your MacBook's battery between limits you choose to slow its aging.",
        symbol: "battery.75percent", tint: .green, category: .advanced,
        permissions: [], enabledByDefault: false,
        keywords: ["battery", "charge", "limit", "health", "charging", "magsafe", "cycles", "calibration", "sailing"])

    let settings: Persisted<ChargeLimitSettings>
    let model: ChargeLimitModel
    let log = Log.for("chargelimit")

    private var running = false
    private var pollTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let powerWatcher = PowerSourceWatcher()
    private var pushWork: DispatchWorkItem?
    private var syncing = false
    private var offeredUpdate = false
    private var lastShortcuts: [Shortcut?]?
    private lazy var statusItem = ChargeStatusItem(module: self)

    public convenience init() {
        self.init(store: .shared, model: ChargeLimitModel())
    }

    /// `store` and `model` let previews use throwaway settings and sample data.
    init(store: SettingsStore, model: ChargeLimitModel) {
        settings = Persisted("chargelimit", default: ChargeLimitSettings(), store: store)
        self.model = model
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        model.refreshLocal()
        powerWatcher.onChange = { [weak self] in
            self?.model.refreshLocal()
            self?.statusItem.refresh()
        }
        powerWatcher.start()
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { m in
            Task { await m.sync() }
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.sync() }
            }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        registerHotkeys()
        updateStatusItem()
        Task { await sync() }
    }

    public func stop() {
        guard running else { return }
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        powerWatcher.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        pushWork?.cancel()
        pushWork = nil
        HotkeyCenter.shared.unregister(prefix: "chargelimit.")
        lastShortcuts = nil
        statusItem.remove()
        settings.flush()
        // Turned off by the user (not MacToys quitting): give charging back to macOS. When MacToys
        // quits with Charge Limit on, the helper keeps limiting on its own.
        if !ModuleRegistry.shared.isEnabled(info.id), model.helper.isRunning, model.config?.paused == false {
            let model = self.model
            Task { await model.send(.pause) }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (ChargeLimitModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    private func settingsChanged() {
        guard running else { return }
        registerHotkeys()
        updateStatusItem()
        statusItem.refresh()
        // Sliders change continuously: send the final value.
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.sync() }
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func registerHotkeys() {
        let s = settings.value
        let shortcuts = [s.toggleShortcut, s.topUpShortcut]
        guard lastShortcuts != shortcuts else { return }
        lastShortcuts = shortcuts
        HotkeyCenter.shared.register("chargelimit.toggle", s.toggleShortcut) { [weak self] in self?.toggleLimit(fromShortcut: true) }
        HotkeyCenter.shared.register("chargelimit.topup", s.topUpShortcut) { [weak self] in self?.toggleTopUp(fromShortcut: true) }
    }

    private func updateStatusItem() {
        if settings.value.showMenuBarItem && model.battery != nil { statusItem.install() } else { statusItem.remove() }
    }

    // MARK: - Sync with the helper

    /// Reads the battery and the helper, then makes the helper match the settings.
    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        model.refreshLocal()
        await model.refreshHelper()
        defer { statusItem.refresh() }
        guard running else { return }
        switch model.helper {
        case .outdated:
            offerUpdateOnce()
        case .running(let status):
            let s = settings.value
            let wanted = s.engine == .macToys && model.hardware.isSupported
            if !wanted {
                if !status.config.paused { await model.send(.pause) }
                return
            }
            for request in s.requests(toMatch: status.config, capabilities: model.hardware.capabilities) {
                guard await model.send(request) else { break }
            }
            if s.limitPaused, model.config?.paused == false {
                await model.send(.pause)
            } else if !s.limitPaused, model.config?.paused == true, model.status?.lastError == nil {
                await model.send(.resume)
            }
        case .notInstalled, .notResponding:
            break
        }
    }

    /// After an update the helper may be older than this MacToys: reinstall it (once per launch).
    private func offerUpdateOnce() {
        guard !offeredUpdate, model.task == nil else { return }
        offeredUpdate = true
        installHelper(prompt: String(localized: "MacToys has a new version of its charge helper. Enter your password to install it.",
                                     comment: "Administrator prompt when the charge helper is out of date"))
    }

    // MARK: - Helper install and removal

    /// The bundled command-line tool, which doubles as the helper; nil when running unbundled.
    static var bundledTool: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mactoys").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func installHelper(prompt: String = String(localized: "MacToys wants to install its charge helper, which switches charging on and off.",
                                               comment: "Administrator prompt for installing the charge helper")) {
        guard model.task == nil else { return }
        guard model.hardware.isSupported else { return }
        guard let source = Self.bundledTool else {
            model.message = String(localized: "The helper is part of the MacToys app. Open MacToys from its app bundle to install it.")
            return
        }
        let plan = HelperInstallPlan(source: source, ownerUID: getuid())
        model.message = nil
        model.task = .installing
        do {
            _ = try Privileged.run(plan.installScript, prompt: prompt)
            log.notice("Installed the charge helper")
        } catch let error as AppleScript.Failure {
            model.task = nil
            if error.code != -128 {
                model.message = String(localized: "The helper could not be installed: \(error.message)",
                                       comment: "Error banner; the placeholder is the system's reason")
            }
            return
        } catch {
            model.task = nil
            model.message = String(localized: "The helper could not be installed: \(error.localizedDescription)",
                                   comment: "Error banner; the placeholder is the system's reason")
            return
        }
        Task {
            // launchd starts it within a moment.
            for _ in 0..<20 {
                await model.refreshHelper()
                if model.helper.status != nil { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            model.task = nil
            if model.helper.status == nil {
                model.message = String(localized: "The helper is installed but doesn't answer. If you turned MacToys off in System Settings › General › Login Items & Extensions, turn it back on.")
            }
            await sync()
        }
    }

    /// Asks the helper to restore normal charging and remove itself; falls back to an administrator
    /// script that does the same when it doesn't answer.
    func uninstallHelper() {
        guard model.task == nil else { return }
        model.message = nil
        model.task = .uninstalling
        Task {
            if model.helper.status != nil, await model.send(.uninstall) {
                for _ in 0..<20 where HelperClient.isInstalled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            if HelperClient.isInstalled {
                do {
                    _ = try Privileged.run(HelperInstallPlan.uninstallScript,
                                           prompt: String(localized: "MacToys wants to remove its charge helper and restore normal charging.",
                                                          comment: "Administrator prompt for removing the charge helper"))
                } catch let error as AppleScript.Failure {
                    if error.code != -128 {
                        model.message = String(localized: "The helper could not be removed: \(error.message)",
                                               comment: "Error banner; the placeholder is the system's reason")
                    }
                } catch {
                    model.message = String(localized: "The helper could not be removed: \(error.localizedDescription)",
                                           comment: "Error banner; the placeholder is the system's reason")
                }
            }
            model.task = nil
            await model.refreshHelper()
            statusItem.refresh()
        }
    }

    // MARK: - Actions

    var canControl: Bool { model.hardware.isSupported && settings.value.engine == .macToys }

    /// Pauses or resumes the limit; without a helper, opens the settings page.
    func toggleLimit(fromShortcut: Bool = false) {
        guard canControl, model.helper.isRunning else {
            if fromShortcut { HUD.show("Charge Limit needs its helper", symbol: "exclamationmark.triangle") }
            ModuleRegistry.shared.showSettings?(info.id)
            return
        }
        if model.config?.paused == true { resume() } else { pause() }
        if fromShortcut {
            if settings.value.limitPaused {
                HUD.show("Charge Limit paused", symbol: "pause.circle")
            } else {
                HUD.show("Charge Limit \(Self.percent(settings.value.upperLimit))", symbol: "battery.75percent")
            }
        }
    }

    func pause() {
        settings.value.limitPaused = true
        Task { await model.send(.pause) }
    }

    func resume() {
        settings.value.limitPaused = false
        Task { await model.send(.resume) }
    }

    var isToppingUp: Bool { model.config?.topUp == true }

    func setTopUp(_ on: Bool) {
        guard canControl, model.helper.isRunning else { return }
        if on { settings.value.limitPaused = false }
        Task { await model.send(.topUp(on)) }
    }

    func toggleTopUp(fromShortcut: Bool = false) {
        guard canControl, model.helper.isRunning else {
            if fromShortcut { HUD.show("Charge Limit needs its helper", symbol: "exclamationmark.triangle") }
            return
        }
        let on = !isToppingUp
        setTopUp(on)
        if fromShortcut {
            if on {
                HUD.show("Topping up to \(Self.percent(100))", symbol: "battery.100percent.bolt")
            } else {
                HUD.show("Top up cancelled", symbol: "battery.75percent")
            }
        }
    }

    func setCalibration(_ on: Bool) {
        guard canControl, model.helper.isRunning else { return }
        if on { settings.value.limitPaused = false }
        Task { await model.send(.calibrate(on)) }
    }

    func setUpperLimit(_ value: Int) {
        settings.value.upperLimit = min(max(value, ChargePolicy.upperRange.lowerBound), ChargePolicy.upperRange.upperBound)
    }

    func openBatterySettings() {
        NSWorkspace.shared.open(SystemChargeLimit.settingsURL)
    }

    /// One line for the menu bar flyout switch: "Sailing · 78 % · limit 80 %".
    var statusLine: String {
        ChargeText.statusLine(model: model, settings: settings.value)
    }

    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Flyout

    func toggleFlyout(from button: NSStatusBarButton?) {
        statusItem.toggleFlyout(from: button)
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(ChargeLimitSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        guard canControl else {
            guard model.systemLimit.available else { return [] }
            return [QuickAction(id: "chargelimit.battery-settings", title: "Battery Settings", symbol: "battery.75percent",
                                tint: .green, perform: { [weak self] in self?.openBatterySettings() })]
        }
        return [
            QuickAction(id: "chargelimit.toggle", title: "Charge Limit", symbol: "battery.75percent", tint: .green,
                        shortcut: settings.value.toggleShortcut,
                        isOn: { [weak self] in self?.model.isLimiting ?? false },
                        detail: { [weak self] in self?.statusLine ?? "" },
                        perform: { [weak self] in self?.toggleLimit() }),
            QuickAction(id: "chargelimit.topup", title: "Top Up", symbol: "battery.100percent.bolt", tint: .green,
                        shortcut: settings.value.topUpShortcut,
                        perform: { [weak self] in self?.toggleTopUp() }),
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Pause or resume Charge Limit", settings.value.toggleShortcut),
         ShortcutBinding("Top up to full charge", settings.value.topUpShortcut)]
            .filter { !$0.keys.isEmpty }
    }

    /// `mactoys://chargelimit/<action>`: `open`/`settings`/`show`, `flyout`, `pause`, `resume`, `toggle`,
    /// `topup` (`?on=false` cancels), `limit?value=80`, `discharge?on=true|false`, `calibrate` (`?on=false` cancels).
    public func handle(_ command: AppCommand) -> Bool {
        let p = command.parameters
        func flag(_ key: String) -> Bool? {
            guard let v = p[key]?.lowercased() else { return nil }
            return ["1", "true", "yes", "on"].contains(v)
        }
        switch command.action {
        case "open", "settings", "show":
            ModuleRegistry.shared.showSettings?(info.id)
        case "flyout":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            toggleFlyout(from: nil)
        case "pause":
            guard running, canControl else { return false }
            pause()
        case "resume":
            guard running, canControl else { return false }
            resume()
        case "toggle":
            guard running else { return false }
            toggleLimit()
        case "topup", "top-up":
            guard running, canControl else { return false }
            setTopUp(flag("on") ?? true)
        case "limit":
            guard let value = Int(p["value"] ?? p["percent"] ?? ""), ChargePolicy.upperRange.contains(value) else { return false }
            setUpperLimit(value)
        case "discharge":
            settings.value.dischargeToLimit = flag("on") ?? !settings.value.dischargeToLimit
        case "calibrate":
            guard running, canControl else { return false }
            setCalibration(flag("on") ?? true)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] { ChargePreviews.scenes }
}
