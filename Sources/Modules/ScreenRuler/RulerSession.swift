import AppKit
import CoreVideo
import MacToysCore
import SwiftUI

/// One activation of Screen Ruler: the toolbar, and while a tool is selected, an overlay per
/// screen measuring a frozen capture (or live frames in continuous mode).
///
/// Spacing tools: move to measure, click to copy (⇧-click keeps the measurement on screen).
/// Bounds: drag a box; release copies it, ⇧ keeps it. Scroll changes the edge tolerance by 15,
/// ⌘1–⌘4 pick tools, arrow keys move one pixel, ⌫ removes the last kept measurement,
/// right-click ends the measurement, Esc closes everything.
@MainActor
final class RulerSession {
    @MainActor
    private final class Overlay {
        let screen: NSScreen
        let panel: OverlayPanel
        let canvas: RulerCanvas
        var frozen: PixelBuffer?
        var live: LiveCapture?
        var frame: CVPixelBuffer?
        var pinned: [RulerMark] = []

        init(screen: NSScreen, panel: OverlayPanel, canvas: RulerCanvas) {
            self.screen = screen
            self.panel = panel
            self.canvas = canvas
        }

        /// Capture pixels per point, from whatever pixels are measured.
        var scale: CGFloat { canvas.scale }
    }

    let model = RulerToolbarModel()
    private let settings: ScreenRulerSettings
    private let onEnd: () -> Void
    private var toolbar: OverlayPanel?
    private var overlays: [Overlay] = []
    private var monitor: Any?
    private var tolerance: Int
    private var current: (overlay: Int, mark: RulerMark)?
    private var dragStart: (overlay: Int, x: Int, y: Int)?
    private var pixel: (x: Int, y: Int) = (0, 0)
    private var scrollAccumulator: CGFloat = 0
    private var noteWork: DispatchWorkItem?
    private var generation = 0
    private var ended = false
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private let log = Log.for("screenruler")

    init(settings: ScreenRulerSettings, onEnd: @escaping () -> Void) {
        self.settings = settings
        self.onEnd = onEnd
        self.tolerance = Int(settings.pixelTolerance.rounded())
    }

    // MARK: Lifecycle

    func begin(tool: RulerTool?) {
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        let host = FirstClickHostingView(rootView: RulerToolbar(model: model, select: { [weak self] in self?.select($0) },
                                                                close: { [weak self] in self?.end() }))
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let frame = CGRect(x: (vf.midX - size.width / 2).rounded(), y: vf.maxY - size.height - 14,
                           width: size.width, height: size.height)
        let panel = OverlayPanel(frame: frame, interactive: true, acceptsKey: true,
                                 level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.present()
        toolbar = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.key(event) ? nil : event
        }
        if let tool { select(tool) }
    }

    /// Closes the toolbar and every overlay.
    func end() {
        guard !ended else { return }
        ended = true
        hideOverlays()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        onEnd()
    }

    /// Selecting the active tool again puts it away (the toolbar stays).
    func select(_ tool: RulerTool) {
        guard !ended else { return }
        if model.tool == tool { cancelInteraction(); return }
        model.tool = tool
        current = nil
        dragStart = nil
        if overlays.isEmpty { showOverlays() } else { pointerMoved() }
    }

    /// Ends the current measurement: the overlays go, the toolbar stays.
    func cancelInteraction() {
        model.tool = nil
        hideOverlays()
    }

    // MARK: Overlays

    private func showOverlays() {
        guard !model.busy else { return }
        generation += 1
        let token = generation
        if settings.continuousCapture {
            guard CGPreflightScreenCaptureAccess() else { permissionMissing(); return }
            for screen in NSScreen.screens { addOverlay(screen: screen, image: nil) }
            for (i, overlay) in overlays.enumerated() { startLive(overlay, index: i) }
            presentOverlays()
            return
        }
        model.busy = true
        Task { @MainActor [weak self] in
            guard CGPreflightScreenCaptureAccess() else { self?.model.busy = false; self?.permissionMissing(); return }
            let captures = await ScreenCapture.allScreens()
            guard let self, !self.ended, token == self.generation, self.model.tool != nil else {
                self?.model.busy = false
                return
            }
            self.model.busy = false
            for (screen, image) in captures { self.addOverlay(screen: screen, image: image) }
            if self.overlays.isEmpty {
                HUD.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle")
                self.model.tool = nil
                return
            }
            self.presentOverlays()
        }
    }

