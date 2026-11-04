import AppKit
import MacToysCore
import SwiftUI

/// A frosted cover over one visible piece of a locked app's window. It swallows clicks; a click
/// brings up the unlock island.
@MainActor
private final class AppCover {
    let under: BlurPanel
    let top: BlurPanel
    private var badgeKey: String?

    init(onClick: @escaping () -> Void) {
        under = BlurPanel(frame: CGRect(x: 0, y: 0, width: 10, height: 10), level: BlurLevels.window, interactive: false)
        under.configure(washOpacity: 0, dark: true)
        top = BlurPanel(frame: CGRect(x: 0, y: 0, width: 10, height: 10), level: BlurLevels.window, interactive: true)
        top.configure(washOpacity: 0.3, dark: true)
        top.root.onMouseDown = onClick
    }

    /// - Parameters:
    ///   - part: the visible piece, global top-left coordinates.
    ///   - window: the whole window (for its rounded corners).
    ///   - badge: the app shown in the middle of the piece, or nil.
    func place(part: CGRect, window: CGRect, badge: (name: String, icon: NSImage?)?) {
        let frame = ScreenGeometry.toCocoa(part)
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -part.minX, ty: part.maxY)
        let mask = MaskPaths.visible(parts: [part], of: window).copy(using: &t)
        for p in [under, top] {
            if p.frame != frame { p.setFrame(frame, display: false) }
            p.setMask(mask)
        }
        let key = badge.map { "\($0.name)" }
        if key != badgeKey {
            badgeKey = key
            if let badge {
                top.setOverlay(AppLockBadge(name: badge.name, icon: badge.icon))
            } else {
                top.setOverlay(Optional<AppLockBadge>.none)
            }
        }
        if !top.isVisible {
            under.orderFrontRegardless()
            top.orderFrontRegardless()
        }
    }

    func close() {
        under.orderOut(nil)
        top.orderOut(nil)
        under.close()
        top.close()
    }
}

/// The app's icon and name on its cover.
struct AppLockBadge: View {
    let name: String
    let icon: NSImage?

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 64, height: 64)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.15)).frame(width: 64, height: 64)
                }
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.85)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .offset(x: 6, y: 6)
            }
            Text("“\(name)” is locked", comment: "App Lock cover; the placeholder is the app's name")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Click to unlock with Touch ID or your password.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// App Lock: locks the frontmost app. Its windows are covered by frosted panels that swallow clicks,
/// and bringing it forward shows the unlock island until Touch ID or the password approve.
@MainActor
final class AppLockController {
    struct LockedApp: Equatable {
        let pid: pid_t
        let name: String
        let icon: NSImage?
    }

    /// Locked apps changed (lock, unlock, quit).
    var onChange: (() -> Void)?
    /// Whether Touch ID may be offered (the Lock setting applies to App Lock too).
    var allowsTouchID: () -> Bool = { true }
    let unlock = UnlockModel()
    private(set) var locked: [pid_t: LockedApp] = [:]
    private let poller: WindowPoller
    private var covers: [AppCover] = []
    private var lastKey: [WindowSample]?
    private var lastParts: [[CGRect]]?
    private var island: IslandPanel?
    private var islandFor: pid_t?
    private var lastOtherApp: NSRunningApplication?
    private var backoff = UnlockBackoff()
    private let biometric = BiometricPrompt()
    private var biometricsLockedOut = false
    private var observers: [NSObjectProtocol] = []
    private var islandResign: NSObjectProtocol?
    private var waitTimer: Timer?
    private let log = Log.for("privacyscreen")

    init(poller: WindowPoller) {
        self.poller = poller
        unlock.canCancel = true
    }

    var hasLockedApps: Bool { !locked.isEmpty }

    /// Names of the locked apps, alphabetically.
    var lockedNames: [String] { locked.values.map(\.name).sorted() }

