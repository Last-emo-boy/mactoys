import AppKit
import Carbon.HIToolbox
import CoreVideo
import MacToysCore
import QuartzCore

/// Live Zoom: a continuously updated, magnified view of the display under the pointer.
///
/// The window ignores the mouse, and the zoom keeps the point under the pointer in place
/// (`ZoomMath`), so clicks and typing reach the apps exactly where the magnified view shows.
/// ⌃⌥= / ⌃⌥- (or ⌃⌥-scroll, with Accessibility) change the level.
@MainActor
final class LiveZoomController {
    let screen: NSScreen
    var onStop: (() -> Void)?

    private let panel: OverlayPanel
    private let host: LayerHostView
    private let imageLayer = CALayer()
    private let capture = LiveCapture()
    private var link: CADisplayLink?
    private var driver: FrameDriver?
    private var level: Double
    private var target: Double
    private var visible: CGRect
    private(set) var panLocked = false
    private var stopped = false
    private var scrollAccumulator = 0.0
    private let logger = Log.for("zoomit")
    private static let hotkeyPrefix = "zoomit.livezoom."

    var windowNumber: Int { panel.windowNumber }

    init(screen: NSScreen, level: Double, smooth: Bool) {
        self.screen = screen
        self.level = 1
        self.target = ZoomMath.clamp(level)
        self.visible = CGRect(origin: .zero, size: screen.frame.size)
        panel = OverlayPanel(frame: screen.frame, interactive: false, acceptsKey: false,
                             level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1))
        host = LayerHostView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = host
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = smooth ? .linear : .nearest
        imageLayer.frame = host.bounds
        host.layer?.addSublayer(imageLayer)
        host.layer?.backgroundColor = NSColor.black.cgColor
    }

    /// Starts streaming; throws when the display can't be captured.
    func start() async throws {
        capture.onFrame = { [weak self] buffer in self?.show(buffer) }
        capture.onStop = { [weak self] error in
            guard let self, !self.stopped else { return }
            if let error { self.logger.error("Live Zoom stream ended: \(error.localizedDescription, privacy: .public)") }
            self.stop()
        }
        try await capture.start(.display(screen.displayID), fps: 60, scale: screen.backingScaleFactor)
        guard !stopped else { capture.stop(); return }
        panel.orderFrontRegardless()
        let driver = FrameDriver { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        let link = host.displayLink(target: driver, selector: #selector(FrameDriver.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.driver = driver
        self.link = link
        registerControls()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        link?.invalidate()
        link = nil
        driver = nil
        capture.stop()
        HotkeyCenter.shared.unregister(prefix: Self.hotkeyPrefix)
        InputTap.shared.remove("zoomit.livezoom")
        panel.orderOut(nil)
        onStop?()
        onStop = nil
    }

    /// Freezes panning while drawing over the live view, so drawings stay on their content.
    func setPanLocked(_ locked: Bool) { panLocked = locked }

    func zoom(in zoomIn: Bool) { target = ZoomMath.step(target, zoomIn: zoomIn) }

    /// Trackpads send many small deltas; step once per ~10 points of travel.
    private func scrolled(_ delta: Double) {
        scrollAccumulator += delta
        guard abs(scrollAccumulator) >= 10 else { return }
        zoom(in: scrollAccumulator > 0)
        scrollAccumulator = 0
    }

    private func show(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    private func tick() {
        // Ease toward the target level each frame.
        if abs(level - target) > 0.001 {
            level = exp(log(level) + (log(target) - log(level)) * 0.22)
        } else {
            level = target
        }
        if !panLocked {
            let m = NSEvent.mouseLocation
            let p = CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y)
            visible = ZoomMath.sourceRect(pointer: p, screen: screen.frame.size, level: level)
        } else {
            // Keep the locked center while the level settles.
            let center = CGPoint(x: visible.midX, y: visible.midY)
            let s = screen.frame.size
            let w = s.width / CGFloat(level), h = s.height / CGFloat(level)
            visible = CGRect(x: min(max(center.x - w / 2, 0), s.width - w), y: min(max(center.y - h / 2, 0), s.height - h),
                             width: w, height: h)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = ZoomMath.layerFrame(showing: visible, screen: screen.frame.size)
        CATransaction.commit()
    }

    private func registerControls() {
        let mods: Modifiers = [.control, .option]
        HotkeyCenter.shared.register(Self.hotkeyPrefix + "in", Shortcut(kVK_ANSI_Equal, mods)) { [weak self] in self?.zoom(in: true) }
        HotkeyCenter.shared.register(Self.hotkeyPrefix + "out", Shortcut(kVK_ANSI_Minus, mods)) { [weak self] in self?.zoom(in: false) }
        InputTap.shared.add("zoomit.livezoom", priority: 40, events: [.scrollWheel]) { [weak self] _, event in
            let flags = event.flags
            guard flags.contains(.maskControl), flags.contains(.maskAlternate) else { return .pass }
            self?.scrolled(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            return .consume
        }
    }
}
