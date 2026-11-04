import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

// MARK: - Panels

/// The top panel of a display's shield: frost (or solid), ambient glow, clock and away message.
/// It takes every click so nothing reaches the apps behind it.
final class ShieldPanel: NSPanel {
    let root: BlurRootView
    private let effect = NSVisualEffectView()
    private var glow: AmbientGlowView?
    private let host: NSHostingView<LockShieldView>

    init(frame: CGRect, model: ShieldModel) {
        root = BlurRootView(frame: CGRect(origin: .zero, size: frame.size))
        host = NSHostingView(rootView: LockShieldView(model: model))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = LockLevels.shield
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .readOnly

        root.wantsLayer = true
        effect.frame = root.bounds
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .fullScreenUI
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        root.addSubview(effect)
        host.sizingOptions = []
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Solid shows an opaque dark screen; frosted and ambient let the window server frost the desktop.
    func apply(style: LockStyle, solid: Bool, animateGlow: Bool) {
        effect.isHidden = solid
        isOpaque = solid
        backgroundColor = solid ? NSColor(srgbRed: 0.035, green: 0.035, blue: 0.05, alpha: 1) : .clear
        if style == .ambient && !solid {
            if let glow {
                glow.animated = animateGlow
            } else {
                let g = AmbientGlowView(frame: root.bounds, animated: animateGlow)
                g.autoresizingMask = [.width, .height]
                root.addSubview(g, positioned: .below, relativeTo: host)
                glow = g
            }
        } else {
            glow?.removeFromSuperview()
            glow = nil
        }
    }
}

/// A key-capable borderless panel for the unlock island. Command-key shortcuts are swallowed (⌘Q,
/// ⌘W, ⌘H… must not reach the app behind the lock), except paste and select-all for the field.
final class IslandPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch Int(event.keyCode) {
            case kVK_ANSI_V: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case kVK_ANSI_A: return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            default: break
            }
        }
        // Everything else with ⌘ or ⌃ is consumed here.
        if !mods.isDisjoint(with: [.command, .control]) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Places the SwiftUI island in the panel.
    func setIsland(_ view: UnlockIslandView) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

// MARK: - Island placement

enum IslandPlacement {
    /// The notch areas of a display in global Cocoa coordinates (AppKit reports them relative to the
    /// display on some configurations).
    static func notchAreas(of screen: NSScreen) -> (left: CGRect?, right: CGRect?) {
        func global(_ r: CGRect?) -> CGRect? {
            guard let r else { return nil }
            if screen.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: r.midX, y: r.midY)) { return r }
            return r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        }
        return (global(screen.auxiliaryTopLeftArea), global(screen.auxiliaryTopRightArea))
    }

    static func frame(on screen: NSScreen, topMargin: CGFloat) -> (frame: CGRect, notch: CGFloat) {
        let areas = notchAreas(of: screen)
        return IslandLayout.frame(content: IslandMetrics.content, screen: screen.frame,
                                  notchHeight: screen.safeAreaInsets.top, leftOfNotch: areas.left,
                                  rightOfNotch: areas.right, topMargin: topMargin)
    }
}

// MARK: - Lock

/// Lock: covers every display at the shielding level, takes the keyboard and asks for Touch ID or the
/// password in a black island hanging from the notch.
@MainActor
final class LockController {
    let shield = ShieldModel()
    let unlock = UnlockModel()

    /// Called after the lock ends (authenticated, or the macOS lock was unlocked).
    var onUnlocked: (() -> Void)?
    /// What the guard should keep watching after the screen unlocks (App Lock may still hold apps).
    var residualGuardScope: () -> GuardMarker.Scope? = { nil }

    private(set) var isLocked = false
    private let settings: Persisted<PrivacyScreenSettings>
    private let guardian: LockGuard
    private var shields: [CGDirectDisplayID: (top: ShieldPanel, under: [BlurPanel])] = [:]
    private var island: IslandPanel?
    private var islandScreen: CGDirectDisplayID?
    private var summary: OverlayPanel?
    private var summaryHide: DispatchWorkItem?
    private var lease = PresentationLease()
    private var backoff = UnlockBackoff()
    private let biometric = BiometricPrompt()
    private var biometricsLockedOut = false
    private var handOffAt: Date?
    private var handedOff = false
    private var sawSystemLock = false
    private var previousApp: NSRunningApplication?
    private var hotkeysWereSuspended = false
    private var secureInputOn = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var watchdog: Timer?
    private let log = Log.for("privacyscreen")

