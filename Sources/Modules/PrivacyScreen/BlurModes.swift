import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// "Esc or click to clear", shown briefly at the bottom of the display under the pointer.
struct BlurHint: View {
    var fades = true
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Screen blurred", comment: "Blur Screen hint, first part")
                .font(.system(size: 13, weight: .semibold))
            Text("Esc or click to clear", comment: "Blur Screen hint: how to remove the blur")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.72)))
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 96)
        .task {
            guard fades else { return }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { visible = false }
        }
        .accessibilityHidden(true)
    }
}

/// Blur Screen: frosts every display at once, no password. Esc, the shortcut or a click clears it.
/// Keys typed while it is up go nowhere, so nobody types blind into the app behind it.
@MainActor
final class ScreenBlurController {
    /// Asked to clear the blur (Esc or a click).
    var onDismiss: (() -> Void)?
    private(set) var isShown = false
    private let set = DisplayBlurSet(level: BlurLevels.screen, interactive: true, acceptsKey: true)
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?

    init() {
        set.onMouseDown = { [weak self] in self?.onDismiss?() }
        set.onKeyDown = { [weak self] event in
            if Int(event.keyCode) == kVK_Escape { self?.onDismiss?() }
            return true
        }
    }

    func show(strength: Double) {
        set.configure(BlurRecipe.make(strength: strength), dark: nil)
        set.syncScreens()
        set.show()
        guard !isShown else { return }
        isShown = true
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        NSApp.activate()
        if let top = set.stackUnderMouse?.top {
            top.makeKeyAndOrderFront(nil)
            top.makeFirstResponder(top.root)
            top.setOverlay(BlurHint())
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.set.syncScreens()
                self.set.show()
            }
        }
        Announce.say(String(localized: "Screen blurred", comment: "VoiceOver announcement"))
    }

    func update(strength: Double) {
        guard isShown else { return }
        set.configure(BlurRecipe.make(strength: strength), dark: nil)
    }

    /// - Parameter restoringFocus: give the keyboard back to the app that had it (not when the
    ///   lock takes over).
    func hide(restoringFocus: Bool = true) {
        guard isShown else { return }
        isShown = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        set.close()
        if restoringFocus, let app = previousApp, !app.isTerminated, NSApp.isActive {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        previousApp = nil
        if restoringFocus { Announce.say(String(localized: "Blur cleared", comment: "VoiceOver announcement")) }
    }
}

/// Focus Blur: everything but the frontmost window is blurred; the sharp hole follows window
/// switches, moves and resizes. The overlay sits below menus and popovers, so the active app's
/// menus stay sharp.
@MainActor
final class FocusBlurController {
    private(set) var isActive = false
    private let set = DisplayBlurSet(level: BlurLevels.window)
    private let poller: WindowPoller
    private var lastHoles: [CGRect]?
    private var screenObserver: NSObjectProtocol?

    init(poller: WindowPoller) {
        self.poller = poller
    }

    func start(strength: Double) {
        set.configure(BlurRecipe.make(strength: strength), dark: nil)
        guard !isActive else { return }
        isActive = true
        set.syncScreens()
        lastHoles = nil
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.set.syncScreens()
                self.lastHoles = nil
                self.poller.poke()
            }
        }
        poller.subscribe("focus") { [weak self] scene, changed in
            guard changed else { return }
            self?.render(scene)
        }
    }

    func update(strength: Double) {
        guard isActive else { return }
        set.configure(BlurRecipe.make(strength: strength), dark: nil)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        poller.unsubscribe("focus")
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        set.close()
        lastHoles = nil
    }

    private func render(_ scene: WindowScene) {
        let holes = scene.focusHoles(overlayLevel: BlurLevels.window.rawValue)
        guard holes != lastHoles else { return }
        lastHoles = holes
        let desktop = ScreenGeometry.desktopAXFrame.insetBy(dx: -2, dy: -2)
        set.setGlobalMask(MaskPaths.excluding(holes, from: desktop))
    }
}

/// Private Apps: the chosen apps stay blurred wherever they show, unless they are frontmost. Only
/// their visible part is blurred (a window minus the windows above it), so windows in front stay sharp.
/// Holding ⌥ over one peeks at it without switching.
@MainActor
final class PrivateAppsController {
    private(set) var isActive = false
    private let set = DisplayBlurSet(level: BlurLevels.window)
    private let poller: WindowPoller
    private var apps: [String] = []
    private var peekWithOption = true
    private var cache: [pid_t: Bool] = [:]
    private var subscribed = false
    private var lastKey: RenderKey?
    private var observers: [NSObjectProtocol] = []

    private struct RenderKey: Equatable {
        var windows: [WindowSample]
        var parts: [[CGRect]]
        var peeked: CGWindowID?
    }

    init(poller: WindowPoller) {
        self.poller = poller
    }

    func start(strength: Double, apps: [String], peekWithOption: Bool) {
        set.configure(BlurRecipe.make(strength: strength), dark: nil)
        let listChanged = apps != self.apps
        self.apps = apps
        self.peekWithOption = peekWithOption
        if listChanged { cache.removeAll() }
        lastKey = nil
        if !isActive {
            isActive = true
            set.syncScreens()
            let ws = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.cache.removeAll()
                        self?.updateSubscription()
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.set.syncScreens()
                    self.lastKey = nil
                    self.poller.poke()
                }
            })
        }
        updateSubscription()
        poller.poke()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        if subscribed { poller.unsubscribe("private") }
        subscribed = false
        set.close()
        cache.removeAll()
        lastKey = nil
    }

    /// Samples windows only while a private app is running.
    private func updateSubscription() {
        guard isActive else { return }
        let running = NSWorkspace.shared.runningApplications.contains { apps.matches(app: $0) }
        if running && !subscribed {
            subscribed = true
            poller.subscribe("private") { [weak self] scene, _ in self?.render(scene) }
        } else if !running && subscribed {
            subscribed = false
            poller.unsubscribe("private")
            set.setGlobalMask(nil)
            lastKey = nil
        }
    }

    private func isPrivate(_ pid: pid_t) -> Bool {
        if let known = cache[pid] { return known }
        let value = apps.matches(app: NSRunningApplication(processIdentifier: pid))
        cache[pid] = value
        return value
    }

    private func render(_ scene: WindowScene) {
        let regions = scene.visibleRegions(overlayLevel: BlurLevels.window.rawValue) { [unowned self] in self.isPrivate($0) }
        var peeked: CGWindowID?
        if peekWithOption, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option) {
            let pointer = ScreenGeometry.toAX(NSEvent.mouseLocation)
            peeked = regions.first { RegionGeometry.contains($0.parts, pointer) }?.window.id
        }
        let key = RenderKey(windows: regions.map(\.window), parts: regions.map(\.parts), peeked: peeked)
        guard key != lastKey else { return }
        lastKey = key
        let path = CGMutablePath()
        for region in regions where region.window.id != peeked {
            path.addPath(MaskPaths.visible(parts: region.parts, of: region.window.frame))
        }
        set.setGlobalMask(path.isEmpty ? nil : path)
    }
}
