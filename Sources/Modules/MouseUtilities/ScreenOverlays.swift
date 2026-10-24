import AppKit
import MacToysCore
import QuartzCore

/// A layer-backed view with a top-left origin, so layers use the same coordinates as CGEvent
/// locations (minus the screen's origin).
final class LayerHostView: NSView {
    let root = CALayer()

    init(frame: CGRect, scale: CGFloat) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.isGeometryFlipped = true
        root.contentsScale = scale
        root.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One click-through overlay panel per display, each hosting a root layer. Rebuilt when the
/// display arrangement changes. Coordinates handed to the client are global top-left (AX/CG).
@MainActor
final class ScreenOverlays {
    struct Surface {
        let screen: NSScreen
        let panel: OverlayPanel
        let root: CALayer
        /// The display's frame in global top-left coordinates.
        let frame: CGRect
        var scale: CGFloat { screen.backingScaleFactor }

        /// A global top-left point in this surface's layer coordinates.
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
    }

    private(set) var surfaces: [Surface] = []
    private let level: NSWindow.Level
    private var screenObserver: NSObjectProtocol?
    /// Called after the surfaces are (re)built, to add the client's layers.
    var onBuild: (([Surface]) -> Void)?

    init(level: NSWindow.Level = .screenSaver) {
        self.level = level
    }

    var isVisible: Bool { !surfaces.isEmpty }

    func show() {
        if surfaces.isEmpty { build() }
        for s in surfaces { s.panel.orderFrontRegardless() }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for s in surfaces { s.panel.orderOut(nil) }
        surfaces = []
    }

    /// The surface showing a global top-left point (nearest display when outside all of them).
    func surface(at p: CGPoint) -> Surface? {
        surfaces.first { $0.frame.contains(p) }
            ?? surfaces.min { $0.frame.distance(to: p) < $1.frame.distance(to: p) }
    }

    private func rebuild() {
        guard !surfaces.isEmpty else { return }
        for s in surfaces { s.panel.orderOut(nil) }
        surfaces = []
        build()
        for s in surfaces { s.panel.orderFrontRegardless() }
    }

    private func build() {
        surfaces = NSScreen.screens.map { screen in
            let panel = OverlayPanel(frame: screen.frame, level: level)
            let view = LayerHostView(frame: CGRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
            panel.contentView = view
            return Surface(screen: screen, panel: panel, root: view.root, frame: screen.axFrame)
        }
        onBuild?(surfaces)
    }
}

/// Applies layer changes without implicit animations.
@MainActor
func withoutAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

extension RGBA {
    /// The color with its alpha multiplied.
    func cgColor(alpha factor: Double) -> CGColor { withAlpha(alpha * factor).cgColor }
}
