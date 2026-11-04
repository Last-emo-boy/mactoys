import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Live mode state for the settings page and menu bar.
@MainActor
@Observable
final class PrivacyStatus {
    var modes = PrivacyModes()
    var lockedApps: [String] = []
}

/// Privacy Screen: blur or lock the screen, the windows around the one you're using, or private apps.
/// Everything is drawn by the window server over windows that keep running and never move; no
/// permission is needed (no screen capture, no Accessibility, no Input Monitoring).
@MainActor
public final class PrivacyScreenModule: ToyModule {
    public let info = ModuleInfo(
        id: "privacyscreen", name: "Privacy Screen",
        summary: "Blur or lock your screen in place, keep private apps blurred and hide everything but the window you're using.",
        symbol: "eye.slash.fill", tint: .purple, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["privacy", "blur", "lock", "screen lock", "touch id", "focus", "hide", "app lock", "private apps",
                   "away", "hot corner", "shield"])

    let settings = Persisted("privacyscreen", default: PrivacyScreenSettings())
    let status = PrivacyStatus()
    private let log = Log.for("privacyscreen")

    private var running = false
    private let poller = WindowPoller()
    private let guardian = LockGuard()
    private lazy var lockController = LockController(settings: settings, guardian: guardian)
    private lazy var screenBlur = ScreenBlurController()
    private lazy var focus = FocusBlurController(poller: poller)
    private lazy var privateApps = PrivateAppsController(poller: poller)
    private lazy var appLock = AppLockController(poller: poller)
    private let away = AwayMonitor()
    private let hotCorner = HotCornerMonitor()
    private var lastOtherApp: NSRunningApplication?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var registeredShortcuts: [Shortcut?] = []

    private var modes: PrivacyModes {
        get { status.modes }
        set { if status.modes != newValue { status.modes = newValue } }
    }

