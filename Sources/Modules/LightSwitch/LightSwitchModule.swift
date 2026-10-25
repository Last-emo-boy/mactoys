import AppKit
import CoreLocation
import MacToysCore
import Observation
import SwiftUI

/// Live state the settings page and the menu bar switch show.
@MainActor
@Observable
final class LightSwitchState {
    var current: Appearance = SystemAppearance.current
    /// Why the last switch failed (Automation denied, script error).
    var lastError: String?
    var automationDenied = false
    var locating = false
    var locationError: String?
}

/// Switches the macOS appearance between light and dark on a schedule (fixed hours, sunset to
/// sunrise, or Night Shift's schedule), with a toggle shortcut, optional wallpapers and Power Display profiles.
@MainActor
public final class LightSwitchModule: ToyModule {
    public let info = ModuleInfo(
        id: "lightswitch", name: "Light Switch",
        summary: "Switch between light and dark appearance on a schedule or at sunrise and sunset.",
        symbol: "circle.lefthalf.filled", tint: .yellow, category: .systemTools,
        permissions: [], enabledByDefault: false,
        keywords: ["dark mode", "light mode", "theme", "appearance", "night", "sunset", "sunrise"])

    let settings = Persisted("lightswitch", default: LightSwitchSettings())
    let state = LightSwitchState()
    let log = Log.for("lightswitch")

    private var running = false
    private var timer: Timer?
    private var heartbeat: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastScheduleKey: LightSwitchSettings.ScheduleKey?
    private var lastShortcut: Shortcut??
    private var locationRequest: LocationRequest?

