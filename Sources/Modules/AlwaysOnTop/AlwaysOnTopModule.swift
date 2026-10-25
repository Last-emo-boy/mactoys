import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Always On Top: keeps chosen windows above all others.
///
/// macOS has no public API to change another app's window level, so a pinned window is
/// represented by a floating panel at its frame. While the real window is frontmost the panel
/// only draws the colored border (and lets every click through). When another window comes to
/// the front, the panel shows a live ScreenCaptureKit mirror of the pinned window instead, so it
/// keeps looking "on top"; pointing at (or clicking) the mirror hides it and raises the real
/// window in place.
@MainActor
public final class AlwaysOnTopModule: ToyModule {
    public let info = ModuleInfo(
        id: "alwaysontop", name: "Always On Top",
        summary: "Pin any window above all others with a shortcut.",
        symbol: "pin.fill", tint: .indigo, category: .windowing,
        permissions: [.accessibility, .screenRecording], enabledByDefault: true,
        keywords: ["pin", "topmost", "float", "window", "border", "mirror"])

    let settings = Persisted("alwaysontop", default: AlwaysOnTopSettings())
    /// Pinned windows for the settings page.
    let list = PinList()

    private var pins: [PinnedWindow] = []
    private var running = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    /// The last app other than MacToys that was frontmost, for actions started from MacToys UI.
    private var lastExternalPID: pid_t?
    private let log = Log.for("alwaysontop")
    private static let hotkeyID = "alwaysontop.toggle"

    public init() {
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
        observeSystem()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        unpinAll(feedback: false)
        stopTimer()
    }

