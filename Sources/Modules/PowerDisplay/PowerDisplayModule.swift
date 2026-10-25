import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Live list of monitors for the flyout and the settings page.
@MainActor
@Observable
final class PowerDisplayStore {
    var monitors: [MonitorState] = []
    /// Controls are locked while a rescan runs (after wake or a display change).
    var isRefreshing = false
    var hasScanned = false

    var visibleMonitors: [MonitorState] = []
}

/// Brightness, contrast, volume, input, color preset and power control for every display:
/// DDC/CI over IOAVService for external monitors, DisplayServices for the built-in panel.
@MainActor
public final class PowerDisplayModule: ToyModule {
    public let info = ModuleInfo(
        id: "powerdisplay", name: "Power Display",
        summary: "Control brightness, contrast, volume and input of your displays from one flyout.",
        symbol: "sun.max.fill", tint: .yellow, category: .systemTools,
        permissions: [], enabledByDefault: false,
        keywords: ["ddc", "monitor", "brightness", "contrast", "volume", "input", "display", "lunar", "monitorcontrol"])

    let settings: Persisted<PowerDisplaySettings>
    let store = PowerDisplayStore()
    let log = Log.for("powerdisplay")

    private let engine = DisplayEngine()
    private let queue = DispatchQueue(label: "com.w33d.mactoys.powerdisplay.ddc", qos: .userInitiated)
    private var running = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var rescanWork: DispatchWorkItem?
    private var scanGeneration = 0
    private var restorePending = false
    private var pending: [String: (String, DisplayFeature, UInt16)] = [:]
    private var flushScheduled = false
    private var statusItem: NSStatusItem?
    private var scrollMonitor: Any?
    private var flyout: FlyoutPanel?
    private var lastShortcut: Shortcut??
    /// The flyout slider under the pointer, for scroll-wheel steps.
    var hoveredSlider: (monitor: String?, feature: DisplayFeature)?

    public convenience init() {
        self.init(store: .shared)
    }

