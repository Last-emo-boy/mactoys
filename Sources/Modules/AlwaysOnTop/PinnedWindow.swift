import AppKit
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// One window kept on top: a floating panel at the window's frame that shows the border and,
/// while another window is in front, a live ScreenCaptureKit mirror of the window.
@MainActor
final class PinnedWindow {
    let window: WindowRef
    let windowID: CGWindowID
    let appName: String
    private(set) var title: String
    /// Last known window frame (global top-left coordinates).
    private(set) var frame: CGRect
    private(set) var presentation: PinPresentation = .hidden

    /// Asked to bring the real window forward (pointer entered or clicked the mirror).
    var onRaiseRequest: ((PinnedWindow) -> Void)?
    /// The window closed, its app quit, or capture failed for good.
    var onGone: ((PinnedWindow) -> Void)?
    /// Something changed that may affect how pins are presented (minimized, focus, first frame).
    var onChange: (() -> Void)?
    /// The window moved or resized (its own panel already followed).
    var onGeometryChange: (() -> Void)?
    var onTitleChange: (() -> Void)?

    private let panel: OverlayPanel
    private let view: PinView
    /// Replaced on every (re)start, so a start still in flight can never leave a stream behind.
    private var capture = LiveCapture()
    private var watcher: AXWatcher?
    private var resizeWork: DispatchWorkItem?
    private var style = PinView.Style(border: 4, color: nil, rounded: true)
    private var frameRate = 30
    private var isTornDown = false
    private var captureRetries = 0
    /// Set while a (re)started stream hasn't delivered a frame yet.
    private var awaitingFrame = false
    /// While set, the window counts as frontmost even if activation hasn't landed yet.
    private var raisingUntil: Date?
    private let log = Log.for("alwaysontop")

