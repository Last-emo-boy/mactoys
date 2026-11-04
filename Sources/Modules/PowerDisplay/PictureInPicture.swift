import AppKit
import CoreVideo
import MacToysCore
import SwiftUI

/// Picture in picture options (Settings › Picture in Picture).
struct PiPOptions: Codable, Equatable, Sendable {
    var frameRate = 30
    var showsCursor = true
    /// Above other windows; off makes it an ordinary window.
    var floats = true
    var allSpaces = true

    static let frameRates = [10, 15, 30, 60]
}

/// Sizing for a picture-in-picture window, as plain math.
enum PiPGeometry {
    /// The starting content size: `width` points wide (a quarter of the smaller screen at most),
    /// in the captured display's shape.
    static func initialSize(display: CGSize, screen: CGSize, width: CGFloat = 480) -> CGSize {
        guard display.width > 0, display.height > 0 else { return CGSize(width: width, height: width * 9 / 16) }
        let w = min(width, max(240, screen.width / 2))
        return CGSize(width: w.rounded(), height: (w * display.height / display.width).rounded())
    }

    /// Pixels per captured point: enough for the window's size on a Retina screen, no more.
    static func captureScale(windowWidth: CGFloat, backing: CGFloat, displayWidth: CGFloat) -> CGFloat {
        guard displayWidth > 0 else { return 1 }
        return max(0.25, min(2, windowWidth * backing / displayWidth))
    }

    /// Bottom-right corner of `visible`, inset by `margin` (Cocoa coordinates).
    static func origin(for size: CGSize, in visible: CGRect, margin: CGFloat = 24) -> CGPoint {
        CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    }
}

/// A floating, resizable live view of a whole display (ScreenCaptureKit through Core's
/// `LiveCapture`). Needs Screen Recording permission. MacToys' own windows are left out, so a
/// picture of the display it sits on doesn't recurse.
@MainActor
final class PiPWindow: NSPanel, NSWindowDelegate {
    let displayID: CGDirectDisplayID
    let monitorID: String
    var onClosed: ((PiPWindow) -> Void)?

    private let capture = LiveCapture()
    private let surface = PiPSurfaceView()
    private let label: NSHostingView<PiPHoverLabel>
    private var options: PiPOptions
    private let displaySize: CGSize
    private var tornDown = false
    private let log = Log.for("powerdisplay")

