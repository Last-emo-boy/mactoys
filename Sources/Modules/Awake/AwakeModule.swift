import AppKit
import MacToysCore
import SwiftUI

/// Keeps the Mac (and optionally its displays) awake with IOKit power assertions,
/// indefinitely, for an interval or until a date — without touching Energy settings.
@MainActor
public final class AwakeModule: ToyModule {
    public let info = ModuleInfo(
        id: "awake", name: "Awake",
        summary: "Keep your Mac awake on demand, without touching Energy settings.",
        symbol: "cup.and.saucer.fill", tint: .orange, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["caffeinate", "sleep", "insomnia", "amphetamine", "display", "power"])

    let settings = Persisted("awake", default: AwakeSettings())
    let log = Log.for("awake")

    private let systemAssertion = PowerAssertion.system()
    private let displayAssertion = PowerAssertion.display()
    private var running = false
    private var screenLocked = false
    private var expiryTimer: Timer?
    private var tickTimer: Timer?
    private var processWatch: (pid: Int32, source: DispatchSourceProcess)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var statusItem = AwakeStatusItem(module: self)

    public init() {
        settings.onChange { [weak self] _ in self?.apply() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        screenLocked = ScreenLock.isLocked
        let restored = AwakeSchedule.restored(settings.value, now: Date())
        if restored != settings.value { settings.value = restored }

        let dnc = DistributedNotificationCenter.default()
        observe(dnc, ScreenLock.lockedNotification) { $0.screenLocked = true; $0.apply() }
        observe(dnc, ScreenLock.unlockedNotification) { $0.screenLocked = false; $0.apply() }
        observe(dnc, SettingsStore.externalChangeNotification) { $0.settings.reload() }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification) { $0.apply() }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.screenLocked = ScreenLock.isLocked; $0.apply() }
        observe(NotificationCenter.default, .NSSystemClockDidChange) { $0.apply() }
        apply()
    }

    public func stop() {
        guard running else { return }
        running = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        expiryTimer?.invalidate()
        expiryTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        watchProcess(nil)
        systemAssertion.release()
        displayAssertion.release()
        statusItem.remove()
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (AwakeModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    /// Brings assertions, timers and the menu bar item in line with the settings.
    func apply() {
        guard running else { return }
        let now = Date()
        let s = settings.value
        if s.mode != .off && AwakeSchedule.isExpired(s, now: now) {
            log.info("keep-awake session ended")
            settings.update { $0.mode = .off; $0.timedExpiresAt = nil }
            return // onChange calls apply again
        }
        if s.mode != .off, let pid = s.boundProcess, kill(pid, 0) != 0 && errno == ESRCH {
            log.info("bound process \(pid) is gone")
            settings.update { $0.mode = .off; $0.boundProcess = nil; $0.timedExpiresAt = nil }
            return
        }
        watchProcess(s.mode == .off ? nil : s.boundProcess)
        let awake = s.mode != .off
        let displayOn = awake && s.keepScreenOn && !(screenLocked && s.allowDisplaySleepWhenLocked)
        if awake { systemAssertion.hold() } else { systemAssertion.release() }
        if displayOn { displayAssertion.hold() } else { displayAssertion.release() }
        scheduleTimers(expiry: AwakeSchedule.expiry(of: s))
        if s.showMenuBarIcon { statusItem.install() } else { statusItem.remove() }
        statusItem.refresh()
    }

    /// Turns Awake off when the bound process exits (`mactoys awake --pid`).
    private func watchProcess(_ pid: Int32?) {
        guard processWatch?.pid != pid else { return }
        processWatch?.source.cancel()
        processWatch = nil
        guard let pid else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settings.value.boundProcess == pid else { return }
                self.settings.update { $0.mode = .off; $0.boundProcess = nil; $0.timedExpiresAt = nil }
            }
        }
        source.resume()
        processWatch = (pid, source)
    }

    private func scheduleTimers(expiry: Date?) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        guard let expiry else { return }
        let fire = Timer(fire: expiry, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        fire.tolerance = 1
        RunLoop.main.add(fire, forMode: .common)
        expiryTimer = fire
        // Keeps the "time left" text in the menu bar tooltip and switch current.
        let tick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.refresh() }
        }
        tick.tolerance = 5
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    // MARK: - Actions (menu, settings page, URL commands)

    var isAwake: Bool { settings.value.mode != .off }
    var isScreenLocked: Bool { screenLocked }
    var statusText: String { AwakeSchedule.statusText(settings.value, now: Date(), locked: screenLocked) }

    func turnOff() { settings.update { $0.mode = .off; $0.timedExpiresAt = nil; $0.boundProcess = nil } }

    func keepAwakeIndefinitely() {
        settings.update { $0.mode = .indefinite; $0.lastActiveMode = .indefinite; $0.timedExpiresAt = nil; $0.boundProcess = nil }
    }

    func keepAwake(forSeconds seconds: Int) {
        settings.update { AwakeSchedule.startTimed(&$0, seconds: seconds, now: Date()); $0.boundProcess = nil }
    }

    /// Starts a timed session with the interval chosen in Settings.
    func keepAwakeForInterval() {
        let s = settings.value
        keepAwake(forSeconds: max(60, AwakeSchedule.intervalSeconds(hours: s.intervalHours, minutes: s.intervalMinutes)))
    }

    func keepAwake(until date: Date) {
        settings.update { AwakeSchedule.startUntil(&$0, date: date, now: Date()); $0.boundProcess = nil }
    }

    /// Changes the Settings interval; a running timed session restarts with it (as in PowerToys).
    func setInterval(hours: Int, minutes: Int) {
        settings.update {
            $0.intervalHours = max(0, min(hours, 999))
            $0.intervalMinutes = max(0, min(minutes, 59))
            if $0.mode == .timed {
                let seconds = max(60, AwakeSchedule.intervalSeconds(hours: $0.intervalHours, minutes: $0.intervalMinutes))
                AwakeSchedule.startTimed(&$0, seconds: seconds, now: Date())
            }
        }
    }

    /// Changes the "until" target; in `until` mode it takes effect at once.
    func setUntilDate(_ date: Date) {
        settings.update { $0.untilDate = date }
    }

    /// Selects a mode from Settings, using the interval and date configured there.
    func select(_ mode: AwakeMode) {
        switch mode {
        case .off: turnOff()
        case .indefinite: keepAwakeIndefinitely()
        case .timed: keepAwakeForInterval()
        case .until: keepAwake(until: settings.value.untilDate)
        }
    }

    func toggle() {
        if isAwake { turnOff() } else { settings.update { $0 = AwakeSchedule.toggledOn($0, now: Date()); $0.boundProcess = nil } }
    }

    func perform(_ action: AwakeMenuAction) {
        switch action {
        case .off: turnOff()
        case .indefinite: keepAwakeIndefinitely()
        case .timed(let seconds): keepAwake(forSeconds: seconds)
        case .until: keepAwake(until: settings.value.untilDate)
        case .toggleScreen: settings.value.keepScreenOn.toggle()
        case .toggleLockedSleep: settings.value.allowDisplaySleepWhenLocked.toggle()
        case .settings: ModuleRegistry.shared.showSettings?(info.id)
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(AwakeSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "awake.toggle", title: "Awake", symbol: "cup.and.saucer", tint: .orange,
                     isOn: { [weak self] in self?.isAwake ?? false },
                     detail: { [weak self] in self?.statusText ?? "" },
                     perform: { [weak self] in self?.toggle() })]
    }

    /// `mactoys://awake/<action>`: `off`, `on`/`indefinite`, `toggle`,
    /// `timed?duration=1h30m` (also `seconds=`, `minutes=`, `hours=`), `until?time=23:30` (or `date=` ISO 8601),
    /// `screen?on=true|false`, `lockedsleep?on=true|false`, `open`/`settings`.
    public func handle(_ command: AppCommand) -> Bool {
        let p = command.parameters
        func flag(_ key: String) -> Bool? {
            guard let v = p[key]?.lowercased() else { return nil }
            return ["1", "true", "yes", "on"].contains(v)
        }
        if let screen = flag("screen") { settings.value.keepScreenOn = screen }
        switch command.action {
        case "open", "settings", "show":
            ModuleRegistry.shared.showSettings?(info.id)
        case "off", "disable":
            turnOff()
        case "on", "indefinite", "enable":
            keepAwakeIndefinitely()
        case "toggle":
            toggle()
        case "timed", "for":
            let seconds = Int(p["seconds"] ?? "") ?? (Int(p["minutes"] ?? "")).map { $0 * 60 }
                ?? (Int(p["hours"] ?? "")).map { $0 * 3600 } ?? AwakeSchedule.parseDuration(p["duration"] ?? "")
            if let seconds, seconds > 0 { keepAwake(forSeconds: seconds) } else { keepAwakeForInterval() }
        case "until", "expire":
            let text = p["date"] ?? p["time"] ?? ""
            if let date = AwakeSchedule.parseDate(text, now: Date()) { keepAwake(until: date) }
            else if text.isEmpty { keepAwake(until: settings.value.untilDate) }
            else { log.error("Awake: cannot parse until \(text, privacy: .public)"); return false }
        case "screen":
            settings.value.keepScreenOn = flag("on") ?? !settings.value.keepScreenOn
        case "lockedsleep":
            settings.value.allowDisplaySleepWhenLocked = flag("on") ?? !settings.value.allowDisplaySleepWhenLocked
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("menu", size: CGSize(width: 420, height: 400)) {
            var s = AwakeSettings()
            s.mode = .indefinite
            s.keepScreenOn = true
            s.allowDisplaySleepWhenLocked = false
            let now = Date()
            var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
            c.hour = 23
            c.minute = 30
            s.untilDate = Calendar.current.date(from: c) ?? now
            return AnyView(AwakeMenuPreview(entries: AwakeMenu.entries(s, now: min(now, s.untilDate.addingTimeInterval(-60))),
                                            highlighted: 2, mode: s.mode))
        }]
    }
}