    init(window: WindowRef, windowID: CGWindowID, frame: CGRect) {
        self.window = window
        self.windowID = windowID
        AXUIElementSetMessagingTimeout(window.element, 0.5)
        self.frame = frame
        self.appName = window.appName
        self.title = window.title ?? ""
        let cocoa = ScreenGeometry.toCocoa(frame)
        panel = OverlayPanel(frame: cocoa, interactive: true, acceptsKey: false, level: .floating)
        // The mirror belongs to the window's Space; ordering it front moves it to the active one
        // instead of switching Spaces. Mission Control hides it.
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        view = PinView(frame: CGRect(origin: .zero, size: cocoa.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.onRaise = { [weak self] in
            guard let self else { return }
            self.onRaiseRequest?(self)
        }
    }

    // MARK: Lifecycle

    func start(style: PinView.Style, frameRate: Int, raiseOnHover: Bool) {
        self.style = style
        self.frameRate = frameRate
        view.raiseOnHover = raiseOnHover
        view.apply(style: style)
        layoutPanel()
        installWatcher()
        startCapture()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        resizeWork?.cancel()
        watcher?.invalidate()
        watcher = nil
        capture.onFrame = nil
        capture.onStop = nil
        capture.stop()
        panel.orderOut(nil)
        panel.close()
    }

    private func startCapture() {
        capture.onFrame = nil
        capture.onStop = nil
        capture.stop()
        let capture = LiveCapture()
        self.capture = capture
        capture.onFrame = { [weak self] buffer in
            guard let self, !self.isTornDown else { return }
            let first = !self.view.hasFrame
            self.view.show(buffer)
            if self.awaitingFrame {
                self.awaitingFrame = false
                self.captureRetries = 0
            }
            if first { self.onChange?() }
        }
        capture.onStop = { [weak self] error in
            guard let self, !self.isTornDown else { return }
            self.log.notice("Mirror stream stopped: \(error?.localizedDescription ?? "-", privacy: .public)")
            self.recoverCapture()
        }
        let scale = screenScale
        awaitingFrame = true
        Task { [weak self, capture, windowID, frameRate] in
            do {
                try await capture.start(.window(windowID), fps: frameRate, scale: scale)
                guard let self else { capture.stop(); return }
                if self.isTornDown || self.capture !== capture { capture.stop() }
            } catch {
                guard let self, !self.isTornDown, self.capture === capture else { return }
                self.log.error("Mirror failed for window \(windowID): \(error.localizedDescription, privacy: .public)")
                if (error as? CaptureError) == .notPermitted {
                    self.onGone?(self)
                } else {
                    self.recoverCapture()
                }
            }
        }
    }

    /// Restarts a stream that stopped while the window still exists; gives up after a few tries.
    private func recoverCapture() {
        guard window.frame != nil, captureRetries < 3 else {
            onGone?(self)
            return
        }
        captureRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.startCapture()
        }
    }

    private var screenScale: CGFloat {
        ScreenGeometry.screen(forAX: frame)?.backingScaleFactor ?? 2
    }

    // MARK: Settings

    func update(style newStyle: PinView.Style, frameRate newRate: Int, raiseOnHover: Bool) {
        view.raiseOnHover = raiseOnHover
        if newStyle != style {
            style = newStyle
            view.apply(style: newStyle)
            layoutPanel()
        }
        if newRate != frameRate {
            frameRate = newRate
            startCapture()
        }
    }

    // MARK: Presentation

    /// Re-reads the window frame; returns false when the window no longer exists.
    @discardableResult
    func refreshFrame() -> Bool {
        guard let f = window.frame else { return false }
        if f != frame {
            let resized = f.size != frame.size
            frame = f
            layoutPanel()
            if resized { scheduleStreamResize() }
        }
        return true
    }

    var isFullScreen: Bool { window.isFullScreen }
    var hasFrame: Bool { view.hasFrame }

    var isRaising: Bool {
        guard let until = raisingUntil else { return false }
        if until > Date() { return true }
        raisingUntil = nil
        return false
    }

    /// Marks the window as being brought forward for a short grace period.
    func beginRaise() {
        raisingUntil = Date().addingTimeInterval(0.6)
    }

    /// Shows the border/mirror as decided by the module. `exclusions` are global rects of
    /// pinned windows that must stay visible above this one.
    func present(_ p: PinPresentation, exclusions: [CGRect]) {
        let panelFrame = PinGeometry.panelFrame(window: frame, border: style.border)
        view.setExclusions(p == .mirror ? PinGeometry.exclusions(panel: panelFrame, others: exclusions) : [])
        let wasMirror = presentation == .mirror
        presentation = p
        switch p {
        case .hidden:
            view.setMirroring(false)
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        case .border:
            view.setMirroring(false)
            panel.ignoresMouseEvents = true
            if style.color == nil { panel.orderOut(nil) } else if !panel.isVisible { panel.orderFrontRegardless() }
        case .mirror:
            view.setMirroring(true)
            panel.ignoresMouseEvents = false
            // The window that just lost focus was the most recent one: its mirror goes on top.
            if !wasMirror || !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func layoutPanel() {
        let target = ScreenGeometry.toCocoa(PinGeometry.panelFrame(window: frame, border: style.border))
        if panel.frame != target { panel.setFrame(target, display: true) }
        view.needsLayout = true
    }

    private func scheduleStreamResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isTornDown else { return }
            let size = self.frame.size
            let scale = self.screenScale
            Task { await self.capture.update(sourceRect: CGRect(origin: .zero, size: size), scale: scale) }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Accessibility notifications

    private func installWatcher() {
        let watcher = AXWatcher(pid: window.pid) { [weak self] notification, _ in
            MainActor.assumeIsolated { self?.handle(notification) }
        }
        guard let watcher else {
            log.error("Could not observe \(self.appName, privacy: .public)")
            return
        }
        for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
            watcher.add(n, on: window.element)
        }
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            watcher.add(n)
        }
        self.watcher = watcher
    }

    private func handle(_ notification: String) {
        guard !isTornDown else { return }
        switch notification {
        case kAXUIElementDestroyedNotification:
            // Some apps recycle elements; trust the destroy only when the window is really gone.
            if window.frame == nil { onGone?(self) }
        case kAXMovedNotification, kAXResizedNotification:
            if !refreshFrame() { onGone?(self); return }
            onGeometryChange?()
        case kAXTitleChangedNotification:
            title = window.title ?? title
            onTitleChange?()
        default:
            onChange?()
        }
    }
}