    /// Locks `app` (the frontmost app, or the last one before MacToys).
    func lock(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, locked[pid] == nil else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? String(localized: "This app", comment: "App Lock: name used when an app has none")
        locked[pid] = LockedApp(pid: pid, name: name, icon: app.icon)
        if locked.count == 1 { startTracking() }
        log.info("app locked")
        Announce.say(String(localized: "\(name) is locked", comment: "VoiceOver announcement; the placeholder is an app name"))
        // Step away from it, so its windows stop taking keys.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { showIsland(for: pid) }
        poller.poke()
        onChange?()
    }

    /// Removes every lock without authentication (Privacy Screen stops; the caller has locked the Mac).
    func tearDown() {
        locked.removeAll()
        stopTracking()
        onChange?()
    }

    // MARK: Tracking

    private func startTracking() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.terminated(pid) }
        })
        poller.subscribe("applock") { [weak self] scene, changed in
            guard changed else { return }
            self?.render(scene)
        }
    }

    private func stopTracking() {
        poller.unsubscribe("applock")
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        covers.forEach { $0.close() }
        covers.removeAll()
        lastKey = nil
        lastParts = nil
        hideIsland(restore: false)
    }

    private func activated(_ pid: pid_t?) {
        guard let pid else { return }
        if pid != ProcessInfo.processInfo.processIdentifier, locked[pid] == nil,
           let app = NSRunningApplication(processIdentifier: pid) {
            lastOtherApp = app
        }
        if locked[pid] != nil { showIsland(for: pid) }
    }

    private func terminated(_ pid: pid_t?) {
        guard let pid, locked.removeValue(forKey: pid) != nil else { return }
        if islandFor == pid { hideIsland(restore: false) }
        if locked.isEmpty { stopTracking() }
        poller.poke()
        onChange?()
    }

    private func render(_ scene: WindowScene) {
        let regions = scene.visibleRegions(overlayLevel: BlurLevels.window.rawValue, skipFrontmost: false) { [unowned self] in
            self.locked[$0] != nil
        }
        let windows = regions.map(\.window)
        let parts = regions.map(\.parts)
        guard windows != lastKey || parts != lastParts else { return }
        lastKey = windows
        lastParts = parts
        var placements: [(part: CGRect, window: CGRect, badge: (String, NSImage?)?)] = []
        for region in regions {
            let largest = region.parts.max { $0.width * $0.height < $1.width * $1.height }
            for part in region.parts {
                let app = locked[region.window.pid]
                let showBadge = part == largest && part.width >= 220 && part.height >= 160
                placements.append((part, region.window.frame, showBadge ? app.map { ($0.name, $0.icon) } : nil))
            }
        }
        while covers.count > placements.count { covers.removeLast().close() }
        while covers.count < placements.count {
            covers.append(AppCover { [weak self] in self?.coverClicked() })
        }
        for (cover, p) in zip(covers, placements) {
            cover.place(part: p.part, window: p.window, badge: p.badge.map { (name: $0.0, icon: $0.1) })
        }
        island?.orderFrontRegardless()
    }

    private func coverClicked() {
        let pointer = ScreenGeometry.toAX(NSEvent.mouseLocation)
        let hit = poller.scene.windows.first { locked[$0.pid] != nil && $0.frame.contains(pointer) }
        if let pid = hit?.pid ?? locked.keys.first { showIsland(for: pid) }
    }

    // MARK: Island

    private func showIsland(for pid: pid_t) {
        guard let app = locked[pid] else { return }
        if islandFor != pid {
            biometric.cancel()
            backoff.reset()
            biometricsLockedOut = false
        }
        islandFor = pid
        unlock.title = String(localized: "“\(app.name)” is locked", comment: "Unlock island title for App Lock; the placeholder is the app's name")
        unlock.appIcon = app.icon
        unlock.password = ""
        unlock.note = nil
        if case .waiting = unlock.phase, backoff.canTryPassword(at: Date()) { unlock.phase = .ready }
        if unlock.phase == .verifying { unlock.phase = .ready }
        unlock.offersBiometrics = allowsTouchID() && BiometricPrompt.isAvailable
        unlock.onSubmit = { [weak self] in self?.submitPassword() }
        unlock.onCancel = { [weak self] in self?.hideIsland(restore: true) }
        unlock.onRetryBiometrics = { [weak self] in self?.armBiometrics() }

        let screen = screenForApp(pid) ?? NSScreen.underMouse ?? NSScreen.main
        guard let screen else { return }
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let placed = IslandPlacement.frame(on: screen, topMargin: menuBar + 10)
        let panel = island ?? IslandPanel(frame: placed.frame, level: BlurLevels.appLockIsland)
        panel.onEscape = { [weak self] in self?.hideIsland(restore: true) }
        panel.setFrame(placed.frame, display: false)
        panel.setIsland(UnlockIslandView(model: unlock, notch: placed.notch,
                                         biometricSlot: unlock.offersBiometrics ? biometric.slot : nil))
        island = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        unlock.focusCount += 1
        if islandResign == nil {
            islandResign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.islandLostFocus() }
            }
        }
        startWaitTimer()
        armBiometrics()
    }

    private func screenForApp(_ pid: pid_t) -> NSScreen? {
        guard let window = poller.scene.windows.first(where: { $0.pid == pid && $0.layer == 0 }) else { return nil }
        return ScreenGeometry.screen(forAX: window.frame)
    }

    private func islandLostFocus() {
        // Give a click on the cover (which re-shows the island) a moment before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let island = self.island, !island.isKeyWindow else { return }
            self.hideIsland(restore: false)
        }
    }

    private func hideIsland(restore: Bool) {
        biometric.cancel()
        waitTimer?.invalidate()
        waitTimer = nil
        if let islandResign { NotificationCenter.default.removeObserver(islandResign) }
        islandResign = nil
        island?.orderOut(nil)
        island?.close()
        island = nil
        islandFor = nil
        unlock.password = ""
        if restore, let app = lastOtherApp, !app.isTerminated, NSApp.isActive {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    private func startWaitTimer() {
        guard waitTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .waiting = self.unlock.phase, self.backoff.canTryPassword(at: Date()) {
                    self.unlock.phase = .ready
                    self.unlock.focusCount += 1
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        waitTimer = t
    }

    private func submitPassword() {
        guard let pid = islandFor, unlock.phase == .ready else { return }
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
            guard let self, self.islandFor == pid else { return }
            if ok {
                self.unlockApp(pid)
            } else {
                let at = Date()
                self.backoff.recordFailure(.password, at: at)
                self.unlock.note = .wrongPassword
                self.unlock.shakeCount += 1
                if let next = self.backoff.nextAttempt, next > at { self.unlock.phase = .waiting(until: next) } else { self.unlock.phase = .ready }
                self.unlock.focusCount += 1
            }
        }
    }

    private func armBiometrics() {
        guard let pid = islandFor, unlock.offersBiometrics, !biometricsLockedOut else { return }
        let name = locked[pid]?.name ?? ""
        biometric.begin(reason: String(localized: "unlock \(name)", comment: "Touch ID reason for App Lock; the placeholder is an app name")) { [weak self] outcome in
            guard let self, self.islandFor == pid else { return }
            switch outcome {
            case .success:
                self.unlockApp(pid)
            case .failed:
                self.backoff.recordFailure(.touchID, at: Date())
                self.unlock.note = .touchIDFailed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.armBiometrics() }
            case .lockedOut:
                self.biometricsLockedOut = true
                self.unlock.note = .touchIDLocked
            case .unavailable:
                self.unlock.offersBiometrics = false
            case .cancelled:
                break
            }
        }
    }

    private func unlockApp(_ pid: pid_t) {
        guard let app = locked.removeValue(forKey: pid) else { return }
        log.info("app unlocked")
        hideIsland(restore: false)
        backoff.reset()
        if locked.isEmpty { stopTracking() } else { poller.poke() }
        Announce.say(String(localized: "\(app.name) is unlocked", comment: "VoiceOver announcement; the placeholder is an app name"))
        if let running = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        onChange?()
    }
}
