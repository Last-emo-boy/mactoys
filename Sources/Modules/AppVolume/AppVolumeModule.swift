import AppKit
import CoreAudio
import MacToysCore
import SwiftUI

/// App Volume: per-app volume (with boost), mute, balance, output device and equalizer from the
/// menu bar, plus the system's output and input devices.
///
/// Apps are left completely alone until the user changes one of them. Only then does App Volume
/// create a Core Audio process tap for that app (`mutedWhenTapped`), mix it into a private
/// aggregate device with the chosen output, and play it back processed from an IO proc.
@MainActor
public final class AppVolumeModule: ToyModule {
    public let info = ModuleInfo(
        id: "appvolume", name: "App Volume",
        summary: "Set the volume, output device and equalizer of each app from the menu bar.",
        symbol: "speaker.wave.3.fill", tint: .purple, category: .inputOutput,
        permissions: [], enabledByDefault: false,
        keywords: ["volume", "audio", "sound", "per app", "output", "mixer", "equalizer", "eq", "boost",
                   "balance", "speakers", "headphones", "mute"])

    let settings: Persisted<AppVolumeSettings>
    let store = AppVolumeStore()
    let levels = LevelStore()
    let log = Log.for("appvolume")
    /// Previews show sample data and never touch Core Audio.
    let isPreview: Bool

    private let audio = AudioSystem()
    private let backend = HALTapBackend()
    private lazy var controller: TapController = {
        let c = TapController(backend: backend)
        c.onStateChange = { [weak self] in self?.syncControllerState() }
        return c
    }()
    private var running = false
    private var apps: [AudioApp] = []
    private var firstPlayed: [String: Date] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var refreshWork: DispatchWorkItem?
    private var tickTimer: Timer?
    private var meterTimer: Timer?
    private var lastMeterTick = Date()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusItem: NSStatusItem?
    private var statusSymbol: String?
    private var flyout: AppVolumeFlyoutPanel?
    private var registeredShortcuts: [Shortcut?] = []
    private var scrollMonitor: Any?
    /// The flyout slider under the pointer, for the scroll wheel.
    var hoveredSlider: SliderTarget?

    enum SliderTarget: Equatable {
        case app(String)
        case output
        case input
    }

    public convenience init() {
        self.init(store: .shared)
    }