    public func settingsView() -> AnyView { AnyView(AlwaysOnTopSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        var actions = [QuickAction(id: "alwaysontop.toggle", title: "Pin Window", symbol: "pin.fill", tint: info.tint,
                                   shortcut: settings.value.activation) { [weak self] in self?.toggleFocused() }]
        if !pins.isEmpty {
            actions.append(QuickAction(id: "alwaysontop.unpinall", title: "Unpin All", symbol: "pin.slash.fill",
                                       tint: info.tint) { [weak self] in self?.unpinAll(feedback: true) })
        }
        return actions
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Pin or unpin the focused window", settings.value.activation)]
    }

    /// `mactoys://alwaysontop/<action>`: `toggle`, `pin`, `unpin`, `unpinall`, `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "toggle": toggleFocused()
        case "pin": pinFocused(onlyPin: true)
        case "unpin":
            if let w = targetWindow(), let id = w.windowID, let pin = pins.first(where: { $0.windowID == id }) {
                unpin(pin, feedback: true)
            }
        case "unpinall": unpinAll(feedback: true)
        case "open", "settings": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("pinned", size: CGSize(width: 960, height: 600)) { AnyView(AlwaysOnTopPreview()) }]
    }

    // MARK: Pinning

    func toggleFocused() { pinFocused(onlyPin: false) }

    private func pinFocused(onlyPin: Bool) {
        guard running else {
            HUD.show("Always On Top is off", symbol: "pin.slash")
            return
        }
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        guard let window = targetWindow(), let id = window.windowID else {
            HUD.show("No window to pin", symbol: "pin.slash")
            return
        }
        if let existing = pins.first(where: { $0.windowID == id }) {
            if !onlyPin { unpin(existing, feedback: true) }
            return
        }
        pin(window, id: id)
    }

    private func pin(_ window: WindowRef, id: CGWindowID) {
        let s = settings.value
        if s.excludedApps.matches(app: window.app) {
            HUD.show("\(window.appName) is excluded from Always On Top", symbol: "pin.slash")
            return
        }
        if window.isFullScreen {
            HUD.show("Full-screen windows can't be pinned", symbol: "pin.slash")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        guard let frame = window.frame, frame.width > 1, frame.height > 1 else {
            HUD.show("This window can't be pinned", symbol: "pin.slash")
            return
        }
        let pin = PinnedWindow(window: window, windowID: id, frame: frame)
        pin.onRaiseRequest = { [weak self] p in self?.raise(p) }
        pin.onGone = { [weak self] p in self?.unpin(p, feedback: false) }
        pin.onChange = { [weak self] in self?.refresh() }
        pin.onGeometryChange = { [weak self] in
            // A lone pin's panel already followed; others only need new cut-outs.
            guard let self, self.pins.count > 1 else { return }
            self.refresh()
        }
        pin.onTitleChange = { [weak self] in self?.syncList() }
        pins.append(pin)
        pin.start(style: style, frameRate: s.frameRate, raiseOnHover: s.raiseTrigger == .hover)
        syncList()
        startTimer()
        refresh()
        feedback(pinned: true, title: displayName(of: pin))
        log.info("Pinned window \(id) of \(pin.appName, privacy: .public)")
    }

    private func unpin(_ pin: PinnedWindow, feedback show: Bool) {
        guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
        pins.remove(at: index)
        pin.teardown()
        syncList()
        if pins.isEmpty { stopTimer() }
        refresh()
        if show { feedback(pinned: false, title: displayName(of: pin)) }
    }

    func unpin(windowID: CGWindowID) {
        if let pin = pins.first(where: { $0.windowID == windowID }) { unpin(pin, feedback: true) }
    }

    func unpinAll(feedback show: Bool) {
        guard !pins.isEmpty else { return }
        let all = pins
        pins.removeAll()
        for p in all { p.teardown() }
        syncList()
        stopTimer()
        if show {
            let title = all.count == 1 ? displayName(of: all[0])
                : String(localized: "\(all.count) windows", comment: "Always On Top: what was unpinned, shown after “Unpinned ·”")
            feedback(pinned: false, title: title)
        }
    }

    private func raise(_ pin: PinnedWindow) {
        pin.beginRaise()
        refresh()
        if pin.window.isMinimized { pin.window.minimize(false) }
        pin.window.focus()
        // Cooperative activation may ignore a background app's request; Accessibility doesn't.
        AXUIElementCreateApplication(pin.window.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refresh() }
    }

    private func feedback(pinned: Bool, title: String) {
        let s = settings.value
        let message = pinned
            ? String(localized: "Pinned · \(title)", comment: "HUD after pinning; %@ is the window title or app name")
            : String(localized: "Unpinned · \(title)", comment: "HUD after unpinning; %@ is the window title, app name or a window count")
        HUD.show(message, symbol: pinned ? "pin.fill" : "pin.slash")
        if s.playSound { NSSound(named: pinned ? "Tink" : "Pop")?.play() }
    }

    private func displayName(of pin: PinnedWindow) -> String {
        pin.title.isEmpty ? pin.appName : pin.title
    }

    /// The focused window of the frontmost app, or of the last other app when MacToys is in front.
    private func targetWindow() -> WindowRef? {
        let own = ProcessInfo.processInfo.processIdentifier
        var pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid == nil || pid == own { pid = lastExternalPID }
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if let element: AXUIElement = app.ax(kAXFocusedWindowAttribute) { return WindowRef(element: element, pid: pid) }
        return WindowRef.windows(of: pid).first { $0.isStandard && !$0.isMinimized }
    }

    // MARK: Presentation

    /// Decides for every pin whether it shows nothing, the border, or its mirror.
    private func refresh() {
        guard !pins.isEmpty else { return }
        let onScreen = Set(WindowInfo.onScreen().map(\.id))
        let front = frontmostWindowID()
        let border = style.border
        let frontmost = Set(pins.filter { $0.windowID == front || $0.isRaising }.map(\.windowID))
        let frontFrames = pins.filter { frontmost.contains($0.windowID) && onScreen.contains($0.windowID) }
            .map { PinGeometry.panelFrame(window: $0.frame, border: border) }
        for pin in pins {
            let visible = onScreen.contains(pin.windowID)
            let isFront = frontmost.contains(pin.windowID)
            let state = PinPresentation.resolve(visible: visible, fullScreen: visible && pin.isFullScreen,
                                                frontmost: isFront, hasFrame: pin.hasFrame)
            pin.present(state, exclusions: isFront ? [] : frontFrames)
        }
    }

    private func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall MacToys: this runs on every activation and once a second.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let element: AXUIElement = axApp.ax(kAXFocusedWindowAttribute) else { return nil }
        return WindowRef(element: element, pid: app.processIdentifier).windowID
    }

    private var style: PinView.Style {
        let s = settings.value
        guard s.showBorder else { return PinView.Style(border: 0, color: nil, rounded: s.roundedCorners) }
        let base = s.colorMode == .accent ? NSColor.controlAccentColor : s.customColor.nsColor
        let color = base.withAlphaComponent(base.alphaComponent * min(max(s.opacity, 0), 100) / 100)
        return PinView.Style(border: PinGeometry.clampedThickness(s.thickness), color: color, rounded: s.roundedCorners)
    }

    private func restyle() {
        let s = settings.value
        let current = style
        for pin in pins {
            pin.update(style: current, frameRate: s.frameRate, raiseOnHover: s.raiseTrigger == .hover)
        }
        refresh()
    }

    private func settingsChanged() {
        guard running else { return }
        registerHotkey()
        restyle()
        // Newly excluded apps lose their pins.
        for pin in pins where settings.value.excludedApps.matches(app: pin.window.app) { unpin(pin, feedback: true) }
    }

    private func syncList() {
        list.items = pins.map { PinList.Item(id: $0.windowID, app: $0.appName, title: $0.title) }
    }

    // MARK: System observation

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activation) { [weak self] in self?.toggleFocused() }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let own = ProcessInfo.processInfo.processIdentifier
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((center, token))
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != own { lastExternalPID = front }
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != own {
                self?.lastExternalPID = app.processIdentifier
            }
            self?.refresh()
        }
        on(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for pin in self.pins where pin.window.pid == app.processIdentifier { self.unpin(pin, feedback: false) }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            on(ws, name) { [weak self] _ in self?.refresh() }
        }
        on(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.revalidate() }
        on(.default, NSColor.systemColorsDidChangeNotification) { [weak self] _ in self?.restyle() }
    }

    /// Re-reads every frame, drops pins whose window disappeared, and re-presents.
    private func revalidate() {
        for pin in pins where !pin.refreshFrame() { unpin(pin, feedback: false) }
        refresh()
    }

    /// AX notifications cover moves and focus; a slow timer catches what they miss
    /// (Space switches through Mission Control, apps that don't post notifications).
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidate() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Observable list of pinned windows for the settings page.
@MainActor
@Observable
final class PinList {
    struct Item: Identifiable, Equatable {
        let id: CGWindowID
        let app: String
        let title: String
    }

    var items: [Item] = []
}