    init(settings: Persisted<PrivacyScreenSettings>, guardian: LockGuard) {
        self.settings = settings
        self.guardian = guardian
    }

    private var solid: Bool {
        settings.value.lockStyle == .solid || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    // MARK: Lock

    /// Locks every display. `message` overrides the away message for this lock.
    func lock(message: String? = nil) {
        guard !isLocked else {
            reclaimKeyboard()
            return
        }
        isLocked = true
        let s = settings.value
        let now = Date()
        handOffAt = s.handOffMinutes > 0 ? now.addingTimeInterval(TimeInterval(s.handOffMinutes * 60)) : nil
        handedOff = false
        sawSystemLock = false
        biometricsLockedOut = false
        backoff.reset()
        hideSummary()
        previousApp = nil
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        configureModels(message: message)
        guardian.engage(.screen)
        syncShields()
        showIsland()
        reclaimKeyboard()
        startMonitoring()
        armBiometrics()
        Announce.say(String(localized: "Screen locked", comment: "VoiceOver announcement"))
        log.info("locked")
    }

    /// Re-applies style, clock and message while locked.
    func settingsChanged() {
        guard isLocked else { return }
        let s = settings.value
        shield.style = s.lockStyle
        shield.showClock = s.showClock
        for entry in shields.values {
            entry.top.apply(style: s.lockStyle, solid: solid, animateGlow: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    private func configureModels(message: String?) {
        let s = settings.value
        shield.style = s.lockStyle
        shield.showClock = s.showClock
        let note = (message ?? (s.showAwayMessage ? s.awayMessage : "")).trimmingCharacters(in: .whitespacesAndNewlines)
        shield.awayMessage = note.isEmpty ? nil : note
        unlock.title = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        unlock.appIcon = nil
        unlock.password = ""
        unlock.phase = .ready
        unlock.note = nil
        unlock.canCancel = false
        unlock.offersBiometrics = s.allowTouchID && BiometricPrompt.isAvailable
        unlock.onSubmit = { [weak self] in self?.submitPassword() }
        unlock.onCancel = {}
        unlock.onRetryBiometrics = { [weak self] in self?.armBiometrics() }
    }

    // MARK: Displays

    /// Covers every connected display (also ones plugged in while locked) and drops shields of
    /// displays that are gone.
    private func syncShields() {
        guard isLocked else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let style = settings.value.lockStyle
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = screen.displayID
            seen.insert(id)
            if let entry = shields[id] {
                if entry.top.frame != screen.frame {
                    entry.under.forEach { $0.setFrame(screen.frame, display: false) }
                    entry.top.setFrame(screen.frame, display: true)
                }
                if !entry.top.isVisible {
                    entry.under.forEach { $0.orderFrontRegardless() }
                    entry.top.orderFrontRegardless()
                }
                continue
            }
            let top = ShieldPanel(frame: screen.frame, model: shield)
            top.apply(style: style, solid: solid, animateGlow: !reduceMotion)
            top.root.onMouseDown = { [weak self] in self?.reclaimKeyboard() }
            // Two more frost layers under the top one make the desktop unrecognizable.
            let under: [BlurPanel] = solid ? [] : (0..<2).map { _ in
                let p = BlurPanel(frame: screen.frame, level: LockLevels.shield, interactive: false)
                p.configure(washOpacity: 0, dark: true)
                p.sharingType = .readOnly
                return p
            }
            under.forEach { $0.orderFrontRegardless() }
            top.orderFrontRegardless()
            shields[id] = (top, under)
        }
        for (id, entry) in shields where !seen.contains(id) {
            entry.under.forEach { $0.close() }
            entry.top.close()
            shields[id] = nil
        }
        island?.orderFrontRegardless()
        if let id = islandScreen, !seen.contains(id) { placeIsland() }
    }

    private func removeShields() {
        for entry in shields.values {
            entry.under.forEach { $0.orderOut(nil); $0.close() }
            entry.top.orderOut(nil)
            entry.top.close()
        }
        shields.removeAll()
        island?.orderOut(nil)
        island?.close()
        island = nil
        islandScreen = nil
    }

    private func showIsland() {
        let panel = island ?? IslandPanel(frame: .zero, level: LockLevels.island)
        panel.onEscape = { [weak self] in self?.unlock.password = "" }
        island = panel
        placeIsland()
    }

    /// Puts the island on the display under the pointer (hanging from its notch when it has one).
    private func placeIsland() {
        guard let panel = island else { return }
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let placed = IslandPlacement.frame(on: screen, topMargin: 14)
        shield.islandClearance = placed.frame.height
        if islandScreen != screen.displayID || panel.frame != placed.frame || panel.contentView == nil {
            panel.setFrame(placed.frame, display: false)
            panel.setIsland(UnlockIslandView(model: unlock, notch: placed.notch,
                                             biometricSlot: unlock.offersBiometrics ? biometric.slot : nil))
            islandScreen = screen.displayID
        }
        panel.orderFrontRegardless()
    }

    // MARK: Keyboard

    /// Activates MacToys, makes the island key and hides the Dock and menu bar with process
    /// switching, Force Quit and the power-key panel disabled.
    private func reclaimKeyboard() {
        guard isLocked, !SystemLock.isScreenLocked else { return }
        if NSScreen.underMouse?.displayID != islandScreen { placeIsland() }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        island?.makeKeyAndOrderFront(nil)
        unlock.focusCount += 1
        if !lease.isEngaged {
            let options = lease.engage(current: NSApp.presentationOptions)
            NSApp.presentationOptions = options
            hotkeysWereSuspended = HotkeyCenter.shared.isSuspended
            HotkeyCenter.shared.isSuspended = true
        } else if NSApp.presentationOptions != PresentationLease.lockOptions {
            NSApp.presentationOptions = PresentationLease.lockOptions
        }
        if !secureInputOn {
            // Keeps other apps' event taps from seeing what is typed while locked.
            EnableSecureEventInput()
            secureInputOn = true
        }
    }

    private func releaseKeyboard() {
        if secureInputOn {
            DisableSecureEventInput()
            secureInputOn = false
        }
        if let restore = lease.release() {
            NSApp.presentationOptions = restore
            HotkeyCenter.shared.isSuspended = hotkeysWereSuspended
        }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        stopMonitoring()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.syncShields() }
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification) { me in
            DispatchQueue.main.async { me.reclaimKeyboard() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didActivateApplicationNotification) { me in
            DispatchQueue.main.async { me.reclaimKeyboard() }
        }
        observe(ws, NSWorkspace.didWakeNotification) { me in
            me.syncShields()
            me.checkSystemLock()
        }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.checkSystemLock() }
        observe(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.settingsChanged() }
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, SystemLock.lockedNotification) { $0.checkSystemLock() }
        observe(dnc, SystemLock.unlockedNotification) { $0.checkSystemLock() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopMonitoring() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        watchdog?.invalidate()
        watchdog = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (LockController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    /// Twice a second while locked: every display covered, keyboard ours, hand-off due, the macOS
    /// lock seen coming and going.
    private func watch() {
        guard isLocked else { return }
        let ids = Set(NSScreen.screens.map(\.displayID))
        if ids != Set(shields.keys) || shields.values.contains(where: { !$0.top.isVisible }) { syncShields() }
        checkSystemLock()
        guard isLocked else { return }
        if let id = NSScreen.underMouse?.displayID, id != islandScreen { placeIsland() }
        if let at = handOffAt, !handedOff, Date() >= at {
            handedOff = true
            let how = SystemLock.lockNow()
            log.info("handed off to the macOS lock (\(how, privacy: .public))")
        }
        if !SystemLock.isScreenLocked && (!NSApp.isActive || island?.isKeyWindow != true) { reclaimKeyboard() }
        if case .waiting = unlock.phase, backoff.canTryPassword(at: Date()) {
            unlock.phase = .ready
            unlock.focusCount += 1
        }
    }

    /// Unlocking the real macOS lock proves the user's identity too: when the session went through a
    /// lock and is unlocked again, the shield goes away. The session dictionary is checked rather than
    /// trusting the (forgeable) distributed notifications.
    private func checkSystemLock() {
        guard isLocked else { return }
        if SystemLock.isScreenLocked {
            sawSystemLock = true
        } else if sawSystemLock {
            finishUnlock(reason: "macOS unlock")
        }
    }

    // MARK: Unlocking

    private func submitPassword() {
        guard isLocked, unlock.phase == .ready else { return }
        let now = Date()
        guard backoff.canTryPassword(at: now) else {
            unlock.phase = .waiting(until: backoff.nextAttempt ?? now)
            return
        }
        let password = unlock.password
        guard !password.isEmpty else { return }
        unlock.password = ""
        unlock.phase = .verifying
        unlock.note = nil
        Task { @MainActor [weak self] in
            let ok = await PasswordCheck.verify(password)
            guard let self, self.isLocked else { return }
            if ok {
                self.finishUnlock(reason: "password")
            } else {
                self.passwordFailed()
            }
        }
    }

    private func passwordFailed() {
        let now = Date()
        backoff.recordFailure(.password, at: now)
        unlock.note = .wrongPassword
        unlock.shakeCount += 1
        if let next = backoff.nextAttempt, next > now {
            unlock.phase = .waiting(until: next)
        } else {
            unlock.phase = .ready
        }
        unlock.focusCount += 1
        Announce.say(String(localized: "Wrong password", comment: "VoiceOver announcement"))
    }

    private func armBiometrics() {
        guard isLocked, unlock.offersBiometrics, !biometricsLockedOut else { return }
        biometric.begin(reason: String(localized: "unlock your Mac", comment: "Touch ID reason (shown on an Apple Watch): '… wants to unlock your Mac'")) { [weak self] outcome in
            guard let self, self.isLocked else { return }
            switch outcome {
            case .success:
                self.finishUnlock(reason: "Touch ID")
            case .failed:
                self.backoff.recordFailure(.touchID, at: Date())
                self.unlock.note = .touchIDFailed
                // Offer the sensor again after a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.armBiometrics() }
            case .lockedOut:
                self.biometricsLockedOut = true
                self.unlock.note = .touchIDLocked
            case .unavailable:
                self.unlock.offersBiometrics = false
                self.placeIsland()
            case .cancelled:
                break
            }
        }
    }

    /// Ends the lock after authentication.
    private func finishUnlock(reason: String) {
        guard isLocked else { return }
        isLocked = false
        log.info("unlocked (\(reason, privacy: .public))")
        stopMonitoring()
        biometric.cancel()
        unlock.password = ""
        releaseKeyboard()
        let attempts = backoff.attempts
        backoff.reset()
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.removeShields()
            self.restoreFocus()
            Announce.say(String(localized: "Unlocked", comment: "VoiceOver announcement"))
            if !attempts.isEmpty { self.showSummary(attempts) }
            self.onUnlocked?()
        }
        if let scope = residualGuardScope() {
            // The guard stays for App Lock; give it a moment to drop its backup shield.
            guardian.engage(scope)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { complete() }
        } else {
            guardian.disengage(then: complete)
        }
    }

    /// Ends the lock without authentication because Privacy Screen stops (disabled, MacToys quits):
    /// the real macOS lock takes over first, so nothing is revealed.
    func handOffAndTearDown() {
        guard isLocked else { return }
        let how = SystemLock.lockNow()
        log.notice("stopping while locked; handed off to the macOS lock (\(how, privacy: .public))")
        for _ in 0..<60 where !SystemLock.isScreenLocked { usleep(50_000) }
        isLocked = false
        stopMonitoring()
        biometric.cancel()
        unlock.password = ""
        releaseKeyboard()
        backoff.reset()
        guardian.disengage {}
        removeShields()
        hideSummary()
    }

    private func restoreFocus() {
        defer { previousApp = nil }
        guard let app = previousApp, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    // MARK: Failed attempts summary

    private func showSummary(_ attempts: [FailedAttempt]) {
        hideSummary()
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 420, height: CGFloat(170 + min(attempts.count, 6) * 33))
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12,
                           width: size.width, height: size.height)
        let panel = OverlayPanel(frame: frame, interactive: true, acceptsKey: false, level: .statusBar)
        panel.setContent(FailedAttemptsView(attempts: attempts) { [weak self] in self?.hideSummary() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8))
        panel.orderFrontRegardless()
        summary = panel
        Announce.say(String(localized: "\(attempts.count) failed attempts while locked",
                            comment: "VoiceOver announcement after unlocking"))
        let work = DispatchWorkItem { [weak self] in self?.hideSummary() }
        summaryHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func hideSummary() {
        summaryHide?.cancel()
        summaryHide = nil
        summary?.orderOut(nil)
        summary?.close()
        summary = nil
    }

    /// Called when the guard died while locked: someone is tampering, so lock the Mac for real.
    func guardDiedWhileLocked() {
        guard isLocked else { return }
        handedOff = true
        SystemLock.lockNow()
        guardian.respawnIfNeeded()
    }
}

/// VoiceOver announcements.
enum Announce {
    @MainActor static func say(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
