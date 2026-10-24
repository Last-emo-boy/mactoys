import AppKit
import MacToysCore
import Observation
import SwiftUI

/// The dictation badge's state, shown along the top edge of a snip selection.
@MainActor
@Observable
final class DictationBadgeModel {
    enum Status: Equatable {
        case preparing, listening, transcribing
        case unavailable(String)
    }

    var status: Status?
    var text = ""
}

struct DictationBadge: View {
    let model: DictationBadgeModel

    var body: some View {
        if let status = model.status {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(status))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status == .listening ? Color.red : .white.opacity(0.8))
                    .symbolEffect(.pulse, isActive: status == .listening)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(status)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    if !model.text.isEmpty {
                        Text(model.text).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(_ s: DictationBadgeModel.Status) -> String {
        switch s {
        case .preparing, .listening: "mic.fill"
        case .transcribing: "waveform"
        case .unavailable: "mic.slash"
        }
    }

    private func title(_ s: DictationBadgeModel.Status) -> String {
        switch s {
        case .preparing: "Preparing…"
        case .listening: "Listening…"
        case .transcribing: "Transcribing — Esc to cancel"
        case .unavailable(let why): why
        }
    }
}

/// Draws the dimmed exterior, the selection and its size, and reports the drag.
final class RegionSelectionView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true; onChange?(selection) } }
    var onChange: ((CGRect?) -> Void)?
    var onFinish: ((CGRect?, NSEvent.ModifierFlags) -> Void)?
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDragStart: (() -> Void)?
    var aspect: CGFloat?
    /// Ignore input (while transcribing).
    var locked = false
    private var start: CGPoint?
    private var scale: CGFloat = 2

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(scale: CGFloat) { self.scale = scale }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.addRect(bounds)
        if let r = selection { ctx.addRect(r) }
        ctx.fillPath(using: .evenOdd)
        guard let r = selection else { return }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        let label = "\(Int((r.width * scale).rounded())) × \(Int((r.height * scale).rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        var origin = CGPoint(x: r.maxX - size.width - 8, y: r.maxY + 6)
        if origin.y + size.height + 6 > bounds.maxY { origin.y = r.maxY - size.height - 10 }
        let pill = CGRect(x: origin.x - 6, y: origin.y - 2, width: size.width + 12, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        text.draw(at: origin)
    }

    override func mouseDown(with event: NSEvent) {
        guard !locked else { return }
        start = convert(event.locationInWindow, from: nil)
        selection = CGRect(origin: start ?? .zero, size: .zero)
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !locked, let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        let w = p.x - start.x
        var h = p.y - start.y
        if let aspect, abs(w) > 0 { h = (abs(w) / aspect) * (h < 0 ? -1 : 1) }
        selection = CGRect(x: min(start.x, start.x + w), y: min(start.y, start.y + h), width: abs(w), height: abs(h))
            .intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard !locked, start != nil else { return }
        start = nil
        let r = selection.flatMap { $0.width >= 2 && $0.height >= 2 ? $0 : nil }
        onFinish?(r, event.modifierFlags)
    }

    override func rightMouseDown(with event: NSEvent) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onEscape?()
        case 49: if start != nil || selection != nil { onSpace?() }
        default: super.keyDown(with: event)
        }
    }
}

/// Drag out a rectangle on the screen under the pointer, over a frozen image or the live screen.
@MainActor
final class RegionSelector {
    let screen: NSScreen
    let badge = DictationBadgeModel()
    private let panel: OverlayPanel
    private let selectionView: RegionSelectionView
    private let badgeHost: NSHostingView<DictationBadge>
    private var previousApp = NSWorkspace.shared.frontmostApplication

    var onSpace: (() -> Void)? {
        get { selectionView.onSpace }
        set { selectionView.onSpace = newValue }
    }
    var onEscape: (() -> Void)? {
        get { selectionView.onEscape }
        set { selectionView.onEscape = newValue }
    }
    var onDragStart: (() -> Void)? {
        get { selectionView.onDragStart }
        set { selectionView.onDragStart = newValue }
    }
    /// Called with the selection (points, top-left origin) or nil when cancelled, and the modifiers at release.
    var onFinish: ((CGRect?, NSEvent.ModifierFlags) -> Void)? {
        get { selectionView.onFinish }
        set { selectionView.onFinish = newValue }
    }
    var locked: Bool {
        get { selectionView.locked }
        set { selectionView.locked = newValue }
    }
    var windowNumber: Int { panel.windowNumber }

    init(screen: NSScreen, frozen: CGImage?, aspect: CGFloat? = nil) {
        self.screen = screen
        panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
        let root = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        if let frozen {
            root.layer?.contents = frozen
            root.layer?.contentsGravity = .resize
        }
        selectionView = RegionSelectionView(frame: root.bounds)
        selectionView.autoresizingMask = [.width, .height]
        selectionView.aspect = aspect
        selectionView.configure(scale: frozen.map { CGFloat($0.width) / screen.frame.width } ?? screen.backingScaleFactor)
        root.addSubview(selectionView)
        badgeHost = NSHostingView(rootView: DictationBadge(model: badge))
        badgeHost.isHidden = true
        root.addSubview(badgeHost)
        panel.contentView = root
        selectionView.onChange = { [weak self] r in self?.placeBadge(near: r) }
    }

    func show() {
        panel.present()
        panel.makeFirstResponder(selectionView)
    }

    func close(restoreFocus: Bool = true) {
        panel.orderOut(nil)
        panel.contentView = nil
        if restoreFocus, let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    func showBadge() {
        badgeHost.isHidden = false
        placeBadge(near: selectionView.selection)
    }

    /// Centers the badge on the selection's top edge (above it when there's room).
    private func placeBadge(near r: CGRect?) {
        guard !badgeHost.isHidden else { return }
        let fit = badgeHost.fittingSize
        let anchor = r ?? CGRect(origin: CGPoint(x: screen.frame.width / 2, y: 80), size: .zero)
        let flippedTop = anchor.minY
        var y = flippedTop - fit.height - 8
        if y < 8 { y = flippedTop + 8 }
        let x = min(max(anchor.midX - fit.width / 2, 8), screen.frame.width - fit.width - 8)
        // The root view isn't flipped: convert from top-left.
        badgeHost.frame = CGRect(x: x, y: screen.frame.height - y - fit.height, width: fit.width, height: fit.height)
    }

    func refreshBadge() { placeBadge(near: selectionView.selection) }
}
