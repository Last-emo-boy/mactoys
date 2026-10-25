import AppKit
import CoreVideo
import MacToysCore

/// A floating window showing a cropped area of another window, live.
///
/// - Thumbnail: read-only and freely resizable (keeping the aspect ratio).
/// - Interactive: macOS can't embed another app's window, so instead clicking the crop moves the
///   original window so its cropped area sits exactly under the crop window, raises it and passes
///   the click on. When you switch away, the crop window comes back over that area.
@MainActor
final class LiveCropWindow: NSPanel, NSWindowDelegate {
    struct Options {
        var forwardClicks: Bool
        var restorePosition: Bool
        var allSpaces: Bool
        var frameRate: Int
    }

    let mode: CropMode
    let source: WindowRef
    let sourceID: CGWindowID
    /// Cropped area in window-local points (top-left origin).
    let crop: CGRect
    var onClosed: ((LiveCropWindow) -> Void)?

    private let options: Options
    private let originalSourceOrigin: CGPoint
    private let capture = LiveCapture()
    private let cropView: CropContentView
    private var watcher: AXWatcher?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var outline: OverlayPanel?
    private var sourceActive = false
    private var raisingUntil = Date.distantPast
    private var tornDown = false
    private var captureRetries = 0
    private var awaitingFrame = false
    private let log = Log.for("cropandlock")

    init(mode: CropMode, source: WindowRef, sourceID: CGWindowID, sourceFrame: CGRect, crop: CGRect, options: Options) {
        self.mode = mode
        self.source = source
        self.sourceID = sourceID
        self.crop = crop
        self.options = options
        self.originalSourceOrigin = sourceFrame.origin
        let global = CropGeometry.globalRect(crop: crop, windowFrame: sourceFrame)
        let visible = ScreenGeometry.screen(forAX: global)?.axVisibleFrame ?? global
        // Interactive crops stay at actual size so clicks map 1:1 onto the original window.
        let content = mode == .interactive ? global : CropGeometry.keep(global, inside: visible)
        cropView = CropContentView(frame: CGRect(origin: .zero, size: content.size), interactive: mode == .interactive)
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        if mode == .thumbnail { style.insert(.resizable) }
        super.init(contentRect: ScreenGeometry.toCocoa(content), styleMask: style, backing: .buffered, defer: false)
        title = mode.windowTitle(of: source.title.flatMap { $0.isEmpty ? nil : $0 } ?? source.appName)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.alphaValue = 0
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        backgroundColor = .black
        collectionBehavior = options.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        contentAspectRatio = crop.size
        contentMinSize = CropGeometry.minimumContentSize(for: crop.size)
        AXUIElementSetMessagingTimeout(source.element, 0.5)
        delegate = self
        cropView.autoresizingMask = [.width, .height]
        contentView = cropView
        cropView.onHover = { [weak self] inside in
            self?.standardWindowButton(.closeButton)?.animator().alphaValue = inside ? 1 : 0
        }
        cropView.onClick = { [weak self] point in self?.clicked(at: point) }
        cropView.onDoubleClick = { [weak self] in self?.showOriginal() }
        cropView.menuProvider = { [weak self] in self?.contextMenu() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func start() {
        installWatchers()
        startCapture()
        orderFrontRegardless()
    }

    // MARK: Capture

    private func startCapture() {
        capture.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.cropView.show(buffer)
            if self.awaitingFrame {
                self.awaitingFrame = false
                self.captureRetries = 0
            }
        }
        capture.onStop = { [weak self] error in
            guard let self, !self.tornDown else { return }
            self.log.notice("Crop stream stopped: \(error?.localizedDescription ?? "-", privacy: .public)")
            self.recoverCapture()
        }
        let scale = outputScale
        awaitingFrame = true
        Task { [weak self, capture, sourceID, crop, options] in
            do {
                try await capture.start(.window(sourceID), sourceRect: crop, fps: options.frameRate, scale: scale)
                if self == nil || self?.tornDown == true { capture.stop() }
            } catch {
                guard let self, !self.tornDown else { return }
                self.log.error("Crop capture failed: \(error.localizedDescription, privacy: .public)")
                if (error as? CaptureError) == .notPermitted { self.close() } else { self.recoverCapture() }
            }
        }
    }

    private func recoverCapture() {
        guard source.frame != nil, captureRetries < 3 else {
            close()
            return
        }
        captureRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.tornDown else { return }
            self.startCapture()
        }
    }

    /// Pixels per crop point: the screen's scale, more when the thumbnail is enlarged (up to 2×).
    private var outputScale: CGFloat {
        let backing = screen?.backingScaleFactor ?? 2
        let zoom = crop.width > 0 ? frame.width / crop.width : 1
        return backing * min(max(zoom, 1), 2)
    }

    func windowDidEndLiveResize(_ notification: Notification) { updateStreamScale() }

    private func updateStreamScale() {
        let scale = outputScale
        Task { [capture, crop] in await capture.update(sourceRect: crop, scale: scale) }
    }

    // MARK: Interaction