    public init() {
        settings.onChange { [weak self] new in self?.settingsChanged(new) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        state.current = SystemAppearance.current
        registerHotkey()
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification) { $0.evaluate(force: false) }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.evaluate(force: false) }
        observe(NotificationCenter.default, .NSSystemClockDidChange) { $0.evaluate(force: false) }
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange) { $0.evaluate(force: false) }
        observe(NotificationCenter.default, .NSCalendarDayChanged) { $0.evaluate(force: false) }
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, Notification.Name("AppleInterfaceThemeChangedNotification")) { $0.state.current = SystemAppearance.current }
        observe(dnc, SettingsStore.externalChangeNotification) { $0.settings.reload() }
        lastScheduleKey = settings.value.scheduleKey
        evaluate(force: false)
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister("lightswitch.toggle")
        lastShortcut = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        heartbeat?.invalidate()
        heartbeat = nil
        locationRequest = nil
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (LightSwitchModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    private func registerHotkey() {
        let shortcut = settings.value.toggleShortcut
        guard lastShortcut != .some(shortcut) else { return }
        lastShortcut = .some(shortcut)
        HotkeyCenter.shared.register("lightswitch.toggle", shortcut) { [weak self] in self?.toggle() }
    }

    private func settingsChanged(_ new: LightSwitchSettings) {
        guard running else { return }
        registerHotkey()
        if new.scheduleKey != lastScheduleKey {
            lastScheduleKey = new.scheduleKey
            // A relevant setting changed: drop any manual override and follow the new schedule now.
            settings.update { $0.manualOverrideUntil = nil }
            evaluate(force: true)
        } else {
            scheduleTimers()
        }
    }

    // MARK: - Schedule

    var nightShift: NightShiftSchedule? { NightShiftSchedule.current() }

    func currentPlan(now: Date = Date()) -> SchedulePlan? {
        let s = settings.value
        let source = LightSwitchSchedule.source(for: s, nightShift: s.scheduleMode == .followNightShift ? nightShift : nil)
        return LightSwitchSchedule.plan(source, now: now)
    }

    /// Applies the schedule when a new period began (or `force`), then waits for the next change.
    func evaluate(force: Bool) {
        guard running else { return }
        let now = Date()
        state.current = SystemAppearance.current
        let plan = currentPlan(now: now)
        if let until = settings.value.manualOverrideUntil, now >= until {
            settings.update { $0.manualOverrideUntil = nil }
        }
        switch LightSwitchSchedule.decide(plan: plan, settings: settings.value, now: now, force: force) {
        case let .apply(appearance, periodStart):
            settings.update { $0.lastHandledPeriodStart = periodStart; $0.manualOverrideUntil = nil }
            log.info("schedule → \(appearance.rawValue, privacy: .public)")
            switchTo(appearance, announce: false)
        case .keep:
            break
        }
        scheduleTimers()
    }

    private func scheduleTimers() {
        timer?.invalidate()
        timer = nil
        let s = settings.value
        let candidates = [currentPlan()?.nextChange, s.manualOverrideUntil].compactMap { $0 }
        if let next = candidates.min() {
            let t = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(force: false) }
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        // Night Shift's schedule can change in System Settings without telling anyone.
        let wantsHeartbeat = s.scheduleMode == .followNightShift
        if wantsHeartbeat && heartbeat == nil {
            let h = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(force: false) }
            }
            h.tolerance = 60
            RunLoop.main.add(h, forMode: .common)
            heartbeat = h
        } else if !wantsHeartbeat {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    // MARK: - Switching

    func toggle() { setAppearance(SystemAppearance.current.opposite) }

    /// A manual switch (shortcut, menu bar, URL, CLI): holds until the next scheduled change.
    func setAppearance(_ appearance: Appearance) {
        if let plan = currentPlan() {
            settings.update {
                $0.manualOverrideUntil = appearance != plan.appearance ? plan.nextChange : nil
                $0.lastHandledPeriodStart = plan.periodStart
            }
            scheduleTimers()
        }
        switchTo(appearance, announce: true)
    }

    private func switchTo(_ appearance: Appearance, announce: Bool) {
        let alreadyThere = SystemAppearance.current == appearance
        let finish: @MainActor (Result<Void, SystemAppearance.Failure>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state.current = appearance
                self.state.lastError = nil
                self.state.automationDenied = false
                self.applyExtras(appearance)
                if announce && self.settings.value.showHUD {
                    HUD.show(appearance.modeTitle, symbol: appearance == .dark ? "moon.fill" : "sun.max.fill")
                }
            case .failure(let failure):
                self.log.error("\(failure.localizedDescription, privacy: .public)")
                self.state.lastError = failure.localizedDescription
                self.state.automationDenied = failure == .notPermitted
                if announce {
                    if failure == .notPermitted {
                        HUD.show("Allow MacToys to control System Events", symbol: "exclamationmark.shield")
                        PermissionCenter.shared.openSettings(.automation)
                    } else {
                        HUD.show("Couldn't switch appearance", symbol: "exclamationmark.triangle")
                    }
                }
            }
        }
        if alreadyThere { finish(.success(())) } else { SystemAppearance.set(appearance, completion: finish) }
    }

    private func applyExtras(_ appearance: Appearance) {
        let s = settings.value
        if s.changeWallpaper, let path = appearance == .dark ? s.darkWallpaper : s.lightWallpaper, !path.isEmpty {
            SystemAppearance.setWallpaper(path)
        }
        if let id = appearance == .dark ? s.darkDisplayProfile : s.lightDisplayProfile {
            Services.applyDisplayProfile?(id)
        }
    }

    // MARK: - Location

    func locate() {
        state.locating = true
        state.locationError = nil
        let request = LocationRequest()
        locationRequest = request
        request.start { [weak self] result in
            guard let self else { return }
            self.state.locating = false
            self.locationRequest = nil
            switch result {
            case .success(let c):
                self.settings.update {
                    $0.latitude = (c.latitude * 10000).rounded() / 10000
                    $0.longitude = (c.longitude * 10000).rounded() / 10000
                }
            case .failure(let error):
                self.state.locationError = error.localizedDescription
            }
        }
    }

    func requestAutomation() {
        SystemAppearance.requestAutomation { [weak self] granted in
            guard let self else { return }
            self.state.automationDenied = !granted
            if granted { self.state.lastError = nil } else { PermissionCenter.shared.openSettings(.automation) }
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(LightSwitchSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "lightswitch.toggle", title: "Light Switch", symbol: "circle.lefthalf.filled", tint: .yellow,
                     shortcut: settings.value.toggleShortcut,
                     isOn: { SystemAppearance.current == .dark },
                     detail: { [weak self] in
                         guard let self else { return "" }
                         return LightSwitchSchedule.describeNext(plan: self.currentPlan(), mode: self.settings.value.scheduleMode, now: Date())
                     },
                     perform: { [weak self] in self?.toggle() })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Toggle light and dark mode", settings.value.toggleShortcut)]
    }

    /// `mactoys://lightswitch/<action>`: `toggle`, `light`, `dark`,
    /// `schedule?mode=off|fixed-hours|sunset-to-sunrise|follow-night-shift`, `refresh`, `open`/`settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "settings", "show":
            ModuleRegistry.shared.showSettings?(info.id)
        case "toggle":
            guard running else { return false }
            toggle()
        case "light", "dark":
            guard running, let a = Appearance(rawValue: command.action) else { return false }
            setAppearance(a)
        case "schedule":
            guard let mode = ScheduleMode(cliName: command.parameters["mode"] ?? "") else { return false }
            settings.value.scheduleMode = mode
        case "refresh":
            evaluate(force: true)
        default:
            return false
        }
        return true
    }
}
