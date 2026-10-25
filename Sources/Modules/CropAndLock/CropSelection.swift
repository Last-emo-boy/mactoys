import AppKit
import MacToysCore

/// The drag-to-select overlay drawn over the window being cropped. Esc, a right click or
/// switching away cancels; releasing the mouse over a large enough area completes.
@MainActor
final class CropSelection {
    private let panel: OverlayPanel
    private let view: CropSelectionView
    private var resignObserver: NSObjectProtocol?
    private var finished = false
    private let onDone: (CGRect?) -> Void

    /// - Parameters:
    ///   - windowFrame: the target window, global top-left coordinates.
    ///   - onDone: the selected rect in window-local points (top-left origin), or nil when cancelled.
    init(windowFrame: CGRect, mode: CropMode, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        let cocoa = ScreenGeometry.toCocoa(windowFrame)
        panel = OverlayPanel(frame: cocoa, interactive: true, acceptsKey: true, level: .screenSaver)
        view = CropSelectionView(frame: CGRect(origin: .zero, size: cocoa.size), mode: mode)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.onComplete = { [weak self] rect in self?.finish(rect) }
        view.onCancel = { [weak self] in self?.finish(nil) }
    }

    func present() {
        panel.present()
        panel.makeFirstResponder(view)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
        panel.close()
        onDone(rect)
    }
}

/// Dims the window, cuts out the dragged area and labels it with its size.
/// Flipped, so view coordinates equal window-local top-left points.
final class CropSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    /// Current selection (view coordinates); empty before the first drag.
    var selection: CGRect = .zero { didSet { needsDisplay = true } }

    private let mode: CropMode
    private var anchor: CGPoint?

    init(frame: NSRect, mode: CropMode) {
        self.mode = mode
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hasSelection = selection.width > 0 && selection.height > 0
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        if hasSelection {
            shape.append(NSBezierPath(rect: selection))
            shape.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.42).setFill()
        shape.fill()

        let tint = Tint.teal.nsColor
        if hasSelection {
            // Not fully clear: transparent pixels would let clicks fall through to the app below.
            NSColor.white.withAlphaComponent(0.03).setFill()
            selection.fill()
            let ring = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            ring.lineWidth = 2
            tint.setStroke()
            ring.stroke()
            drawHandles(tint)
            drawSizeLabel()
        } else {
            drawHint()
        }
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        edge.lineWidth = 1
        edge.stroke()
    }

    private func drawHandles(_ tint: NSColor) {
        let s: CGFloat = 7
        let corners = [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                       CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
        for c in corners {
            let r = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            tint.setStroke()
            let o = NSBezierPath(ovalIn: r)
            o.lineWidth = 1.5
            o.stroke()
        }
    }

    private func drawSizeLabel() {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let below = selection.maxY + 30 < bounds.maxY
        let center = CGPoint(x: selection.midX, y: below ? selection.maxY + 16 : selection.minY - 16)
        drawPill(text, at: center, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
    }

    private func drawHint() {
        let center = CGPoint(x: bounds.midX, y: min(bounds.midY, 60))
        drawPill(String(localized: "\(mode.title) · drag over the area to keep · esc cancels",
                        comment: "Crop selection hint; %@ is the crop mode (Thumbnail, Interactive or Screenshot), esc is the key"),
                 at: center,
                 font: .systemFont(ofSize: 13, weight: .semibold))
    }

    private func drawPill(_ text: String, at center: CGPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pill = CGRect(x: center.x - size.width / 2 - 12, y: center.y - size.height / 2 - 6,
                          width: size.width + 24, height: size.height + 12)
        NSColor(white: 0.1, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        str.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 6))
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selection = CropGeometry.selection(from: anchor, to: convert(event.locationInWindow, from: nil), in: bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        anchor = nil
        if CropGeometry.isUsable(selection) {
            onComplete?(selection)
        } else {
            selection = .zero
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                                         // esc
        case 36, 76: if CropGeometry.isUsable(selection) { onComplete?(selection) }  // return, enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