    private func clicked(at local: CGPoint) {
        guard mode == .interactive, let sourceFrame = source.frame else { return }
        let content = ScreenGeometry.toAX(frame)
        let target = CropGeometry.sourceOrigin(crop: crop, contentOrigin: content.origin)
        if abs(sourceFrame.minX - target.x) > 0.5 || abs(sourceFrame.minY - target.y) > 0.5 {
            source.setPosition(target)
        }
        sourceActive = true
        raisingUntil = Date().addingTimeInterval(0.8)
        orderOut(nil)
        showOutline(CropGeometry.globalRect(crop: crop, windowFrame: CGRect(origin: target, size: sourceFrame.size)))
        focusSource()
        startTimer()
        guard options.forwardClicks else { return }
        let point = CGPoint(x: content.minX + local.x, y: content.minY + local.y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.sourceActive, self.isSourceTopmost(at: point) else { return }
            MouseSynth.button(.left, down: true, at: point)
            MouseSynth.button(.left, down: false, at: point)
        }
    }

    /// Thumbnail: double-click or the menu brings the original window forward where it is.
    private func showOriginal() {
        if mode == .interactive {
            clicked(at: CGPoint(x: crop.width / 2, y: crop.height / 2))
        } else {
            focusSource()
        }
    }

    private func focusSource() {
        if source.isMinimized { source.minimize(false) }
        source.focus()
        AXUIElementCreateApplication(source.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    private func isSourceTopmost(at point: CGPoint) -> Bool {
        WindowInfo.onScreen().first { $0.frame.contains(point) }?.id == sourceID
    }

    /// Interactive: once the original window is no longer in front, the crop returns over its area.
    private func checkFocus() {
        guard mode == .interactive, sourceActive, !tornDown, Date() > raisingUntil else { return }
        guard frontmostWindowID() != sourceID else { return }
        sourceActive = false
        stopTimer()
        hideOutline()
        if let f = source.frame {
            let global = CropGeometry.globalRect(crop: crop, windowFrame: f)
            setFrame(ScreenGeometry.toCocoa(global), display: false)
        }
        orderFrontRegardless()
    }

    private func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let element: AXUIElement = axApp.ax(kAXFocusedWindowAttribute) else { return nil }
        return WindowRef(element: element, pid: app.processIdentifier).windowID
    }

    private func showOutline(_ rect: CGRect) {
        let cocoa = ScreenGeometry.toCocoa(rect.insetBy(dx: -3, dy: -3))
        let panel = outline ?? OverlayPanel(frame: cocoa, level: .floating)
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.setFrame(cocoa, display: false)
        if outline == nil { panel.setContent(CropOutlineView()) }
        panel.orderFrontRegardless()
        outline = panel
    }

    private func hideOutline() {
        outline?.orderOut(nil)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show Original Window"), action: #selector(menuShowOriginal),
                     keyEquivalent: "").target = self
        if mode == .thumbnail {
            menu.addItem(withTitle: String(localized: "Actual Size", comment: "Menu item: give the crop window its original size"),
                         action: #selector(menuActualSize), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close", comment: "Menu item: close the crop window"),
                     action: #selector(menuClose), keyEquivalent: "").target = self
        return menu
    }

    @objc private func menuShowOriginal() { showOriginal() }
    @objc private func menuClose() { close() }

    @objc private func menuActualSize() {
        var f = frame
        f.origin.y += f.height - crop.height
        f.size = crop.size
        setFrame(f, display: true, animate: true)
        updateStreamScale()
    }

    // MARK: Source tracking

    private func installWatchers() {
        if let w = AXWatcher(pid: source.pid, callback: { [weak self] notification, _ in
            MainActor.assumeIsolated { self?.handleAX(notification) }
        }) {
            for n in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXWindowMiniaturizedNotification] {
                w.add(n, on: source.element)
            }
            w.add(kAXFocusedWindowChangedNotification)
            watcher = w
        }
        let ws = NSWorkspace.shared.notificationCenter
        let pid = source.pid
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if app?.processIdentifier == pid { self?.close() } }
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }))
    }

    private func handleAX(_ notification: String) {
        guard !tornDown else { return }
        switch notification {
        case kAXUIElementDestroyedNotification:
            if source.frame == nil { close() }
        case kAXMovedNotification:
            if sourceActive, let f = source.frame {
                showOutline(CropGeometry.globalRect(crop: crop, windowFrame: f))
            }
        default:
            checkFocus()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        guard !tornDown else { return }
        tornDown = true
        stopTimer()
        watcher?.invalidate()
        watcher = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        capture.onFrame = nil
        capture.onStop = nil
        capture.stop()
        outline?.orderOut(nil)
        outline?.close()
        outline = nil
        if mode == .interactive, options.restorePosition, source.frame != nil {
            source.setPosition(originalSourceOrigin)
        }
        onClosed?(self)
    }
}

/// The live image plus mouse handling of a crop window (top-left based coordinates).
final class CropContentView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let imageLayer = CALayer()
    private let interactive: Bool
    private var tracking: NSTrackingArea?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var dragged = false

    init(frame: NSRect, interactive: Bool) {
        self.interactive = interactive
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !interactive {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        if interactive {
            dragStart = (NSEvent.mouseLocation, window.frame.origin)
            dragged = false
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
        if !dragged && dx * dx + dy * dy < 9 { return }
        dragged = true
        window.setFrameOrigin(CGPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive, dragStart != nil else { return }
        dragStart = nil
        if !dragged { onClick?(convert(event.locationInWindow, from: nil)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