    private func permissionMissing() {
        model.tool = nil
        HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
        PermissionCenter.shared.request(.screenRecording)
    }

    private func addOverlay(screen: NSScreen, image: CGImage?) {
        let size = screen.frame.size
        let scale = image.map { CGFloat($0.width) / max(1, size.width) } ?? screen.backingScaleFactor
        let mm = CGDisplayScreenSize(screen.displayID).width
        let metrics = DisplayMetrics(pixelsPerPoint: scale, pixelWidth: size.width * scale, physicalWidthMM: mm)
        let style = RulerStyle(color: settings.lineColor.nsColor, drawFeet: settings.drawFeet, extraUnit: settings.extraUnit)
        let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
        panel.acceptsMouseMovedEvents = true
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        if let image {
            container.layer?.contents = image
            container.layer?.contentsGravity = .resize
        }
        let canvas = RulerCanvas(frame: container.bounds, index: overlays.count, style: style, scale: scale, metrics: metrics)
        canvas.autoresizingMask = [.width, .height]
        canvas.session = self
        container.addSubview(canvas)
        panel.contentView = container
        let overlay = Overlay(screen: screen, panel: panel, canvas: canvas)
        if let image { overlay.frozen = PixelBuffer(image: image) }
        overlays.append(overlay)
    }

