import AppKit
import Carbon.HIToolbox
import MacToysCore
import QuartzCore

/// Find My Mouse: double-tap ⌃ (left or right), shake the mouse, or press a shortcut, and a
/// spotlight closes in on the pointer. A click or key dismisses it; after you move the mouse it
/// dismisses itself shortly after the mouse stops.
@MainActor
final class FindMyMouse {
    static let tapID = "mouseutils.findmymouse"
    static let hotkeyID = "mouseutils.findmymouse"

    private(set) var settings: FindMyMouseSettings
    private var running = false
    private var doubleTap = DoubleTapDetector()
    private var shake = ShakeDetector()
    private let overlays = ScreenOverlays(level: .screenSaver)
    private var spot = SpotlightLayers()
    private var center = CGPoint.zero
    private var animationStart: TimeInterval = 0
    private var animationTimer: Timer?
    private var dismissWork: DispatchWorkItem?
    private(set) var isShowing = false

    init(settings: FindMyMouseSettings) {
        self.settings = settings
        overlays.onBuild = { [weak self] surfaces in self?.spot.build(on: surfaces) }
    }

    func update(_ s: FindMyMouseSettings) {
        let old = settings
        settings = s
        doubleTap.maxGap = NSEvent.doubleClickInterval
        shake.interval = s.shakeInterval / 1000
        shake.minimumDistance = s.shakeMinimumDistance
        shake.factor = s.shakeFactor / 100
        if running && (old.activation != s.activation || old.shortcut != s.shortcut) { installTriggers() }
        if isShowing { spot.style(s); redraw() }
    }

    func start() {
        guard !running else { return }
        running = true
        update(settings)
        installTriggers()
    }

    func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(Self.tapID)
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        dismiss(animated: false)
    }

    private func installTriggers() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.activation == .shortcut ? settings.shortcut : nil) { [weak self] in
            self?.activate()
        }
        var events: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                                     .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if settings.activation == .leftControlTwice || settings.activation == .rightControlTwice {
            events.append(.flagsChanged)
        }
        InputTap.shared.add(Self.tapID, priority: 30, events: events) { [weak self] type, event in
            self?.handle(type, event)
            return .pass
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let watched = settings.activation == .leftControlTwice ? kVK_Control : kVK_RightControl
            if code == watched {
                let mask: UInt64 = watched == kVK_Control ? 0x1 : 0x2000
                var others = Modifiers(event.flags)
                others.remove(.control)
                others.remove(.function)
                var clean = others.isEmpty
                if settings.requireCommand {
                    clean = others == [.command]
                }
                // The other ⌃ key held at the same time doesn't count as a tap.
                let otherControl: UInt64 = watched == kVK_Control ? 0x2000 : 0x1
                if event.flags.rawValue & otherControl != 0 { clean = false }
                if doubleTap.watchedKey(down: event.flags.rawValue & mask != 0, time: now, clean: clean) { activate() }
            } else if !(settings.requireCommand && (code == kVK_Command || code == kVK_RightCommand)) {
                doubleTap.interrupt()
            }
        case .keyDown:
            doubleTap.interrupt()
            if isShowing { dismiss(animated: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            doubleTap.interrupt()
            if isShowing { dismiss(animated: true) }
        default:
            let p = event.location
            if isShowing {
                center = p
                redraw()
                scheduleDismissAfterMovement()
            } else if settings.activation == .shake, shake.add(p, at: now) {
                activate()
                scheduleDismissAfterMovement()
            }
        }
    }

    // MARK: - Spotlight

    func activate() {
        guard running else { return }
        if isShowing { dismiss(animated: true); return }
        let front = NSWorkspace.shared.frontmostApplication
        if settings.excludedApps.matches(app: front) { return }
        if settings.skipFullScreenApps && FrontmostApp.isFullScreen() { return }
        center = MouseSynth.location
        isShowing = true
        overlays.show()
        spot.style(settings)
        animationStart = ProcessInfo.processInfo.systemUptime
        redraw()
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    func dismiss(animated: Bool) {
        guard isShowing else { return }
        isShowing = false
        animationTimer?.invalidate()
        animationTimer = nil
        dismissWork?.cancel()
        dismissWork = nil
        guard animated else { overlays.hide(); return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShowing else { return }
                self.overlays.hide()
            }
        }
        spot.fadeOut()
        CATransaction.commit()
    }

    private func scheduleDismissAfterMovement() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func redraw() {
        let duration = max(settings.animationDuration / 1000, 0.001)
        let t = min((ProcessInfo.processInfo.systemUptime - animationStart) / duration, 1)
        let eased = 1 - pow(1 - t, 3)
        let r = settings.spotlightRadius
        let radius = r * max(settings.initialZoom, 1) + (r - r * max(settings.initialZoom, 1)) * eased
        withoutAnimation {
            spot.draw(center: center, radius: CGFloat(radius), progress: CGFloat(eased), surfaces: overlays.surfaces)
        }
        if t >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
}

/// Backdrop with a hole, the tinted spotlight, and a thin outer ring, per display.
@MainActor
struct SpotlightLayers {
    private var backdrops: [CAShapeLayer] = []
    private var spots: [CAShapeLayer] = []
    private var rings: [CAShapeLayer] = []
    private var backdropAlpha: Double = 0.7

    mutating func build(on surfaces: [ScreenOverlays.Surface]) {
        backdrops = []
        spots = []
        rings = []
        for s in surfaces {
            let backdrop = CAShapeLayer()
            backdrop.fillRule = .evenOdd
            backdrop.frame = s.root.bounds
            let spot = CAShapeLayer()
            spot.frame = s.root.bounds
            let ring = CAShapeLayer()
            ring.frame = s.root.bounds
            ring.fillColor = nil
            ring.lineWidth = 1.5
            for l in [backdrop, spot, ring] {
                l.contentsScale = s.scale
                s.root.addSublayer(l)
            }
            backdrops.append(backdrop)
            spots.append(spot)
            rings.append(ring)
        }
    }

    mutating func style(_ s: FindMyMouseSettings) {
        backdropAlpha = s.backdropColor.alpha
        for b in backdrops { b.fillColor = s.backdropColor.withAlpha(1).cgColor }
        for l in spots { l.fillColor = s.spotlightColor.cgColor }
        for r in rings { r.strokeColor = RGBA.white.withAlpha(0.55).cgColor }
    }

    func draw(center: CGPoint, radius: CGFloat, progress: CGFloat, surfaces: [ScreenOverlays.Surface]) {
        for (i, s) in surfaces.enumerated() where i < backdrops.count {
            let c = s.local(center)
            let circle = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            let hole = CGMutablePath()
            hole.addRect(s.root.bounds)
            hole.addEllipse(in: circle)
            backdrops[i].path = hole
            backdrops[i].opacity = Float(backdropAlpha * Double(progress))
            spots[i].path = CGPath(ellipseIn: circle, transform: nil)
            spots[i].opacity = Float(progress)
            let ringRadius = radius * 1.45
            rings[i].path = CGPath(ellipseIn: CGRect(x: c.x - ringRadius, y: c.y - ringRadius,
                                                     width: ringRadius * 2, height: ringRadius * 2), transform: nil)
            rings[i].opacity = Float(progress * 0.9)
        }
    }

    func fadeOut() {
        for l in backdrops + spots + rings { l.opacity = 0 }
    }
}