    public init() {
        status.modes.privateApps = settings.value.privateAppsOn
        settings.onChange { [weak self] in self?.settingsChanged($0) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        let s = settings.value
        modes.privateApps = s.privateAppsOn

        guardian.onUnexpectedExit = { [weak self] in self?.guardDied() }
        lockController.onUnlocked = { [weak self] in
            guard let self else { return }
            self.modes.apply(.unlock)
            self.applyModes()
        }
        lockController.residualGuardScope = { [weak self] in
            (self?.appLock.hasLockedApps ?? false) ? .apps : nil
        }
        screenBlur.onDismiss = { [weak self] in self?.request(.clearBlur) }
        appLock.allowsTouchID = { [weak self] in self?.settings.value.allowTouchID ?? true }
        appLock.onChange = { [weak self] in self?.appLocksChanged() }
        away.isLocked = { [weak self] in self?.lockController.isLocked ?? false }
        away.onAction = { [weak self] action in
            switch action {
            case .blur: self?.request(.blur)
            case .lock: self?.request(.lock)
            }
        }
        hotCorner.onTrigger = { [weak self] in
            guard let self else { return }
            self.request(self.settings.value.hotCornerAction == .lock ? .lock : .blur)
        }

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didActivateApplicationNotification) { me, note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                me.lastOtherApp = app
            }
        }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) { me, _ in
            me.settings.reload()
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastOtherApp = front
        }

        registerHotkeys(s)
        configureTimers(s)
        applyModes()
    }

    public func stop() {
        guard running else { return }
        // Something locked must never be revealed by Privacy Screen going away (disabled, MacToys
        // quitting): the real macOS lock takes over first.
        if lockController.isLocked {
            lockController.handOffAndTearDown()
        } else if appLock.hasLockedApps {
            SystemLock.lockNow()
            for _ in 0..<60 where !SystemLock.isScreenLocked { usleep(50_000) }
        }
        appLock.tearDown()
        running = false
        modes.apply(.unlock)
        modes.apply(.clearBlur)
        screenBlur.hide(restoringFocus: false)
        focus.stop()
        privateApps.stop()
        away.stop()
        hotCorner.stop()
        HotkeyCenter.shared.unregister(prefix: "privacyscreen.")
        registeredShortcuts = []
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        guardian.disengage {}
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (PrivacyScreenModule, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self, note)
            }
        }
        observers.append((center, token))
    }

    private func settingsChanged(_ s: PrivacyScreenSettings) {
        if modes.privateApps != s.privateAppsOn { modes.privateApps = s.privateAppsOn }
        guard running else { return }
        registerHotkeys(s)
        configureTimers(s)
        lockController.settingsChanged()
        screenBlur.update(strength: s.screenBlurStrength)
        focus.update(strength: s.focusBlurStrength)
        applyModes()
    }

    private func configureTimers(_ s: PrivacyScreenSettings) {
        away.configure(blurMinutes: s.blurAfterIdleMinutes, lockMinutes: s.lockAfterIdleMinutes,
                       pauseWhileDisplayKeptAwake: s.pauseWhileDisplayKeptAwake)
        hotCorner.configure(corner: s.hotCorner, dwell: s.hotCornerDelay)
    }

    private func registerHotkeys(_ s: PrivacyScreenSettings) {
        let wanted = [s.lockShortcut, s.blurShortcut, s.focusShortcut, s.privateAppsShortcut, s.appLockShortcut]
        guard wanted != registeredShortcuts else { return }
        registeredShortcuts = wanted
        let hk = HotkeyCenter.shared
        hk.register("privacyscreen.lock", s.lockShortcut) { [weak self] in self?.request(.lock) }
        hk.register("privacyscreen.blur", s.blurShortcut) { [weak self] in self?.request(.toggleBlur) }
        hk.register("privacyscreen.focus", s.focusShortcut) { [weak self] in self?.toggleFocus() }
        hk.register("privacyscreen.private", s.privateAppsShortcut) { [weak self] in self?.togglePrivateApps() }
        hk.register("privacyscreen.applock", s.appLockShortcut) { [weak self] in self?.lockFrontmostApp() }
    }

    // MARK: - Modes

    /// Applies a mode change and brings the overlays in line with it.
    func request(_ request: PrivacyModes.Request, message: String? = nil) {
        guard running, request != .unlock else { return }
        var next = modes
        next.apply(request)
        let lockNow = next.locked && !modes.locked
        modes = next
        if next.privateApps != settings.value.privateAppsOn { settings.value.privateAppsOn = next.privateApps }
        if lockNow { lockController.lock(message: message) }
        applyModes()
    }

    private func applyModes() {
        guard running else { return }
        let s = settings.value
        let m = modes
        if m.showsScreenBlur { screenBlur.show(strength: s.screenBlurStrength) } else { screenBlur.hide(restoringFocus: !m.locked) }
        if m.showsFocusBlur { focus.start(strength: s.focusBlurStrength) } else { focus.stop() }
        if m.showsPrivateApps {
            privateApps.start(strength: s.focusBlurStrength, apps: s.privateApps, peekWithOption: s.peekWithOption)
        } else {
            privateApps.stop()
        }
    }

    func toggleFocus() {
        request(.toggleFocus)
        HUD.show(modes.focusBlur ? String(localized: "Focus Blur on", comment: "HUD") : String(localized: "Focus Blur off", comment: "HUD"),
                 symbol: "scope")
    }

    func togglePrivateApps() {
        request(.togglePrivateApps)
        HUD.show(modes.privateApps ? String(localized: "Private Apps on", comment: "HUD") : String(localized: "Private Apps off", comment: "HUD"),
                 symbol: "hand.raised.fill")
    }

    /// Locks the frontmost app (or the app that was in front before MacToys).
    func lockFrontmostApp() {
        guard running else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var target = NSWorkspace.shared.frontmostApplication
        if target?.processIdentifier == own { target = lastOtherApp }
        guard let app = target, !app.isTerminated, app.processIdentifier != own,
              app.activationPolicy == .regular else {
            HUD.show("No app to lock", symbol: "lock.app.dashed")
            return
        }
        appLock.lock(app)
    }

    private func appLocksChanged() {
        status.lockedApps = appLock.lockedNames
        guard running, !lockController.isLocked else { return }
        if appLock.hasLockedApps {
            guardian.engage(.apps)
        } else if guardian.scope != nil {
            guardian.disengage {}
        }
    }

    /// The guard died while something is locked: treat it as tampering.
    private func guardDied() {
        if lockController.isLocked {
            lockController.guardDiedWhileLocked()
        } else if appLock.hasLockedApps {
            SystemLock.lockNow()
            guardian.respawnIfNeeded()
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(PrivacyScreenSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        let s = settings.value
        return [
            QuickAction(id: "privacyscreen.lock", title: "Lock Screen", symbol: "lock.fill", tint: .purple,
                        shortcut: s.lockShortcut) { [weak self] in self?.request(.lock) },
            QuickAction(id: "privacyscreen.blur", title: "Blur Screen", symbol: "eye.slash.fill", tint: .purple,
                        shortcut: s.blurShortcut) { [weak self] in self?.request(.blur) },
            QuickAction(id: "privacyscreen.applock", title: "Lock App", symbol: "lock.app.dashed", tint: .purple,
                        shortcut: s.appLockShortcut) { [weak self] in self?.lockFrontmostApp() },
            QuickAction(id: "privacyscreen.focus", title: "Focus Blur", symbol: "scope", tint: .purple,
                        shortcut: s.focusShortcut,
                        isOn: { [weak self] in self?.status.modes.focusBlur ?? false },
                        detail: { String(localized: "Only the front window stays sharp") }) { [weak self] in self?.request(.toggleFocus) },
            QuickAction(id: "privacyscreen.private", title: "Private Apps", symbol: "hand.raised.fill", tint: .purple,
                        shortcut: s.privateAppsShortcut,
                        isOn: { [weak self] in self?.status.modes.privateApps ?? false },
                        detail: { [weak self] in self?.privateAppsDetail ?? "" }) { [weak self] in self?.request(.togglePrivateApps) },
        ]
    }

    /// "Messages, Mail, Slack".
    var privateAppsDetail: String {
        let apps = settings.value.privateApps
        guard !apps.isEmpty else { return String(localized: "No apps chosen", comment: "Private Apps switch detail") }
        return apps.formatted(.list(type: .and, width: .narrow))
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [
            ShortcutBinding("Lock Screen", s.lockShortcut),
            ShortcutBinding("Blur Screen", s.blurShortcut),
            ShortcutBinding("Focus Blur", s.focusShortcut),
            ShortcutBinding("Private Apps", s.privateAppsShortcut),
            ShortcutBinding("Lock App", s.appLockShortcut),
        ]
    }

    /// `mactoys://privacyscreen/<action>`: `lock` (optional `message=`), `blur`, `focus`, `private`,
    /// `applock`, `open`/`settings`. Actions only ever turn protection on — none unlocks, clears a
    /// blur or switches a mode off.
    public func handle(_ command: AppCommand) -> Bool {
        guard let action = PrivacyURLAction(action: command.action) else { return false }
        if action == .settings {
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        }
        guard running else {
            log.notice("Privacy Screen is off; ignoring \(command.action, privacy: .public)")
            return false
        }
        if action == .appLock {
            lockFrontmostApp()
        } else if let request = action.request {
            let message = command.parameters["message"].flatMap { $0.isEmpty ? nil : $0 }
            self.request(request, message: message)
        }
        return true
    }

    public var previewScenes: [PreviewScene] { PrivacyPreviews.scenes }
}
