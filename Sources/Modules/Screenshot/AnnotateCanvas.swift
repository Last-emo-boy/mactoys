import AppKit
import MacToysCore
import Observation
import SwiftUI

/// The annotate canvas: draws the capture, its annotations and the background frame, and turns
/// clicks and drags into annotations. Coordinates go through `CanvasGeometry`.
final class MarkupCanvasView: NSView, NSTextViewDelegate {
    let model: AnnotateModel

    private enum Drag {
        case none
        case create(MarkupItem.ID, start: CGPoint)
        case freehand(MarkupItem.ID)
        case move(MarkupItem.ID, last: CGPoint)
        case handle(MarkupItem.ID, MarkupItem.Handle)
        case cropNew(start: CGPoint)
        case cropHandle(AreaGeometry.Handle)
        case cropMove(start: CGPoint, rect: CGRect)
    }

    private var drag = Drag.none
    private var textView: NSTextView?
    private var lastTool: MarkupTool

    init(model: AnnotateModel) {
        self.model = model
        lastTool = model.tool
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geometry: CanvasGeometry {
        CanvasGeometry(viewSize: bounds.size, document: model.document, showsWholeImage: model.tool == .crop)
    }

    /// Redraws whenever anything the canvas shows changes.
    private func observe() {
        withObservationTracking {
            _ = model.document
            _ = model.tool
            _ = model.selection
            _ = model.cropDraft
            _ = model.editingText
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.model.tool != self.lastTool {
                    self.lastTool = self.model.tool
                    self.commitText()
                    self.window?.invalidateCursorRects(for: self)
                }
                self.needsDisplay = true
                self.observe()
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionTextView()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = geometry
        let doc = model.document
        let backing = window?.backingScaleFactor ?? 2
        let device = g.zoom * backing
        let hidden: Set<MarkupItem.ID> = model.editingText.map { [$0] } ?? []
        let visible = g.visibleImageRect

        ctx.saveGState()
        ctx.translateBy(x: g.canvasRect.minX, y: g.canvasRect.minY)
        ctx.scaleBy(x: g.zoom, y: g.zoom)
        ctx.interpolationQuality = g.zoom < 1 ? .high : .medium
        let paintContent: (CGContext) -> Void = { ctx in
            ctx.clip(to: visible)
            RenderContext.drawUpright(self.model.item.image, in: doc.imageBounds, ctx: ctx)
            MarkupRenderer.draw(doc.items, in: ctx, canvas: doc.imageBounds, redactions: self.model.item.redactions,
                                deviceScale: device, hiding: hidden)
        }
        if let layout = g.layout, let style = doc.beautify {
            Beautifier.drawFrame(layout: layout, style: style, in: ctx, deviceScale: device) { ctx in
                ctx.translateBy(x: layout.content.minX - visible.minX, y: layout.content.minY - visible.minY)
                paintContent(ctx)
            }
        } else {
            // The capture floats over the backdrop on a soft shadow.
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * backing), blur: 18 * backing,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.translateBy(x: -visible.minX, y: -visible.minY)
            paintContent(ctx)
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()

        if model.tool == .crop {
            drawCropUI(ctx, g)
        } else if let item = model.selectedItem, model.editingText != item.id {
            drawSelection(item, ctx, g)
        }
    }

    private func drawSelection(_ item: MarkupItem, _ ctx: CGContext, _ g: CanvasGeometry) {
        let accent = NSColor.controlAccentColor
        if item.handles.isEmpty || item.box != nil {
            let r = g.view(item.box ?? item.bounds).insetBy(dx: -3, dy: -3)
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            ctx.restoreGState()
        }
        for h in item.handles {
            guard let p = item.point(of: h).map(g.view) else { continue }
            let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            if h == .bend {
                let diamond = CGMutablePath()
                diamond.move(to: CGPoint(x: p.x, y: p.y - 6))
                diamond.addLine(to: CGPoint(x: p.x + 6, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y + 6))
                diamond.addLine(to: CGPoint(x: p.x - 6, y: p.y))
                diamond.closeSubpath()
                ctx.addPath(diamond)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(diamond)
                ctx.strokePath()
            } else {
                ctx.fillEllipse(in: r)
                ctx.restoreGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
            }
        }
    }

    private func drawCropUI(_ ctx: CGContext, _ g: CanvasGeometry) {
        let image = g.contentRect
        let draft = g.view(model.cropDraft ?? model.document.imageBounds)
        ctx.saveGState()
        ctx.addRect(image)
        ctx.addRect(draft)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        // Rule of thirds.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = draft.minX + draft.width * CGFloat(i) / 3, y = draft.minY + draft.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: draft.minY)); ctx.addLine(to: CGPoint(x: x, y: draft.maxY))
            ctx.move(to: CGPoint(x: draft.minX, y: y)); ctx.addLine(to: CGPoint(x: draft.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(draft)
        // Corner brackets.
        ctx.setLineWidth(4)
        let l: CGFloat = min(18, draft.width / 3, draft.height / 3)
        for (c, sx, sy) in [(CGPoint(x: draft.minX, y: draft.minY), 1.0, 1.0), (CGPoint(x: draft.maxX, y: draft.minY), -1.0, 1.0),
                            (CGPoint(x: draft.minX, y: draft.maxY), 1.0, -1.0), (CGPoint(x: draft.maxX, y: draft.maxY), -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: c.x + l * sx, y: c.y))
            ctx.addLine(to: c)
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + l * sy))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Size in pixels under the crop.
        if let crop = model.cropDraft {
            let px = AreaGeometry.pixelSize(crop, scale: model.document.scale)
            let label = NSAttributedString(string: "\(px.width) × \(px.height)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let size = label.size()
            let pill = CGRect(x: draft.midX - size.width / 2 - 8, y: min(draft.maxY + 8, bounds.maxY - size.height - 12),
                              width: size.width + 16, height: size.height + 6)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.fillPath()
            label.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3))
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(geometry.contentRect.intersection(bounds), cursor: cursor)
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint { geometry.image(convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        if textView != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let g = geometry
        let p = imagePoint(event)
        let tolerance = 6 / g.zoom
        let doc = model.document
        switch model.tool {
        case .crop:
            let draft = model.cropDraft ?? doc.imageBounds
            if let h = AreaGeometry.handle(at: p, of: draft, radius: 10 / g.zoom) {
                drag = .cropHandle(h)
            } else if draft.contains(p) {
                drag = .cropMove(start: p, rect: draft)
            } else {
                drag = .cropNew(start: AreaGeometry.clamp(p, to: doc.imageBounds))
            }
        case .select:
            if let item = model.selectedItem, let h = item.handle(at: p, radius: 8 / g.zoom) {
                model.beginGesture()
                drag = .handle(item.id, h)
            } else if let hit = doc.item(at: p, tolerance: tolerance) {
                model.selection = hit.id
                model.adoptStyle(of: hit)
                if event.clickCount >= 2, case .text = hit.shape {
                    editText(hit)
                } else {
                    model.beginGesture()
                    drag = .move(hit.id, last: p)
                }
            } else {
                model.selection = nil
            }
        case .text:
            if let hit = doc.item(at: p, tolerance: tolerance), case .text = hit.shape {
                model.selection = hit.id
                model.adoptStyle(of: hit)
                editText(hit)
            } else {
                createText(at: p)
            }
        default:
            if let item = model.selectedItem, let h = item.handle(at: p, radius: 8 / g.zoom) {
                model.beginGesture()
                drag = .handle(item.id, h)
            } else if let item = model.selectedItem, item.hit(p, tolerance: tolerance) {
                model.beginGesture()
                drag = .move(item.id, last: p)
            } else {
                create(at: p)
            }
        }
    }

    private func create(at p: CGPoint) {
        guard let shape = newShape(at: p) else { return }
        model.beginGesture()
        let item = MarkupItem(shape: shape, color: model.color, size: model.size)
        model.document.items.append(item)
        model.selection = item.id
        switch model.tool {
        case .pencil, .highlighter: drag = .freehand(item.id)
        case .counter: drag = .move(item.id, last: p)
        default: drag = .create(item.id, start: p)
        }
    }

    private func newShape(at p: CGPoint) -> MarkupItem.Shape? {
        let zero = CGRect(origin: p, size: .zero)
        return switch model.tool {
        case .arrow: .arrow(from: p, to: p, bend: 0)
        case .line: .line(from: p, to: p)
        case .rectangle: .rectangle(zero, filled: model.filledShapes)
        case .ellipse: .ellipse(zero, filled: model.filledShapes)
        case .highlighter: .highlighter([p])
        case .pencil: .pencil([p])
        case .counter: .counter(center: p, number: model.document.nextCounter)
        case .blur: .blur(zero)
        case .pixelate: .pixelate(zero)
        case .spotlight: .spotlight(zero, oval: model.ovalSpotlight)
        case .select, .text, .crop: nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let bounds = model.document.imageBounds
        let anywhere = bounds.insetBy(dx: -100_000, dy: -100_000)
        switch drag {
        case .none: break
        case .create(let id, let start):
            model.update(id) { item in
                switch item.shape {
                case .arrow:
                    let end = shift ? Self.snapped(p, from: start) : p
                    item.shape = .arrow(from: start, to: end, bend: model.curvedArrows ? MarkupGeometry.defaultBend(from: start, to: end) : 0)
                case .line:
                    item.shape = .line(from: start, to: shift ? Self.snapped(p, from: start) : p)
                case .rectangle, .ellipse:
                    item = item.withBox(AreaGeometry.rect(anchor: start, current: p, square: shift, fromCenter: option, in: anywhere))
                case .blur, .pixelate, .spotlight:
                    item = item.withBox(AreaGeometry.rect(anchor: start, current: p, square: shift, fromCenter: option, in: bounds))
                default: break
                }
            }
        case .freehand(let id):
            model.update(id) { item in
                switch item.shape {
                case .pencil(var pts):
                    pts.append(p)
                    item.shape = .pencil(pts)
                case .highlighter(var pts):
                    if shift, let first = pts.first {
                        pts = [first, CGPoint(x: p.x, y: abs(p.y - first.y) < 12 ? first.y : p.y)]
                    } else {
                        pts.append(p)
                    }
                    item.shape = .highlighter(pts)
                default: break
                }
            }
        case .move(let id, let last):
            model.update(id) { $0 = $0.moved(by: CGVector(dx: p.x - last.x, dy: p.y - last.y)) }
            drag = .move(id, last: p)
        case .handle(let id, let h):
            model.update(id) { item in
                var target = p
                if shift, h == .start || h == .end, let other = item.point(of: h == .start ? .end : .start) {
                    target = Self.snapped(p, from: other)
                }
                item = item.dragging(h, to: target, in: bounds)
            }
        case .cropNew(let start):
            model.cropDraft = AreaGeometry.rect(anchor: start, current: p, square: shift, fromCenter: option, in: bounds)
        case .cropHandle(let h):
            model.cropDraft = AreaGeometry.resized(model.cropDraft ?? bounds, handle: h, to: p, in: bounds)
        case .cropMove(let start, let rect):
            model.cropDraft = AreaGeometry.moved(rect, by: CGVector(dx: p.x - start.x, dy: p.y - start.y), in: bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .create(let id, _), .freehand(let id):
            if let item = model.document.items.first(where: { $0.id == id }), item.isDegenerate {
                model.cancelGesture()
                model.selection = nil
            } else {
                model.update(id) { item in
                    if case .pencil(let pts) = item.shape { item.shape = .pencil(MarkupGeometry.thinned(pts, spacing: 1.5)) }
                    if case .highlighter(let pts) = item.shape { item.shape = .highlighter(MarkupGeometry.thinned(pts, spacing: 1.5)) }
                }
                model.endGesture()
            }
        case .move, .handle:
            model.endGesture()
        case .cropNew:
            if let d = model.cropDraft, !AreaGeometry.isUsable(d) { model.cropDraft = model.document.crop ?? model.document.imageBounds }
        default: break
        }
        drag = .none
    }

    /// Snaps a drag to the nearest 45° direction.
    static func snapped(_ p: CGPoint, from a: CGPoint) -> CGPoint {
        let dx = p.x - a.x, dy = p.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 51, 117: model.deleteSelection()                                   // delete, forward delete
        case 53:                                                                 // esc
            if model.tool == .crop {
                model.cropDraft = model.document.crop ?? model.document.imageBounds
                model.applyCrop()
            } else {
                model.selection = nil
            }
        case 36, 76: if model.tool == .crop { model.applyCrop() }               // return, enter
        case 123: model.nudgeSelection(dx: -step, dy: 0)
        case 124: model.nudgeSelection(dx: step, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: step)
        case 126: model.nudgeSelection(dx: 0, dy: -step)
        default:
            if mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased().first, let tool = MarkupTool.forKey(c) {
                model.selectTool(tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text

    private func createText(at p: CGPoint) {
        model.beginGesture()
        let item = MarkupItem(shape: .text(MarkupText(origin: p, string: "", style: model.textStyle)), color: model.color, size: model.size)
        model.document.items.append(item)
        model.selection = item.id
        startEditing(item)
    }

    private func editText(_ item: MarkupItem) {
        model.beginGesture()
        startEditing(item)
    }

    private func startEditing(_ item: MarkupItem) {
        guard case .text(let t) = item.shape else { return }
        model.editingText = item.id
        let zoom = geometry.zoom
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = MarkupText.font(size: item.size.fontSize * zoom)
        let solid = t.style == .solid
        tv.textColor = solid ? (item.color.isLight ? .black : .white) : item.color.nsColor
        tv.insertionPointColor = tv.textColor ?? .white
        tv.drawsBackground = solid || t.style == .soft
        tv.backgroundColor = solid ? item.color.nsColor : .white
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.string = t.string
        tv.delegate = self
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.layer?.borderWidth = 1
        addSubview(tv)
        textView = tv
        positionTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
    }

    private func positionTextView() {
        guard let tv = textView, let id = model.editingText, let item = model.document.items.first(where: { $0.id == id }),
              case .text(let t) = item.shape else { return }
        let g = geometry
        tv.font = MarkupText.font(size: item.size.fontSize * g.zoom)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!) ?? .zero
        let lineHeight = (tv.font.map { $0.ascender - $0.descender + $0.leading } ?? 20)
        let origin = g.view(t.origin)
        tv.frame = CGRect(x: origin.x, y: origin.y, width: max(used.width + 6, 24), height: max(used.height, lineHeight))
    }

    func textDidChange(_ notification: Notification) { positionTextView() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    /// Ends text editing: keeps the text, or removes the annotation when it's empty.
    func commitText() {
        guard let tv = textView else { return }
        let id = model.editingText
        let string = tv.string
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        model.editingText = nil
        if let id {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.document.items.removeAll { $0.id == id }
                if model.selection == id { model.selection = nil }
            } else {
                model.update(id) { item in
                    if case .text(var t) = item.shape {
                        t.string = string
                        item.shape = .text(t)
                    }
                }
            }
        }
        model.endGesture()
        window?.makeFirstResponder(self)
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { model.actions.copy(model) }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
}

/// SwiftUI wrapper for the canvas.
struct MarkupCanvas: NSViewRepresentable {
    let model: AnnotateModel

    func makeNSView(context: Context) -> MarkupCanvasView {
        let view = MarkupCanvasView(model: model)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: MarkupCanvasView, context: Context) { view.needsDisplay = true }
}

/// The annotate window: a regular titled window with SwiftUI's toolbar bridged into the title bar.
/// Handles ⌘ shortcuts itself unless text is being typed.
@MainActor
final class AnnotateWindow: NSWindow, NSWindowDelegate {
    let model: AnnotateModel
    var onClose: (() -> Void)?

    init(model: AnnotateModel) {
        self.model = model
        let controller = NSHostingController(rootView: AnnotateView(model: model))
        controller.sceneBridgingOptions = [.toolbars]
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = model.item.pointSize
        let width = min(max(image.width + 80 + (model.showsBeautify ? AnnotateView.panelWidth : 0), 860), visible.width * 0.9)
        let height = min(max(image.height + 190, 560), visible.height * 0.9)
        super.init(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        contentViewController = controller
        setContentSize(CGSize(width: width, height: height))
        contentMinSize = CGSize(width: 820, height: 500)
        title = model.item.title
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        delegate = self
        center()
    }

    func show() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    private var isTyping: Bool { firstResponder is NSTextView }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), !isTyping, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, mods) {
        case ("z", [.command]): model.undo()
        case ("z", [.command, .shift]): model.redo()
        case ("c", [.command]): model.actions.copy(model)
        case ("c", [.command, .shift]): model.actions.copyText(model)
        case ("s", [.command]): model.actions.save(model)
        case ("s", [.command, .shift]): model.actions.saveAs(model)
        case ("d", [.command]): model.duplicateSelection()
        case ("b", [.command]): model.toggleBeautify()
        case ("p", [.command, .shift]): model.actions.pin(model)
        case ("w", [.command]): close()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let canvas = firstResponder as? NSTextView, let host = canvas.superview as? MarkupCanvasView { host.commitText() }
        if model.tool == .crop { model.applyCrop() }
        let callback = onClose
        onClose = nil
        callback?()
    }
}