    private func presentOverlays() {
        for o in overlays { o.panel.orderFrontRegardless() }
        let target = overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) } ?? overlays.first
        if let target {
            target.panel.makeKey()
            target.panel.makeFirstResponder(target.canvas)
        }
        toolbar?.orderFrontRegardless()
        pointerMoved()
    }

    private func startLive(_ overlay: Overlay, index: Int) {
        let capture = LiveCapture()
        overlay.live = capture
        capture.onFrame = { [weak self, weak overlay] buffer in
            guard let self, let overlay else { return }
            overlay.frame = buffer
            overlay.canvas.scale = CGFloat(CVPixelBufferGetWidth(buffer)) / max(1, overlay.screen.frame.width)
            if self.overlayIndexUnderMouse() == index { self.measure() }
        }
        capture.onStop = { [weak self] error in
            if let error { self?.log.error("Live capture stopped: \(error.localizedDescription, privacy: .public)") }
        }
        let displayID = overlay.screen.displayID
        let scale = overlay.screen.backingScaleFactor
        Task { @MainActor [weak self, weak overlay] in
            do {
                try await capture.start(.display(displayID), fps: 15, scale: scale)
                // The overlay may have closed while the stream was starting; nothing else would stop it.
                if overlay?.live !== capture { capture.stop() }
            } catch {
                self?.log.error("Continuous capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func hideOverlays() {
        generation += 1
        model.busy = false
        current = nil
        dragStart = nil
        for o in overlays {
            o.live?.stop()
            o.live = nil
            o.canvas.session = nil
            o.panel.orderOut(nil)
            o.panel.contentView = nil
        }
        overlays.removeAll()
        toolbar?.makeKey()
    }

    // MARK: Input

    func pointerMoved() {
        guard let index = overlayIndexUnderMouse() else { return }
        let o = overlays[index]
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - o.screen.frame.minX, y: o.screen.frame.maxY - mouse.y)
        pixel = (Int((local.x * o.scale).rounded(.down)), Int((local.y * o.scale).rounded(.down)))
        if !o.panel.isKeyWindow, dragStart == nil {
            o.panel.makeKey()
            o.panel.makeFirstResponder(o.canvas)
        }
        measure()
    }

    func mouseDown(shift: Bool) {
        guard let tool = model.tool, let index = overlayIndexUnderMouse() else { return }
        pointerMoved()
        if tool == .bounds {
            dragStart = (index, pixel.x, pixel.y)
            measure()
            return
        }
        guard let current else { return }
        if shift {
            overlays[current.overlay].pinned.append(current.mark)
            redraw()
        } else {
            copy(current.mark, overlaysStay: false)
            cancelInteraction()
        }
    }

    func mouseUp(shift: Bool) {
        guard model.tool == .bounds, dragStart != nil else { return }
        pointerMoved()
        dragStart = nil
        guard let current else { return }
        if shift {
            overlays[current.overlay].pinned.append(current.mark)
        } else {
            copy(current.mark, overlaysStay: true)
        }
        self.current = nil
        redraw()
    }

    func scroll(_ dy: CGFloat) {
        scrollAccumulator += dy
        guard abs(scrollAccumulator) >= 1 else { return }
        tolerance = min(255, max(0, tolerance + (scrollAccumulator > 0 ? 15 : -15)))
        scrollAccumulator = 0
        showNote(String(localized: "Tolerance \(tolerance)", comment: "Screen Ruler: the edge-detection tolerance changed; the number is 0–255"))
        measure()
    }

    /// Returns true when handled.
    private func key(_ event: NSEvent) -> Bool {
        // The monitor sees every MacToys window; only handle keys aimed at the ruler.
        guard let window = event.window,
              window === toolbar || overlays.contains(where: { $0.panel === window }) else { return false }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let arrows: Set<Int> = [123, 124, 125, 126]
        if arrows.contains(Int(event.keyCode)), model.tool == nil { return false }
        switch Int(event.keyCode) {
        case 53: end()                                                            // esc
        case 18: select(.bounds)                                                  // 1
        case 19: select(.spacing)                                                 // 2
        case 20: select(.horizontal)                                              // 3
        case 21: select(.vertical)                                                // 4
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, step)
        case 126: nudge(0, -step)
        case 51, 117:                                                             // ⌫ / ⌦
            guard let i = overlays.lastIndex(where: { !$0.pinned.isEmpty }) else { return false }
            overlays[i].pinned.removeLast()
            redraw()
        case 8 where event.modifierFlags.contains(.command):                      // ⌘C
            guard let current else { return false }
            copy(current.mark, overlaysStay: true)
        default: return false
        }
        return true
    }

    // MARK: Measuring

    private func overlayIndexUnderMouse() -> Int? {
        if let drag = dragStart { return drag.overlay }
        let mouse = NSEvent.mouseLocation
        return overlays.firstIndex { NSMouseInRect(mouse, $0.screen.frame, false) }
    }

    private func nudge(_ dx: Int, _ dy: Int) {
        guard model.tool != nil, let index = overlayIndexUnderMouse() else { return }
        let o = overlays[index]
        let px = pixel.x + dx, py = pixel.y + dy
        let local = CGPoint(x: (CGFloat(px) + 0.5) / o.scale, y: (CGFloat(py) + 0.5) / o.scale)
        guard local.x >= 0, local.y >= 0, local.x < o.screen.frame.width, local.y < o.screen.frame.height else { return }
        MouseSynth.warp(to: ScreenGeometry.toAX(CGPoint(x: o.screen.frame.minX + local.x, y: o.screen.frame.maxY - local.y)))
        pixel = (px, py)
        measure()
    }

    /// Recomputes the live measurement at the current pixel and redraws.
    private func measure() {
        guard let tool = model.tool, let index = overlayIndexUnderMouse() else { current = nil; redraw(); return }
        let o = overlays[index]
        if tool == .bounds {
            if let d = dragStart {
                current = (index, RulerMark(tool: .bounds, rect: .spanning(d.x, d.y, pixel.x, pixel.y),
                                            anchorX: pixel.x, anchorY: pixel.y))
            } else {
                current = nil
            }
            redraw()
            return
        }
        let x = pixel.x, y = pixel.y
        let t = tolerance, perChannel = settings.perChannelDetection
        let rect: PixelRect?
        if let frozen = o.frozen {
            rect = EdgeDetector.edges(in: frozen, x: x, y: y, tolerance: t, perChannel: perChannel)
        } else if let frame = o.frame {
            rect = LiveFrame.read(frame) { EdgeDetector.edges(in: $0, x: x, y: y, tolerance: t, perChannel: perChannel) }
        } else {
            rect = nil
        }
        current = rect.map { (index, RulerMark(tool: tool, rect: $0, anchorX: x, anchorY: y)) }
        redraw()
    }

    private func redraw() {
        for (i, o) in overlays.enumerated() {
            var marks = o.pinned
            if let current, current.overlay == i { marks.append(current.mark) }
            if o.canvas.marks != marks { o.canvas.marks = marks }
        }
    }

    private func showNote(_ text: String) {
        noteWork?.cancel()
        for o in overlays { o.canvas.note = text }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { for o in self?.overlays ?? [] { o.canvas.note = nil } }
        }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// Copies the measurement; confirms on the canvas while overlays stay up (they cover the
    /// HUD's level), otherwise with the HUD.
    private func copy(_ mark: RulerMark, overlaysStay: Bool) {
        let text = MeasurementText.clipboard(width: mark.width, height: mark.height)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if overlaysStay { showNote(String(localized: "Copied", comment: "Screen Ruler: the measurement was copied to the clipboard")) } else { HUD.show("Copied \(text)", symbol: "ruler") }
    }
}
