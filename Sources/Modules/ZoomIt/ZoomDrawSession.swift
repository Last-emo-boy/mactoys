import AppKit
import CoreImage
import MacToysCore
import QuartzCore
import UniformTypeIdentifiers

/// Calls a closure from a display link (CADisplayLink needs an Objective-C target).
final class FrameDriver: NSObject {
    private let onFrame: () -> Void
    init(_ onFrame: @escaping () -> Void) { self.onFrame = onFrame }
    @objc func tick(_ link: CADisplayLink) { onFrame() }
}

/// A layer-hosting view: its layer tree is ours, with a y-up geometry.
final class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the annotations and forwards every input event to the session.
final class AnnotationView: NSView {
    weak var session: ZoomDrawSession?
    var cursor: NSCursor = .arrow { didSet { window?.invalidateCursorRects(for: self) } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Keeps clicks on this window when nothing opaque is behind (drawing over the live screen).
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.004).cgColor)
        ctx.fill(dirtyRect)
        session?.render(in: ctx, dirty: dirtyRect)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseMoved(with event: NSEvent) { session?.pointerMoved(point(event)) }
    override func mouseDown(with event: NSEvent) { session?.mouseDown(point(event), flags: event.modifierFlags) }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(point(event), flags: event.modifierFlags) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(point(event)) }
    override func rightMouseDown(with event: NSEvent) { session?.rightClick() }
    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        session?.scroll(dy)
    }
    override func keyDown(with event: NSEvent) { if session?.keyDown(event) != true { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { session?.flagsChanged(event.modifierFlags) }
}

/// Zoom and draw on one screen.
///
/// Zoom mode: the frozen screen magnifies toward the pointer and pans as it moves; scroll or ↑/↓
/// change the level; a left click (or ⌃⌥2) starts drawing; right-click or Esc leaves.
/// Draw mode: ZoomIt's keys — R G B Y O P colors (⇧ highlighter), X blur, ⇧ line, ⌃ rectangle,
/// Tab ellipse, ⌃⇧ arrow, T / ⇧T text, ⌘Z undo, E erase all, W whiteboard, K blackboard,
/// Space centers the pointer, scroll or ↑/↓ pen width, ⌘C / ⌘S copy or save (⇧: cropped).
@MainActor
final class ZoomDrawSession {
    enum Background {
        case frozen(CGImage)
        /// Drawing straight over the screen (Live Zoom, or no Screen Recording permission).
        case live
    }

    private enum UndoStep {
        case added
        case erased(Annotation, Int)
        case cleared([Annotation])
    }

    private enum CropPurpose { case copy, save }

    let screen: NSScreen
    let state = DrawState()
    let startedAsZoom: Bool
    var onEnd: (() -> Void)?
    var onRecord: (() -> Void)?

    private let settings: ZoomItSettings
    private let background: Background
    private let size: CGSize
    private let panel: OverlayPanel
    private let annotationView: AnnotationView
    private let imageLayer = CALayer()
    private let boardLayer = CALayer()
    private var toolbar: OverlayPanel?
    private var displayLink: CADisplayLink?
    private var driver: FrameDriver?

    private var level: Double = 1
    private var animation: (from: Double, to: Double, start: CFTimeInterval, duration: Double, then: (() -> Void)?)?
    private var visible: CGRect
    private var pointer: CGPoint
    private var panLocked = false

    private var boards: [Board: [Annotation]] = [:]
    private var history: [Board: [UndoStep]] = [:]
    private var inProgress: Annotation?
    private var dragStart: CGPoint?
    private var typing: TextItem?
    private var crop: (purpose: CropPurpose, start: CGPoint?, current: CGPoint?)?
    private var tabHeld = false
    private var scrollAccumulator: CGFloat = 0
    private var blurred: CGImage?
    private var ending = false
    private var closed = false
    private var stateObserver: Any?
    private let log = Log.for("zoomit")

    var isDrawing: Bool { state.drawing }
    var annotations: [Annotation] { boards[state.board] ?? [] }
    /// The toolbar window, kept out of recordings.
    var toolbarWindowNumber: Int? { toolbar.map { $0.windowNumber } }

    init(screen: NSScreen, background: Background, zoom: Bool, settings: ZoomItSettings) {
        self.screen = screen
        self.background = background
        self.startedAsZoom = zoom
        self.settings = settings
        self.size = screen.frame.size
        self.visible = CGRect(origin: .zero, size: screen.frame.size)
        let mouse = NSEvent.mouseLocation
        self.pointer = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        state.color = settings.penColor
        state.width = CGFloat(settings.penWidth)
        if case .live = background { state.blurAvailable = false }

        panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
        panel.acceptsMouseMovedEvents = true
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let host = LayerHostView(frame: container.bounds)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        annotationView = AnnotationView(frame: container.bounds)
        annotationView.autoresizingMask = [.width, .height]
        container.addSubview(annotationView)
        panel.contentView = container

        if case .frozen(let image) = background {
            imageLayer.contents = image
            imageLayer.contentsGravity = .resize
            imageLayer.magnificationFilter = settings.smoothImage ? .linear : .nearest
            imageLayer.minificationFilter = .linear
            imageLayer.frame = CGRect(origin: .zero, size: size)
            host.layer?.addSublayer(imageLayer)
        }
        boardLayer.frame = CGRect(origin: .zero, size: size)
        boardLayer.isHidden = true
        host.layer?.addSublayer(boardLayer)
        annotationView.session = self
    }

    // MARK: Lifecycle

    func begin() {
        panel.present()
        panel.makeFirstResponder(annotationView)
        if startedAsZoom {
            let target = ZoomMath.clamp(settings.initialZoom)
            if settings.animateZoom { animate(to: target, duration: 0.32) } else { setLevel(target) }
        } else {
            startDrawing()
        }
        updateCursor()
    }

    /// Leaves, zooming back out first when zoomed.
    func end() {
        guard !ending else { return }
        ending = true
        commitText()
        hideToolbar()
        state.drawing = false
        if startedAsZoom, settings.animateZoom, level > 1.01 {
            panLocked = false
            // `frame()` closes once this finishes; input is ignored meanwhile so nothing replaces it.
            animate(to: 1, duration: 0.25)
        } else {
            close()
        }
    }

    /// Closes at once (module stopped). Idempotent.
    func close() {
        guard !closed else { return }
        closed = true
        ending = true
        animation = nil
        displayLink?.invalidate()
        displayLink = nil
        driver = nil
        hideToolbar()
        annotationView.session = nil
        panel.orderOut(nil)
        panel.contentView = nil
        onEnd?()
        onEnd = nil
    }

    /// ⌃⌥2 or a left click in zoom mode: freeze the view and draw on it.
    func startDrawing() {
        guard !state.drawing, !ending else { return }
        animation = nil
        panLocked = true
        state.drawing = true
        blurred = nil
        if settings.showToolbar { showToolbar() }
        updateCursor()
    }

    /// Right-click: back to panning (zoom mode, drawings cleared) or leave (draw-only mode).
    func stopDrawing() {
        guard state.drawing else { return }
        commitText()
        if startedAsZoom {
            state.drawing = false
            boards.removeAll()
            history.removeAll()
            state.board = .screen
            state.canUndo = false
            applyBoard()
            panLocked = false
            hideToolbar()
            pointerMoved(currentPointer())
            annotationView.needsDisplay = true
            updateCursor()
        } else {
            end()
        }
    }

    // MARK: Zoom

    private func setLevel(_ z: Double) {
        level = ZoomMath.clamp(z)
        updateVisible()
    }

    private func animate(to target: Double, duration: Double, then: (() -> Void)? = nil) {
        animation = (level, ZoomMath.clamp(target), CACurrentMediaTime(), duration, then)
        if displayLink == nil {
            let driver = FrameDriver { [weak self] in MainActor.assumeIsolated { self?.frame() } }
            let link = annotationView.displayLink(target: driver, selector: #selector(FrameDriver.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.driver = driver
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func frame() {
        guard let a = animation else {
            displayLink?.isPaused = true
            if ending { close() }
            return
        }
        let t = a.duration <= 0 ? 1 : (CACurrentMediaTime() - a.start) / a.duration
        level = ZoomMath.interpolate(from: a.from, to: a.to, progress: t)
        if !panLocked { pointer = currentPointer() }
        updateVisible()
        if t >= 1 {
            animation = nil
            displayLink?.isPaused = true
            a.then?()
            if ending { close() }
        }
    }

    private func currentPointer() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y)
    }

    private func updateVisible() {
        if !panLocked { visible = ZoomMath.sourceRect(pointer: pointer, screen: size, level: level) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = ZoomMath.layerFrame(showing: visible, screen: size)
        CATransaction.commit()
    }

    // MARK: Input

    func pointerMoved(_ p: CGPoint) {
        guard !ending else { return }
        pointer = p
        if !state.drawing, !panLocked, animation == nil { updateVisible() }
        if state.tool == .eraser, state.drawing, NSEvent.pressedMouseButtons & 1 != 0 { erase(at: p) }
    }

    func mouseDown(_ p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard !ending else { return }
        if !state.drawing { startDrawing() }
        if crop != nil { crop?.start = p; crop?.current = p; annotationView.needsDisplay = true; return }
        commitText()
        if state.tool == .text { beginText(at: p, rightAligned: flags.contains(.shift)); return }
        if state.tool == .eraser { erase(at: p); return }
        dragStart = p
        inProgress = makeShape(from: p, to: p, flags: flags)
        invalidate(inProgress)
    }

    func mouseDragged(_ p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard !ending else { return }
        pointer = p
        if crop?.start != nil { crop?.current = p; annotationView.needsDisplay = true; return }
        if state.tool == .eraser { erase(at: p); return }
        guard let start = dragStart, let current = inProgress else { return }
        let old = current.bounds
        if case .pen(var pts) = current.shape, effectiveTool(flags) == state.tool {
            if let last = pts.last, hypot(last.x - p.x, last.y - p.y) < 0.75 { return }
            pts.append(p)
            inProgress?.shape = .pen(pts)
        } else if case .blur(var pts) = current.shape {
            pts.append(p)
            inProgress?.shape = .blur(pts)
        } else {
            inProgress = makeShape(from: start, to: p, flags: flags)
        }
        annotationView.setNeedsDisplay(old.union(inProgress?.bounds ?? old))
    }

    func mouseUp(_ p: CGPoint) {
        guard !ending else { return }
        if let c = crop, let start = c.start {
            crop = nil
            annotationView.needsDisplay = true
            let rect = Annotation.rect(start, p)
            guard rect.width >= 2, rect.height >= 2 else { return }
            export(crop: rect, purpose: c.purpose)
            return
        }
        guard let item = inProgress else { return }
        inProgress = nil
        dragStart = nil
        add(item)
    }

    func rightClick() {
        guard !ending else { return }
        if crop != nil { crop = nil; annotationView.needsDisplay = true; return }
        if state.drawing { stopDrawing() } else { end() }
    }

    /// Trackpads send many small deltas; one step per notch of travel.
    func scroll(_ dy: CGFloat) {
        guard !ending else { return }
        scrollAccumulator += dy
        guard abs(scrollAccumulator) >= 1 else { return }
        adjust(up: scrollAccumulator > 0)
        scrollAccumulator = 0
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard !ending else { return }
        guard let start = dragStart, let current = inProgress else { return }
        if case .pen = current.shape, effectiveTool(flags) == state.tool { return }
        if case .blur = current.shape { return }
        let old = current.bounds
        inProgress = makeShape(from: start, to: pointer, flags: flags)
        annotationView.setNeedsDisplay(old.union(inProgress?.bounds ?? old))
    }

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 48 { tabHeld = false; flagsChanged(event.modifierFlags) }
    }

    /// Returns true when handled.
    func keyDown(_ event: NSEvent) -> Bool {
        guard !ending else { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let code = Int(event.keyCode)

        if code == 53 {                                                       // esc
            if typing != nil { commitText() } else if crop != nil { crop = nil; annotationView.needsDisplay = true } else { end() }
            return true
        }
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": undo()
            case "c": if shift { beginCrop(.copy) } else { export(crop: nil, purpose: .copy) }
            case "s": if shift { beginCrop(.save) } else { export(crop: nil, purpose: .save) }
            default: return false
            }
            return true
        }
        if typing != nil { return type(event) }
        switch code {
        case 126: adjust(up: true); return true                              // ↑
        case 125: adjust(up: false); return true                             // ↓
        case 48: tabHeld = true; flagsChanged(flags); return true             // tab
        default: break
        }
        // Zoom mode has no letter keys; swallow them rather than beep.
        guard state.drawing else { return true }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let color = PenColor.forKey(ch) {
            state.color = color
            state.tool = shift ? .highlighter : (state.tool == .highlighter || state.tool == .blur || state.tool == .eraser ? .pen : state.tool)
            updateCursor()
            return true
        }
        switch ch {
        case "x": if state.blurAvailable { state.tool = .blur; updateCursor() }
        case "t": beginText(at: pointer, rightAligned: shift)
        case "e": clearAll()
        case "w": toggleBoard(.whiteboard)
        case "k": toggleBoard(.blackboard)
        case " ":
            let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            MouseSynth.warp(to: ScreenGeometry.toAX(center))
            pointer = CGPoint(x: size.width / 2, y: size.height / 2)
        default: return false
        }
        return true
    }

    // MARK: Drawing

    private func effectiveTool(_ flags: NSEvent.ModifierFlags) -> DrawTool {
        DrawTool.effective(state.tool, shift: flags.contains(.shift),
                           control: flags.contains(.control) || flags.contains(.command), tab: tabHeld)
    }

    private func makeShape(from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags) -> Annotation {
        let highlighter = state.tool == .highlighter
        let width = Annotation.strokeWidth(pen: state.width, highlighter: highlighter)
        let color = state.color.rgba
        let shape: Annotation.Shape
        switch effectiveTool(flags) {
        case .line: shape = .line(a, b)
        case .rectangle: shape = .rectangle(a, b)
        case .ellipse: shape = .ellipse(a, b)
        case .arrow: shape = .arrow(a, b)
        case .blur: shape = .blur([a, b])
        default: shape = .pen(a == b ? [a] : [a, b])
        }
        if case .blur = shape { return Annotation(shape: shape, color: color, width: max(16, state.width * 4)) }
        return Annotation(shape: shape, color: color, width: width, highlighter: highlighter)
    }

    private func add(_ item: Annotation) {
        if case .blur = item.shape, blurred == nil { blurred = makeBlurred() }
        boards[state.board, default: []].append(item)
        history[state.board, default: []].append(.added)
        state.canUndo = true
        invalidate(item)
    }

    private func erase(at p: CGPoint) {
        var list = boards[state.board] ?? []
        guard let i = list.lastIndex(where: { $0.hit(p, tolerance: 6) }) else { return }
        let item = list.remove(at: i)
        boards[state.board] = list
        history[state.board, default: []].append(.erased(item, i))
        state.canUndo = true
        invalidate(item)
    }

    private func clearAll() {
        let list = boards[state.board] ?? []
        guard !list.isEmpty else { return }
        boards[state.board] = []
        history[state.board, default: []].append(.cleared(list))
        state.canUndo = true
        annotationView.needsDisplay = true
    }

    func undo() {
        guard let step = history[state.board]?.popLast() else { return }
        var list = boards[state.board] ?? []
        switch step {
        case .added: if !list.isEmpty { list.removeLast() }
        case .erased(let item, let i): list.insert(item, at: min(i, list.count))
        case .cleared(let items): list = items
        }
        boards[state.board] = list
        state.canUndo = !(history[state.board]?.isEmpty ?? true)
        annotationView.needsDisplay = true
    }

    func clear() { clearAll() }

    func toggleBoard(_ board: Board) {
        commitText()
        state.board = state.board == board ? .screen : board
        state.canUndo = !(history[state.board]?.isEmpty ?? true)
        applyBoard()
        annotationView.needsDisplay = true
    }

    private func applyBoard() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch state.board {
        case .screen: boardLayer.isHidden = true
        case .whiteboard: boardLayer.isHidden = false; boardLayer.backgroundColor = NSColor.white.cgColor
        case .blackboard: boardLayer.isHidden = false; boardLayer.backgroundColor = NSColor.black.cgColor
        }
        CATransaction.commit()
    }

    private func adjust(up: Bool) {
        if var t = typing {
            let old = Annotation.textRect(t)
            t.size = min(200, max(8, t.size + (up ? 2 : -2)))
            typing = t
            annotationView.setNeedsDisplay(old.union(Annotation.textRect(t)).insetBy(dx: -8, dy: -8))
        } else if state.drawing {
            state.width = min(60, max(1, state.width + (up ? 1 : -1)))
            updateCursor()
        } else {
            animate(to: ZoomMath.step(animation?.to ?? level, zoomIn: up), duration: settings.animateZoom ? 0.14 : 0)
        }
    }

    // MARK: Text

    private func beginText(at p: CGPoint, rightAligned: Bool) {
        commitText()
        if !state.drawing { startDrawing() }
        typing = TextItem(text: "", origin: p, fontName: settings.textFont, size: CGFloat(settings.textSize),
                          rightAligned: rightAligned)
        updateCursor()
        annotationView.needsDisplay = true
    }

    private func type(_ event: NSEvent) -> Bool {
        guard var t = typing else { return false }
        let old = Annotation.textRect(t)
        switch Int(event.keyCode) {
        case 36, 76: t.text += "\n"
        case 51: if !t.text.isEmpty { t.text.removeLast() }
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            t.text += chars
        }
        typing = t
        annotationView.setNeedsDisplay(old.union(Annotation.textRect(t)).insetBy(dx: -t.size, dy: -t.size))
        return true
    }

    private func commitText() {
        guard let t = typing else { return }
        typing = nil
        if !t.text.isEmpty { add(Annotation(shape: .text(t), color: state.color.rgba, width: 1)) }
        annotationView.needsDisplay = true
        updateCursor()
    }

    // MARK: Rendering

    func render(in ctx: CGContext, dirty: CGRect) {
        let canvas = CGRect(origin: .zero, size: size)
        let items = annotations.filter { $0.bounds.intersects(dirty) }
        AnnotationRenderer.draw(items, in: ctx, blurred: blurred, canvas: canvas)
        if let item = inProgress {
            if case .blur = item.shape, blurred == nil { blurred = makeBlurred() }
            AnnotationRenderer.draw(item, in: ctx, blurred: blurred, canvas: canvas)
        }
        if let t = typing { AnnotationRenderer.drawText(t, color: state.color.rgba, in: ctx, caret: true) }
        if let c = crop, let a = c.start, let b = c.current {
            let r = Annotation.rect(a, b)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addRect(canvas)
            ctx.addRect(r)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func invalidate(_ item: Annotation?) {
        guard let item else { return }
        annotationView.setNeedsDisplay(item.bounds)
    }

    /// The visible part of the frozen screen, at backing resolution.
    private func visibleImage() -> CGImage? {
        guard case .frozen(let image) = background else { return nil }
        let s = CGFloat(image.width) / size.width
        let px = CGRect(x: visible.minX * s, y: visible.minY * s, width: visible.width * s, height: visible.height * s).integral
        return image.cropping(to: px)
    }

    /// A blurred copy of what's visible, for blur strokes.
    private func makeBlurred() -> CGImage? {
        guard let visibleImage = visibleImage() else { return nil }
        let input = CIImage(cgImage: visibleImage)
        let radius = 14 * Double(visibleImage.width) / Double(size.width)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: nil).createCGImage(output, from: input.extent)
    }

    // MARK: Export

    private func beginCrop(_ purpose: CropPurpose) {
        commitText()
        crop = (purpose, nil, nil)
        annotationView.cursor = .crosshair
    }

    /// What the overlay shows (background + annotations), at backing resolution.
    func composite(crop: CGRect?) -> CGImage? {
        let scale = screen.backingScaleFactor
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let canvas = CGRect(origin: .zero, size: size)
        switch state.board {
        case .whiteboard: ctx.setFillColor(NSColor.white.cgColor); ctx.fill(canvas)
        case .blackboard: ctx.setFillColor(NSColor.black.cgColor); ctx.fill(canvas)
        case .screen:
            if let image = visibleImage() {
                ctx.interpolationQuality = settings.smoothImage ? .high : .none
                AnnotationRenderer.drawUpright(image, in: canvas, ctx: ctx)
            }
        }
        var items = annotations
        if let t = typing, !t.text.isEmpty { items.append(Annotation(shape: .text(t), color: state.color.rgba, width: 1)) }
        AnnotationRenderer.draw(items, in: ctx, blurred: blurred, canvas: canvas)
        guard let full = ctx.makeImage() else { return nil }
        guard let crop else { return full }
        return full.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                        width: crop.width * scale, height: crop.height * scale).integral)
    }

    private func export(crop: CGRect?, purpose: CropPurpose) {
        annotationView.cursor = .arrow
        updateCursor()
        if case .live = background, state.board == .screen {
            exportLive(crop: crop, purpose: purpose)
            return
        }
        guard let image = composite(crop: crop) else { return }
        deliver(image, purpose: purpose)
    }

    /// Over the live screen there is no frozen image: capture what's on screen, our drawing
    /// (and Live Zoom) included, without the toolbar.
    private func exportLive(crop: CGRect?, purpose: CropPurpose) {
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        commitText()
        let toolbarWasVisible = toolbar?.isVisible ?? false
        toolbar?.orderOut(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if toolbarWasVisible, !self.ending { self.toolbar?.orderFrontRegardless() } }
            do {
                var image = try await ScreenCapture.image(of: self.screen, includeOwnWindows: true)
                if let crop {
                    let s = CGFloat(image.width) / self.size.width
                    if let c = image.cropping(to: CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s,
                                                         height: crop.height * s).integral) { image = c }
                }
                self.deliver(image, purpose: purpose)
            } catch {
                self.log.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deliver(_ image: CGImage, purpose: CropPurpose) {
        let rep = NSBitmapImageRep(cgImage: image)
        switch purpose {
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            flash()
        case .save:
            save(rep)
        }
    }

    /// A quick white flash confirming a copy.
    private func flash() {
        let flash = CALayer()
        flash.frame = CGRect(origin: .zero, size: size)
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        boardLayer.superlayer?.addSublayer(flash)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        flash.opacity = 0
        flash.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { flash.removeFromSuperlayer() }
    }

    private func save(_ rep: NSBitmapImageRep) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        savePanel.nameFieldStringValue = String(localized: "ZoomIt \(Self.stamp())",
                                                comment: "Default file name of a saved screenshot; %@ is the date and time") + ".png"
        savePanel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.orderOut(nil)
        toolbar?.orderOut(nil)
        NSApp.activate()
        savePanel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = savePanel.url {
                    let jpeg = url.pathExtension.lowercased().hasPrefix("jp")
                    let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:])
                    do { try data?.write(to: url) } catch {
                        self.log.error("Saving screenshot failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                guard !self.ending else { return }
                self.panel.present()
                self.panel.makeFirstResponder(self.annotationView)
                if self.state.drawing, self.settings.showToolbar { self.toolbar?.orderFrontRegardless() }
            }
        }
    }

    /// "2026-10-25 at 14.03.12" for file names (no colons, which Finder shows as slashes).
    static func stamp() -> String {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: now)
        f.dateFormat = "HH.mm.ss"
        let time = f.string(from: now)
        return String(localized: "\(date) at \(time)",
                      comment: "Date and time in a default file name, e.g. 2026-10-25 at 14.03.12; the first %@ is the date, the second the time")
    }

    // MARK: Toolbar and cursor

    private func showToolbar() {
        if toolbar == nil {
            var actions = DrawToolbarActions()
            actions.undo = { [weak self] in self?.undo() }
            actions.clear = { [weak self] in self?.clearAll() }
            actions.toggleBoard = { [weak self] in self?.toggleBoard($0) }
            actions.record = { [weak self] in self?.onRecord?() }
            actions.close = { [weak self] in self?.end() }
            let host = FirstClickHostingView(rootView: DrawToolbar(state: state, actions: actions))
            let fit = host.fittingSize
            let vf = screen.visibleFrame
            let frame = CGRect(x: (vf.midX - fit.width / 2).rounded(), y: vf.maxY - fit.height - 12,
                               width: fit.width, height: fit.height)
            let p = OverlayPanel(frame: frame, interactive: true, acceptsKey: false,
                                 level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
            host.frame = CGRect(origin: .zero, size: fit)
            p.contentView = host
            toolbar = p
            observeToolbarState()
        }
        toolbar?.orderFrontRegardless()
    }

    private func hideToolbar() {
        toolbar?.orderOut(nil)
    }

    /// Keeps the cursor in step with toolbar clicks.
    private func observeToolbarState() {
        withObservationTracking {
            _ = state.tool
            _ = state.color
            _ = state.width
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ending else { return }
                    self.updateCursor()
                    self.observeToolbarState()
                }
            }
        }
    }

    private func updateCursor() {
        let c: NSCursor
        if crop != nil {
            c = .crosshair
        } else if !state.drawing {
            c = .arrow
        } else if typing != nil || state.tool == .text {
            c = .iBeam
        } else {
            switch state.tool {
            case .pen, .highlighter, .blur, .eraser:
                let highlighter = state.tool == .highlighter
                let d = state.tool == .eraser ? 16 : Annotation.strokeWidth(pen: state.width, highlighter: highlighter)
                c = PenCursor.make(color: state.tool == .eraser ? .white : state.color.rgba, diameter: d, highlighter: highlighter)
            default:
                c = .crosshair
            }
        }
        annotationView.cursor = c
        if panel.isKeyWindow { c.set() }
    }
}