    init(store: SettingsStore, preview: Bool = false) {
        settings = Persisted("appvolume", default: AppVolumeSettings(), store: store)
        isPreview = preview
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running, !isPreview else { return }
        running = true
        audio.onChange = { [weak self] structural in
            guard let self, self.running else { return }
            if structural { self.scheduleRefresh() } else { self.refreshDeviceControls() }
        }
        audio.startListening()
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didTerminateApplicationNotification) { module, note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            module.appTerminated(app?.bundleIdentifier)
        }
        observe(ws, NSWorkspace.didWakeNotification) { module, _ in module.scheduleRefresh(after: 1) }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) { module, _ in
            module.settings.reload()
        }
        scheduleTick()
        installScrollMonitor()
        refresh()
        updateStatusItem()
        registerHotkeys()
    }

    public func stop() {
        guard running else { return }
        running = false
        closeFlyout()
        tickTimer?.invalidate()
        tickTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        hoveredSlider = nil
        stopMeters()
        refreshWork?.cancel()
        refreshWork = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        // Every tap goes away: apps play straight to their own devices again.
        controller.stopAll()
        audio.stopListening()
        audio.onChange = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        statusSymbol = nil
        HotkeyCenter.shared.unregister(prefix: "appvolume.")
        registeredShortcuts = []
        apps = []
        store.rows = []
        store.processing = []
        store.failures = [:]
        store.hasScanned = false
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (AppVolumeModule, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self, note)
            }
        }
        observers.append((center, token))
    }

    private func settingsChanged() {
        guard running else { return }
        reconcile()
        updateRows()
        updateStatusItem()
        registerHotkeys()
        updateMetering()
    }

    // MARK: - Refresh

    /// HAL notifications come in bursts (a device switch fires a dozen): coalesce them.
    private func scheduleRefresh(after delay: Double = 0.03) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh() {
        guard running else { return }
        let world = audio.snapshot()
        apps = AppGrouper.group(world.processes)
        let now = Date()
        for app in apps where app.isPlaying {
            if firstPlayed[app.identity.key] == nil { firstPlayed[app.identity.key] = now }
            lastPlayed[app.identity.key] = now
        }
        if store.world != world { store.world = world }
        store.hasScanned = true
        reconcile()
        updateRows()
        refreshDeviceControls()
        updateStatusIcon()
    }

    private func reconcile() {
        guard running else { return }
        controller.reconcile(.init(apps: apps, world: store.world, settings: settings.value), now: Date())
        syncControllerState()
        scheduleTick()
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        for app in apps where app.isPlaying { lastPlayed[app.identity.key] = now }
        controller.tick(now: now)
        syncControllerState()
        updateRows()
        scheduleTick()
    }

    /// Health checks run once a second, or five times a second while an app waits to be taken over
    /// (so its settings apply a moment after its first sound, not up to a second later).
    private func scheduleTick() {
        let interval = controller.settling ? 0.2 : 1
        if let tickTimer, tickTimer.isValid, tickTimer.timeInterval == interval { return }
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func syncControllerState() {
        if store.capture != controller.capture { store.capture = controller.capture }
        if store.failures != controller.failures { store.failures = controller.failures }
        let processing = Set(controller.sessions.values.filter { $0.mode == .process }.map(\.key))
        if store.processing != processing { store.processing = processing }
    }

    private func updateRows() {
        let rows = FlyoutList.rows(apps: apps, settings: settings.value, firstPlayed: firstPlayed,
                                   lastPlayed: lastPlayed, now: Date())
        if rows != store.rows { store.rows = rows }
    }

    private func refreshDeviceControls() {
        guard running else { return }
        var out = DeviceControls()
        if let d = store.world.defaultOutput {
            out.volume = audio.volume(d.id)
            out.canSetVolume = audio.canSetVolume(d.id)
            out.muted = audio.isMuted(d.id) ?? false
            out.canMute = audio.canMute(d.id)
            out.balance = audio.balance(d.id)
            out.sampleRates = audio.sampleRates(d.id)
        }
        var inp = DeviceControls()
        if let d = store.world.defaultInput {
            inp.volume = audio.volume(d.id, input: true)
            inp.canSetVolume = audio.canSetVolume(d.id, input: true)
            inp.muted = audio.isMuted(d.id, input: true) ?? false
            inp.canMute = audio.canMute(d.id, input: true)
        }
        if store.output != out { store.output = out }
        if store.input != inp { store.input = inp }
    }

    private func appTerminated(_ bundleID: String?) {
        guard let bundleID, !settings.value.rememberApps, !settings.value.isPinned(bundleID),
              settings.value.apps[bundleID] != nil else { return }
        settings.value.apps[bundleID] = nil
    }

    // MARK: - Meters

    private func updateMetering() {
        let want = running && settings.value.showMeters && (flyout?.isVisible ?? false)
        if controller.metering != want {
            controller.metering = want
            reconcile()
        }
        if flyout?.isVisible == true { startMeters() } else { stopMeters() }
    }

    private func startMeters() {
        guard meterTimer == nil else { return }
        _ = backend.takeLevels() // peaks gathered while the flyout was closed are stale
        lastMeterTick = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.levels.update(self.backend.takeLevels(), elapsed: now.timeIntervalSince(self.lastMeterTick))
                self.lastMeterTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels.clear()
    }

    // MARK: - App actions

    func appSettings(_ key: String) -> AppAudioSettings { settings.value.settings(for: key) }

    func identity(_ key: String) -> AppIdentity? {
        store.rows.first { $0.id == key }?.identity ?? apps.first { $0.identity.key == key }?.identity
    }

    private func change(_ key: String, _ body: (inout AppAudioSettings) -> Void) {
        let name = identity(key)?.name ?? settings.value.apps[key]?.name ?? ""
        settings.update { $0.update(key, name: name, body) }
    }

    func setVolume(_ key: String, _ volume: Double) {
        change(key) { $0.volume = volume; if volume > 0 { $0.muted = false } }
    }

    func toggleMute(_ key: String) { change(key) { $0.muted.toggle() } }

    func setMuted(_ key: String, _ muted: Bool) { change(key) { $0.muted = muted } }

    func setBalance(_ key: String, _ balance: Double) { change(key) { $0.balance = balance } }

    /// nil follows the system output.
    func setOutput(_ key: String, _ device: AudioDeviceInfo?) {
        change(key) {
            $0.outputUID = device?.uid
            $0.outputName = device?.name
        }
    }

    func setEQ(_ key: String, _ eq: EQSettings) { change(key) { $0.eq = eq } }

    func applyPreset(_ key: String, id: String) {
        let count = settings.value.eqBandCount
        var eq = appSettings(key).eq
        if let preset = EQPreset.named(id) {
            eq.gains = preset.gains(count: count)
            eq.preamp = 0
        } else if let custom = settings.value.customPresets.first(where: { $0.id == id }) {
            eq.gains = EQCurve.resample(custom.gains, from: custom.frequencies, to: EQLayout.frequencies(count: count))
            eq.preamp = custom.preamp
        } else {
            return
        }
        eq.preset = id
        eq.isOn = id != "flat" || eq.isOn
        setEQ(key, eq)
    }

    /// Saves an app's curve as a named preset and selects it for the app.
    func savePreset(from key: String, name: String) {
        let eq = appSettings(key).eq
        let count = settings.value.eqBandCount
        let preset = CustomEQPreset(name: name, frequencies: EQLayout.frequencies(count: count),
                                    gains: EQCurve.gains(eq, count: count), preamp: eq.preamp)
        settings.update { s in
            s.customPresets.append(preset)
            s.update(key, name: identity(key)?.name ?? "") { $0.eq.preset = preset.id }
        }
    }

    func resetApp(_ key: String) {
        settings.update { s in
            s.apps[key] = nil
            if s.isPinned(key) { s.apps[key] = AppAudioSettings(name: identity(key)?.name ?? "") }
        }
    }

    func togglePin(_ key: String) {
        settings.update { s in
            if let i = s.pinnedApps.firstIndex(of: key) {
                s.pinnedApps.remove(at: i)
                if let a = s.apps[key], a.matchesNewApp(volume: s.newAppVolume) { s.apps[key] = nil }
            } else {
                s.pinnedApps.append(key)
                if s.apps[key] == nil { s.apps[key] = AppAudioSettings(name: identity(key)?.name ?? key, volume: s.newAppVolume) }
            }
        }
    }

    /// Mutes or unmutes the frontmost app (shortcut).
    func muteFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, let key = app.bundleIdentifier else { return }
        let name = app.localizedName ?? key
        let muted = !appSettings(key).muted
        settings.update { $0.update(key, name: name) { $0.muted = muted } }
        if muted {
            HUD.show(String(localized: "\(name) muted", comment: "HUD; the placeholder is an app name"), symbol: "speaker.slash.fill")
        } else {
            HUD.show(String(localized: "\(name) unmuted", comment: "HUD; the placeholder is an app name"), symbol: "speaker.wave.2.fill")
        }
    }

    func retryCapture() {
        controller.retry(now: Date())
        syncControllerState()
    }

    func openPrivacySettings() {
        closeFlyout()
        PermissionCenter.shared.openSettings(.screenRecording)
    }

    // MARK: - System device actions

    func setDefaultDevice(_ device: AudioDeviceInfo, input: Bool) {
        guard !isPreview else {
            if input { store.world.defaultInputUID = device.uid } else { store.world.defaultOutputUID = device.uid }
            return
        }
        audio.setDefault(device.id, input: input)
    }

    func setSystemVolume(_ value: Float, input: Bool) {
        if input { store.input.volume = value } else { store.output.volume = value }
        guard !isPreview, let d = input ? store.world.defaultInput : store.world.defaultOutput else { return }
        audio.setVolume(value, on: d.id, input: input)
        if value > 0, (input ? store.input.muted : store.output.muted) { setSystemMuted(false, input: input) }
    }

    func setSystemMuted(_ muted: Bool, input: Bool) {
        if input { store.input.muted = muted } else { store.output.muted = muted }
        guard !isPreview, let d = input ? store.world.defaultInput : store.world.defaultOutput else { return }
        audio.setMuted(muted, on: d.id, input: input)
    }

    func setOutputBalance(_ value: Float) {
        store.output.balance = value
        guard !isPreview, let d = store.world.defaultOutput else { return }
        audio.setBalance(value, on: d.id)
    }

    func setOutputSampleRate(_ rate: Double) {
        guard !isPreview, let d = store.world.defaultOutput else { return }
        audio.setSampleRate(rate, on: d.id)
    }

    // MARK: - Scroll wheel

    /// Scrolling over a flyout slider moves it, 2 % per notch.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        var accumulated: CGFloat = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let target = self.hoveredSlider, let flyout = self.flyout,
                  event.window === flyout else { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
            accumulated += (abs(dy) >= abs(dx) ? dy : -dx) * (event.isDirectionInvertedFromDevice ? -1 : 1)
            let steps = Int(accumulated / 10)
            guard steps != 0 else { return nil }
            accumulated -= CGFloat(steps) * 10
            self.nudge(target, by: Double(steps) * 0.02)
            return nil
        }
    }

    private func nudge(_ target: SliderTarget, by delta: Double) {
        switch target {
        case .app(let key):
            let v = appSettings(key).volume
            var next = min(max(0, v + delta), settings.value.maxVolume)
            if (v - 1) * (next - 1) < 0 { next = 1 } // stop at 100 % on the way through
            setVolume(key, (next * 100).rounded() / 100)
        case .output, .input:
            let input = target == .input
            let v = Double((input ? store.input.volume : store.output.volume) ?? 0)
            setSystemVolume(Float(min(max(0, v + delta), 1)), input: input)
        }
    }

    // MARK: - Flyout

    func toggleFlyout(from button: NSStatusBarButton? = nil) {
        if let flyout, flyout.isVisible { closeFlyout(); return }
        let panel = flyout ?? AppVolumeFlyoutPanel(module: self)
        panel.onClose = { [weak self] in self?.updateMetering() }
        flyout = panel
        if running { refresh() }
        panel.present(below: button ?? statusItem?.button)
        updateMetering()
    }

    func closeFlyout() {
        flyout?.dismiss()
        hoveredSlider = nil
        updateMetering()
    }

    /// Runs an alert without the flyout hiding underneath it.
    func withFlyoutPinned<T>(_ body: () -> T) -> T {
        flyout?.hidesOnResign = false
        defer {
            flyout?.hidesOnResign = true
            if flyout?.isVisible == true { flyout?.makeKey() }
        }
        return body()
    }

    /// Asks for a preset name (alert with a text field).
    func promptPresetName(for key: String) {
        withFlyoutPinned {
            let alert = NSAlert()
            alert.messageText = String(localized: "Save Equalizer Preset")
            alert.informativeText = String(localized: "The preset can be chosen for any app.")
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = String(localized: "Custom \(settings.value.customPresets.count + 1)",
                                       comment: "Default name of a saved equalizer preset; the number counts them")
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            savePreset(from: key, name: name)
        }
    }

    func showSettings() {
        closeFlyout()
        ModuleRegistry.shared.showSettings?(info.id)
    }

    // MARK: - Menu bar

    private func updateStatusItem() {
        guard running, settings.value.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            statusSymbol = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "com.w33d.mactoys.appvolume"
            item.button?.target = AppVolumeStatusTarget.shared
            item.button?.action = #selector(AppVolumeStatusTarget.clicked(_:))
            AppVolumeStatusTarget.shared.module = self
            statusItem = item
        }
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = switch settings.value.menuBarIcon {
        case .mixer: "slider.vertical.3"
        case .speaker: "speaker.wave.2"
        case .outputDevice: DeviceSymbol.name(for: store.world.defaultOutput)
        }
        let deviceName = store.world.defaultOutput?.name ?? ""
        button.toolTip = deviceName.isEmpty ? String(localized: "App Volume")
            : String(localized: "App Volume — \(deviceName)", comment: "Menu bar tooltip; the placeholder is the output device")
        guard symbol != statusSymbol else { return }
        statusSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "App Volume"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        button.image = image
    }

    private func registerHotkeys() {
        let s = settings.value
        let wanted = [s.flyoutShortcut, s.muteFrontmostShortcut]
        guard wanted != registeredShortcuts else { return }
        registeredShortcuts = wanted
        HotkeyCenter.shared.register("appvolume.flyout", s.flyoutShortcut) { [weak self] in self?.toggleFlyout() }
        HotkeyCenter.shared.register("appvolume.mute-frontmost", s.muteFrontmostShortcut) { [weak self] in self?.muteFrontmost() }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(AppVolumeSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "appvolume.open", title: "App Volume", symbol: "slider.vertical.3", tint: .purple,
                     shortcut: settings.value.flyoutShortcut, perform: { [weak self] in self?.toggleFlyout() })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Show App Volume", settings.value.flyoutShortcut),
         ShortcutBinding("Mute the frontmost app", settings.value.muteFrontmostShortcut)]
    }

    /// `mactoys://appvolume/<action>`:
    /// `open`/`show` (flyout), `settings`,
    /// `volume?app=<bundle id or name>&value=<0–200>` (without `app`: the output device, 0–100),
    /// `mute?app=…&on=true|false` (toggles without `on`; without `app`: the output device),
    /// `output?app=…&device=<name or UID|system>`, `eq?app=…&preset=<id|off>`, `reset?app=…`,
    /// `device?output=<name or UID>&input=<name or UID>`, `retry`.
    public func handle(_ command: AppCommand) -> Bool {
        let p = command.parameters
        func flag(_ key: String) -> Bool? {
            guard let v = p[key]?.lowercased() else { return nil }
            return ["1", "true", "yes", "on"].contains(v)
        }
        switch command.action {
        case "open", "show", "flyout":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            toggleFlyout()
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "volume":
            guard running, let value = Double(p["value"] ?? p["percent"] ?? "") else { return false }
            if let app = p["app"] {
                guard let key = resolveApp(app) else { return false }
                setVolume(key, min(max(value, 0), settings.value.maxVolume * 100) / 100)
            } else {
                setSystemVolume(Float(min(max(value, 0), 100) / 100), input: false)
            }
        case "mute", "unmute":
            guard running else { return false }
            let on = command.action == "unmute" ? false : flag("on")
            if let app = p["app"] {
                guard let key = resolveApp(app) else { return false }
                if let on { setMuted(key, on) } else { toggleMute(key) }
            } else {
                setSystemMuted(on ?? !store.output.muted, input: false)
            }
        case "output":
            guard running, let app = p["app"], let key = resolveApp(app) else { return false }
            let target = p["device"] ?? "system"
            if target.lowercased() == "system" || target.isEmpty { setOutput(key, nil) }
            else if let d = resolveDevice(target, input: false) { setOutput(key, d) }
            else { return false }
        case "eq":
            guard running, let app = p["app"], let key = resolveApp(app), let preset = p["preset"] else { return false }
            if preset.lowercased() == "off" {
                var eq = appSettings(key).eq
                eq.isOn = false
                setEQ(key, eq)
            } else {
                guard EQPreset.named(preset) != nil || settings.value.customPresets.contains(where: { $0.id == preset })
                else { return false }
                applyPreset(key, id: preset)
            }
        case "reset":
            guard let app = p["app"], let key = resolveApp(app) else { return false }
            resetApp(key)
        case "device":
            guard running else { return false }
            var handled = false
            if let o = p["output"], let d = resolveDevice(o, input: false) { setDefaultDevice(d, input: false); handled = true }
            if let i = p["input"], let d = resolveDevice(i, input: true) { setDefaultDevice(d, input: true); handled = true }
            return handled
        case "retry":
            guard running else { return false }
            retryCapture()
        default:
            return false
        }
        return true
    }

    /// An app by bundle id or (case-insensitive) name, among running and remembered apps.
    private func resolveApp(_ text: String) -> String? {
        let t = text.lowercased()
        if apps.contains(where: { $0.identity.key.lowercased() == t }) || settings.value.apps[text] != nil { return text }
        if let app = apps.first(where: { $0.identity.key.lowercased() == t || $0.name.lowercased() == t }) { return app.identity.key }
        if let (key, _) = settings.value.apps.first(where: { $0.value.name.lowercased() == t }) { return key }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == t || $0.localizedName?.lowercased() == t
        }) { return app.bundleIdentifier }
        return text.contains(".") ? text : nil
    }

    private func resolveDevice(_ text: String, input: Bool) -> AudioDeviceInfo? {
        let list = input ? store.world.inputDevices : store.world.outputDevices
        let t = text.lowercased()
        return list.first { $0.uid == text } ?? list.first { $0.name.lowercased() == t }
            ?? list.first { $0.name.lowercased().contains(t) }
    }

    public var previewScenes: [PreviewScene] { AppVolumePreviews.scenes }
}

/// Target for the menu bar button (NSStatusBarButton needs an Objective-C target).
@MainActor
final class AppVolumeStatusTarget: NSObject {
    static let shared = AppVolumeStatusTarget()
    weak var module: AppVolumeModule?

    @objc func clicked(_ sender: NSStatusBarButton) {
        module?.toggleFlyout(from: sender)
    }
}

extension AppVolumeModule {
    /// Tracks the slider under the pointer (entering one slider can arrive before leaving another).
    func hover(_ target: SliderTarget, _ inside: Bool) {
        if inside { hoveredSlider = target } else if hoveredSlider == target { hoveredSlider = nil }
    }
}