    init(displayID: CGDirectDisplayID, monitorID: String, name: String, options: PiPOptions) {
        self.displayID = displayID
        self.monitorID = monitorID
        self.options = options
        let bounds = CGDisplayBounds(displayID)
        displaySize = bounds.size
        let screen = NSScreen.screens.first { $0.displayID != displayID } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PiPGeometry.initialSize(display: bounds.size, screen: visible.size)
        label = NSHostingView(rootView: PiPHoverLabel(name: name))
        super.init(contentRect: CGRect(origin: PiPGeometry.origin(for: size, in: visible), size: size),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = String(localized: "Picture in Picture: \(name)", comment: "Window title; the placeholder is a display name")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.alphaValue = 0
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        backgroundColor = .black
        contentAspectRatio = bounds.size.width > 0 ? bounds.size : CGSize(width: 16, height: 9)
        contentMinSize = CGSize(width: 200, height: 200 * max(0.3, bounds.height / max(1, bounds.width)))
        delegate = self
        applyOptions()
        surface.autoresizingMask = [.width, .height]
        surface.frame = CGRect(origin: .zero, size: size)
        contentView = surface
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alphaValue = 0
        surface.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            label.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
        ])
        surface.onHover = { [weak self] inside in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                self.standardWindowButton(.closeButton)?.animator().alphaValue = inside ? 1 : 0
                self.label.animator().alphaValue = inside ? 1 : 0
            }
        }
        surface.menuProvider = { [weak self] in self?.contextMenu() }
        // Where this display's picture was last left, then keep saving it there.
        let autosave = "com.w33d.mactoys.powerdisplay.pip.\(monitorID)"
        setFrameUsingName(autosave)
        setFrameAutosaveName(autosave)
    }

    override var canBecomeMain: Bool { false }

    func start() {
        orderFrontRegardless()
        startCapture()
    }

    private func applyOptions() {
        level = options.floats ? .floating : .normal
        isFloatingPanel = options.floats
        collectionBehavior = options.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func update(options new: PiPOptions) {
        let restart = new.frameRate != options.frameRate || new.showsCursor != options.showsCursor
        options = new
        applyOptions()
        if restart { startCapture() }
    }

    private var scale: CGFloat {
        PiPGeometry.captureScale(windowWidth: frame.width, backing: screen?.backingScaleFactor ?? 2,
                                 displayWidth: displaySize.width)
    }

    private func startCapture() {
        capture.onFrame = { [weak self] buffer in self?.surface.show(buffer) }
        capture.onStop = { [weak self] error in
            guard let self, !self.tornDown else { return }
            self.log.notice("PiP stream stopped: \(error?.localizedDescription ?? "-", privacy: .public)")
            self.close()
        }
        let scale = self.scale
        Task { [weak self, capture, displayID, options] in
            do {
                try await capture.start(.display(displayID), fps: options.frameRate, scale: scale,
                                        showsCursor: options.showsCursor, ownWindows: .all)
                if self == nil || self?.tornDown == true { capture.stop() }
            } catch {
                guard let self, !self.tornDown else { return }
                self.log.error("PiP capture failed: \(error.localizedDescription, privacy: .public)")
                if (error as? CaptureError) == .notPermitted {
                    HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
                    PermissionCenter.shared.request(.screenRecording)
                }
                self.close()
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let scale = self.scale
        let rect = CGRect(origin: .zero, size: displaySize)
        Task { [capture] in await capture.update(sourceRect: rect, scale: scale) }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let float = menu.addItem(withTitle: String(localized: "Float on Top", comment: "Menu item: keep the picture-in-picture window above other windows"),
                                 action: #selector(toggleFloat), keyEquivalent: "")
        float.target = self
        float.state = options.floats ? .on : .off
        let cursor = menu.addItem(withTitle: String(localized: "Show Pointer", comment: "Menu item: show the mouse pointer in picture in picture"),
                                  action: #selector(toggleCursor), keyEquivalent: "")
        cursor.target = self
        cursor.state = options.showsCursor ? .on : .off
        menu.addItem(.separator())
        for (title, width) in [(String(localized: "Small", comment: "Picture-in-picture window size"), 320.0),
                               (String(localized: "Medium", comment: "Picture-in-picture window size"), 480.0),
                               (String(localized: "Large", comment: "Picture-in-picture window size"), 760.0)] {
            let item = menu.addItem(withTitle: title, action: #selector(resizeTo(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(width)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close", comment: "Menu item: close the picture-in-picture window"),
                     action: #selector(performClose(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func toggleFloat() { update(options: { var o = options; o.floats.toggle(); return o }()) }
    @objc private func toggleCursor() { update(options: { var o = options; o.showsCursor.toggle(); return o }()) }

    @objc private func resizeTo(_ sender: NSMenuItem) {
        let w = CGFloat(sender.tag)
        let h = (w * displaySize.height / max(1, displaySize.width)).rounded()
        var f = frame
        f.origin.y += f.height - h
        f.size = CGSize(width: w, height: h)
        setFrame(f, display: true, animate: true)
        windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    }

    func windowWillClose(_ notification: Notification) {
        guard !tornDown else { return }
        tornDown = true
        capture.onFrame = nil
        capture.onStop = nil
        capture.stop()
        onClosed?(self)
    }
}

/// The live image (IOSurface-backed frames) plus hover and context menu.
final class PiPSurfaceView: NSView {
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let imageLayer = CALayer()
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// The name pill shown while the pointer is over a picture-in-picture window.
struct PiPHoverLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pip").font(.system(size: 11, weight: .semibold))
            Text(verbatim: name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}