    /// `store` lets previews use throwaway settings.
    init(store: SettingsStore) {
        settings = Persisted("powerdisplay", default: PowerDisplaySettings(), store: store)
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
        updateStatusItem()
        installScrollMonitor()
        Services.displayProfiles = { [weak self] in
            self?.settings.value.profiles.map { Services.DisplayProfile(id: $0.id, name: $0.name) } ?? []
        }
        Services.applyDisplayProfile = { [weak self] id in self?.applyProfile(id: id) }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
            $0.scheduleRescan(after: $0.settings.value.refreshDelay)
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidWakeNotification) {
            $0.store.isRefreshing = true
            $0.scheduleRescan(after: max(1, $0.settings.value.refreshDelay))
        }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) {
            // The CLI changed values or settings: pick them up without locking the controls.
            $0.settings.reload()
            $0.refreshValues()
        }
        restorePending = settings.value.restoreOnLaunch
        rescan()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister("powerdisplay.activate")
        lastShortcut = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        rescanWork?.cancel()
        rescanWork = nil
        scanGeneration += 1
        flushWrites()
        closeFlyout()
        IdentifyOverlay.dismiss()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        Services.displayProfiles = nil
        Services.applyDisplayProfile = nil
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (PowerDisplayModule) -> Void) {
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
        registerHotkey()
        updateStatusItem()
        refreshVisible()
    }

    private func registerHotkey() {
        let shortcut = settings.value.activation
        guard lastShortcut != .some(shortcut) else { return }
        lastShortcut = .some(shortcut)
        HotkeyCenter.shared.register("powerdisplay.activate", shortcut) { [weak self] in self?.toggleFlyout(from: nil) }
    }

    // MARK: - Discovery

    func scheduleRescan(after delay: Double) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    /// Rediscovers displays on the DDC queue; controls stay locked until it finishes.
    func rescan() {
        guard running else { return }
        scanGeneration += 1
        let generation = scanGeneration
        store.isRefreshing = true
        let names = DisplayEngine.screenNames()
        let cached = settings.value.monitors.compactMapValues(\.capabilities)
        let maxCompat = settings.value.maxCompatibility
        let engine = self.engine
        queue.async { [weak self] in
            engine.maxCompatibility = maxCompat
            let snapshots = engine.discover(names: names, cachedCapabilities: cached)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running, generation == self.scanGeneration else { return }
                    self.received(snapshots)
                }
            }
        }
    }

    private func received(_ snapshots: [MonitorSnapshot]) {
        var existing = Dictionary(store.monitors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        store.monitors = snapshots.map { snap in
            if let state = existing.removeValue(forKey: snap.id) { state.load(snap); return state }
            return MonitorState(snap)
        }
        settings.update { s in
            for snap in snapshots {
                var p = s.prefs(snap.id)
                p.lastName = snap.name
                if let raw = snap.capabilities?.raw, !raw.isEmpty { p.capabilities = raw }
                if s.monitors[snap.id] != p { s.monitors[snap.id] = p }
            }
        }
        store.isRefreshing = false
        store.hasScanned = true
        refreshVisible()
        if restorePending {
            restorePending = false
            restoreSavedValues()
        }
        log.info("found \(snapshots.count) display(s): \(snapshots.map { "\($0.name) [\($0.kind.rawValue)]" }.joined(separator: ", "), privacy: .public)")
    }

    private func refreshVisible() {
        let s = settings.value
        store.visibleMonitors = store.monitors.filter { !s.prefs($0.id).hidden && $0.snapshot.kind != .unsupported }
    }

    /// Re-reads one monitor's capabilities string (settings page button).
    func rereadCapabilities(_ id: String) {
        store.isRefreshing = true
        let engine = self.engine
        queue.async { [weak self] in
            let caps = engine.readCapabilities(monitor: id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.settings.update { $0.monitors[id, default: MonitorPrefs()].capabilities = caps?.raw }
                    self.rescan()
                }
            }
        }
    }

    // MARK: - Values

    var brightnessMonitors: [MonitorState] { store.visibleMonitors.filter { $0.supports(.brightness) } }
    var linkedMonitors: [MonitorState] {
        brightnessMonitors.filter { !settings.value.prefs($0.id).excludeFromLinkedBrightness }
    }
    var canLinkBrightness: Bool { brightnessMonitors.count >= 2 }
    var isLinked: Bool { settings.value.linkedBrightness && canLinkBrightness }

    /// Moves a slider. Writes are throttled so dragging doesn't flood the display with DDC traffic.
    func set(_ feature: DisplayFeature, percent: Double, on monitor: MonitorState) {
        let value = max(0, min(100, percent.rounded()))
        guard let reading = monitor.snapshot.readings[feature] else { return }
        monitor.percent[feature] = value
        enqueue(monitor.id, feature, VCPScale.raw(percent: value, maximum: reading.maximum))
    }

    /// The All displays slider: moves every linked monitor.
    func setLinkedBrightness(_ percent: Double) {
        for m in linkedMonitors { set(.brightness, percent: percent, on: m) }
    }

    var linkedBrightness: Double {
        let values = linkedMonitors.compactMap { $0.percent[.brightness] }
        return values.isEmpty ? 0 : (values.reduce(0, +) / Double(values.count)).rounded()
    }

    func setDiscrete(_ feature: DisplayFeature, value: UInt16, on monitor: MonitorState) {
        monitor.discrete[feature] = value
        enqueue(monitor.id, feature, value)
        flushWrites()
    }

    /// One wheel notch on a slider (or `steps` notches).
    func step(_ feature: DisplayFeature, on monitor: MonitorState?, by steps: Int) {
        let delta = Double(steps * settings.value.wheelIncrement)
        if let monitor {
            if feature == .brightness && isLinked && !settings.value.prefs(monitor.id).excludeFromLinkedBrightness {
                setLinkedBrightness(linkedBrightness + delta)
            } else {
                set(feature, percent: (monitor.percent[feature] ?? 0) + delta, on: monitor)
            }
        } else {
            setLinkedBrightness(linkedBrightness + delta)
        }
    }

    private func enqueue(_ id: String, _ feature: DisplayFeature, _ raw: UInt16) {
        pending["\(id)|\(feature.rawValue)"] = (id, feature, raw)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { self?.flushWrites() }
        }
    }

    private func flushWrites() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let writes = Array(pending.values)
        pending.removeAll()
        // Remember brightness and color presets for "restore on launch".
        settings.update { s in
            for (id, feature, raw) in writes where feature == .brightness || feature == .colorTemperature {
                var p = s.prefs(id)
                if feature == .brightness { p.lastBrightness = Int(raw) } else { p.lastColorPreset = Int(raw) }
                if s.monitors[id] != p { s.monitors[id] = p }
            }
        }
        let engine = self.engine
        queue.async {
            for (id, feature, raw) in writes { engine.write(feature, raw: raw, monitor: id) }
        }
    }

    /// Re-applies brightness and color presets saved from the last session.
    private func restoreSavedValues() {
        for m in store.monitors {
            let p = settings.value.prefs(m.id)
            if let b = p.lastBrightness, let r = m.snapshot.readings[.brightness] {
                m.percent[.brightness] = VCPScale.percent(raw: UInt16(clamping: b), maximum: r.maximum)
                enqueue(m.id, .brightness, UInt16(clamping: b))
            }
            if let c = p.lastColorPreset, m.supports(.colorTemperature) {
                m.discrete[.colorTemperature] = UInt16(clamping: c)
                enqueue(m.id, .colorTemperature, UInt16(clamping: c))
            }
        }
        flushWrites()
    }

    /// Turns a display on, to standby or off. Callers confirm with the user first.
    func setPower(_ value: UInt16, on monitor: MonitorState) {
        setDiscrete(.powerState, value: value, on: monitor)
    }

    // MARK: - Profiles

    func currentValues() -> [String: ProfileValues] {
        var out: [String: ProfileValues] = [:]
        for m in store.monitors {
            var v = ProfileValues()
            v.brightness = m.percent[.brightness].map { Int($0) }
            v.contrast = m.percent[.contrast].map { Int($0) }
            v.volume = m.percent[.volume].map { Int($0) }
            v.colorPreset = m.discrete[.colorTemperature].map { Int($0) }
            if !v.isEmpty { out[m.id] = v }
        }
        return out
    }

    @discardableResult
    func saveProfile(named name: String? = nil) -> Int {
        var id = 0
        settings.update { s in
            id = s.addProfile(named: name ?? s.suggestedProfileName(), monitors: currentValues())
            s.lastAppliedProfile = id
        }
        return id
    }

    /// Applies a profile; linked brightness is turned off first so per-monitor values hold.
    func applyProfile(id: Int) {
        guard running, let profile = settings.value.profiles.first(where: { $0.id == id }) else { return }
        if settings.value.linkedBrightness { settings.value.linkedBrightness = false }
        let snapshots = store.monitors.map(\.snapshot)
        for (monitorID, feature, raw) in ProfilePlan.writes(profile, monitors: snapshots) {
            guard let m = store.monitors.first(where: { $0.id == monitorID }), let r = m.snapshot.readings[feature] else { continue }
            if feature.isContinuous { m.percent[feature] = VCPScale.percent(raw: raw, maximum: r.maximum) } else { m.discrete[feature] = raw }
            enqueue(monitorID, feature, raw)
        }
        flushWrites()
        settings.value.lastAppliedProfile = id
        log.info("applied profile \(id)")
    }

    // MARK: - Flyout

    func toggleFlyout(from button: NSStatusBarButton?) {
        if let flyout, flyout.isVisible { closeFlyout(); return }
        let panel = flyout ?? FlyoutPanel(module: self)
        flyout = panel
        panel.present(below: button)
        refreshValues()
    }

    /// Re-reads current values (someone may have used the monitor's buttons) without locking the controls.
    func refreshValues() {
        guard store.hasScanned, !store.isRefreshing else { return }
        let targets = store.monitors.map { ($0.id, $0.snapshot.supported) }
        let engine = self.engine
        let generation = scanGeneration
        queue.async { [weak self] in
            var readings: [String: [DisplayFeature: FeatureReading]] = [:]
            for (id, features) in targets {
                for f in features where f != .powerState {
                    if let r = engine.read(f, monitor: id) { readings[id, default: [:]][f] = r }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.scanGeneration else { return }
                    for m in self.store.monitors {
                        guard let values = readings[m.id] else { continue }
                        for (f, r) in values where self.pending["\(m.id)|\(f.rawValue)"] == nil {
                            m.snapshot.readings[f] = r
                            if f.isContinuous { m.percent[f] = VCPScale.percent(raw: r.current, maximum: r.maximum) }
                            else { m.discrete[f] = r.current }
                        }
                    }
                }
            }
        }
    }

    func closeFlyout() {
        flyout?.dismiss()
        hoveredSlider = nil
    }

    /// Runs a confirmation alert while keeping the flyout from hiding underneath it. Texts must be localized.
    func confirm(_ title: String, _ message: String, button: String) -> Bool {
        flyout?.hidesOnResign = false
        defer { flyout?.hidesOnResign = true; if flyout?.isVisible == true { flyout?.makeKey() } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func identify() {
        IdentifyOverlay.show(store.monitors.map { ($0.snapshot.displayID, $0.snapshot.number, $0.name) })
    }

    // MARK: - Menu bar

    private func updateStatusItem() {
        if settings.value.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "com.w33d.mactoys.powerdisplay"
            let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: String(localized: "Power Display"))
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = String(localized: "Power Display")
            item.button?.target = StatusTarget.shared
            item.button?.action = #selector(StatusTarget.clicked(_:))
            StatusTarget.shared.module = self
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Scroll on the menu bar icon (when enabled) and over flyout sliders.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        var accumulated: CGFloat = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let overIcon = event.window != nil && event.window === self.statusItem?.button?.window
            let overSlider = event.window != nil && event.window === self.flyout && self.hoveredSlider != nil
            guard overIcon || overSlider else { return event }
            if overIcon && self.settings.value.menuBarWheel == .off { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            accumulated += event.isDirectionInvertedFromDevice ? -dy : dy
            let steps = Int(accumulated / 12)
            guard steps != 0 else { return nil }
            accumulated -= CGFloat(steps) * 12
            if overSlider, let h = self.hoveredSlider {
                self.step(h.feature, on: h.monitor.flatMap { id in self.store.monitors.first { $0.id == id } }, by: steps)
            } else {
                self.scrollMenuBar(steps)
            }
            return nil
        }
    }

    private func scrollMenuBar(_ steps: Int) {
        let targets: [MonitorState]
        switch settings.value.menuBarWheel {
        case .off: return
        case .primary:
            let main = CGMainDisplayID()
            targets = brightnessMonitors.filter { $0.snapshot.displayID == main }
        case .all:
            targets = brightnessMonitors
        }
        guard let first = targets.first else { return }
        if isLinked && targets.contains(where: { !settings.value.prefs($0.id).excludeFromLinkedBrightness }) {
            step(.brightness, on: nil, by: steps)
        } else {
            for m in targets { step(.brightness, on: m, by: steps) }
        }
        let percent = ((first.percent[.brightness] ?? 0) / 100).formatted(.percent.precision(.fractionLength(0)))
        HUD.show("Brightness \(percent)", symbol: "sun.max.fill", duration: 0.9)
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(PowerDisplaySettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "powerdisplay.open", title: "Displays", symbol: "sun.max.fill", tint: .yellow,
                     shortcut: settings.value.activation, perform: { [weak self] in self?.toggleFlyout(from: nil) })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Open Power Display", settings.value.activation)]
    }

    /// `mactoys://powerdisplay/<action>`: `open`/`show` (flyout), `settings`, `identify`, `rescan`,
    /// `apply-profile?id=3`, `save-profile?name=Work`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show", "flyout":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            toggleFlyout(from: nil)
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "identify":
            guard running else { return false }
            identify()
        case "rescan", "refresh":
            guard running else { return false }
            rescan()
        case "apply-profile", "profile":
            guard running, let id = Int(command.parameters["id"] ?? "") else { return false }
            applyProfile(id: id)
        case "save-profile":
            guard running else { return false }
            saveProfile(named: command.parameters["name"])
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("flyout", size: CGSize(width: 440, height: 520)) {
            AnyView(PowerDisplayFlyout.preview())
        },
         PreviewScene("flyout-linked", size: CGSize(width: 440, height: 640)) {
            AnyView(PowerDisplayFlyout.preview(linked: true))
        }]
    }
}

/// Target for the menu bar button (NSStatusBarButton needs an Objective-C target).
@MainActor
final class StatusTarget: NSObject {
    static let shared = StatusTarget()
    weak var module: PowerDisplayModule?

    @objc func clicked(_ sender: NSStatusBarButton) {
        module?.toggleFlyout(from: sender)
    }
}
