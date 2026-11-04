import AppKit
import MacToysCore
import QuartzCore

/// Click-through borders or a glow around tiled windows, and the pips that mark a stack, drawn
/// in the gaps so they never cover window content. One panel per display; the layers are reused
/// so the active border slides from window to window.
@MainActor
final class HighlightOverlay {
    struct Item: Equatable {
        var display: CGDirectDisplayID
        /// Window frame, top-left coordinates.
        var frame: CGRect
        var radius: CGFloat
        var active: Bool
        var stackCount: Int
    }

    private var panels: [CGDirectDisplayID: (panel: OverlayPanel, view: HighlightView)] = [:]
    private var last: (items: [Item], style: HighlightStyle, color: NSColor, gap: CGFloat)?

    /// Just above every app window and the No peek veil.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    func update(_ items: [Item], displays: [TileDisplay], style: HighlightStyle, color: NSColor, gap: CGFloat) {
        last = (items, style, color, gap)
        let ids = Set(displays.map(\.displayID))
        for (id, p) in panels where !ids.contains(id) {
            p.panel.close()
            panels[id] = nil
        }
        for d in displays {
            let mine = items.filter { $0.display == d.displayID }
            let drawn = HighlightView.Content(items: mine.map { item in
                var local = item
                local.frame = CGRect(x: item.frame.minX - d.frame.minX, y: d.frame.maxY - item.frame.maxY,
                                     width: item.frame.width, height: item.frame.height)
                return local
            }, style: style, color: color, gap: gap)
            guard drawn.drawsAnything else {
                panels[d.displayID]?.panel.orderOut(nil)
                continue
            }
            let cocoa = ScreenGeometry.toCocoa(d.frame)
            let entry = panels[d.displayID] ?? makePanel(cocoa)
            panels[d.displayID] = entry
            if entry.panel.frame != cocoa { entry.panel.setFrame(cocoa, display: false) }
            entry.view.render(drawn)
            if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
    }

    /// Stops drawing the border at `frame` (its window is being dragged) until the next update.
    func hide(window frame: CGRect?) {
        guard let frame, let last else { return }
        let rest = last.items.filter { $0.frame != frame }
        let displays = TileDisplay.current()
        update(rest, displays: displays, style: last.style, color: last.color, gap: last.gap)
    }

    func hide() {
        for p in panels.values { p.panel.orderOut(nil) }
    }

    func tearDown() {
        for p in panels.values { p.panel.close() }
        panels.removeAll()
        last = nil
    }

    private func makePanel(_ frame: CGRect) -> (panel: OverlayPanel, view: HighlightView) {
        let panel = OverlayPanel(frame: frame, interactive: false, level: Self.level)
        // Follows the current Space; hidden while Mission Control shows every window.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = HighlightView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return (panel, view)
    }
}

/// Draws the highlight layers of one display (view coordinates: origin bottom-left).
final class HighlightView: NSView {
    struct Content {
        var items: [HighlightOverlay.Item]
        var style: HighlightStyle
        var color: NSColor
        var gap: CGFloat

        var drawsAnything: Bool {
            items.contains { $0.stackCount > 1 } || (style != .none && items.contains { $0.active || style == .allBorders })
        }
    }

    private var borders: [CAShapeLayer] = []
    private var glows: [CAShapeLayer] = []
    private var pips: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    func render(_ c: Content) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if reduceMotion { CATransaction.setDisableActions(true) }

        // Borders sit just outside the window, inside the gap.
        let width = min(max(c.gap * 0.35, 2), 4) + (contrast ? 1 : 0)
        var borderSpecs: [(CGRect, CGFloat, CGFloat, Float)] = []   // frame, radius, width, opacity
        if c.style == .activeBorder || c.style == .allBorders {
            for item in c.items where item.active || c.style == .allBorders {
                let w = item.active ? width : max(1.5, width - 1)
                let alpha: Float = item.active ? 1 : (contrast ? 0.8 : 0.45)
                borderSpecs.append((item.frame, item.radius, w, alpha))
            }
        }
        sync(&borders, count: borderSpecs.count) { CAShapeLayer() }
        for (layer, spec) in zip(borders, borderSpecs) {
            let (frame, radius, w, alpha) = spec
            let outset = w / 2 + 1
            let rect = frame.insetBy(dx: -outset, dy: -outset)
            layer.frame = bounds
            layer.path = CGPath(roundedRect: rect, cornerWidth: radius + outset, cornerHeight: radius + outset, transform: nil)
            layer.fillColor = nil
            layer.strokeColor = c.color.cgColor
            layer.lineWidth = w
            layer.opacity = alpha
        }

        // Two passes per window: a tight bright halo and a wide soft one.
        let glowSpecs: [(item: HighlightOverlay.Item, radius: CGFloat, opacity: Float)] = c.style == .glow
            ? c.items.filter(\.active).flatMap { [($0, 6, 1), ($0, 22, 0.8)] } : []
        sync(&glows, count: glowSpecs.count) { CAShapeLayer() }
        for (layer, spec) in zip(glows, glowSpecs) {
            let item = spec.item
            let path = CGPath(roundedRect: item.frame.insetBy(dx: -1.5, dy: -1.5), cornerWidth: item.radius + 1.5,
                              cornerHeight: item.radius + 1.5, transform: nil)
            layer.frame = bounds
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = c.color.cgColor
            layer.lineWidth = contrast ? 4 : 3
            layer.shadowColor = c.color.cgColor
            layer.shadowOpacity = spec.opacity
            layer.shadowRadius = spec.radius
            layer.shadowOffset = .zero
            // The glow spills outward only, never over the window.
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            let cut = CGMutablePath()
            cut.addRect(bounds)
            cut.addPath(CGPath(roundedRect: item.frame, cornerWidth: item.radius, cornerHeight: item.radius, transform: nil))
            mask.frame = bounds
            mask.path = cut
            mask.fillRule = .evenOdd
            layer.mask = mask
        }

        // Stack pips: one per window in the tile, in the gap above it (the front one is longer).
        var pipSpecs: [(CGRect, Float)] = []
        if StackPipMetrics.isDrawn(gap: c.gap) {
            for item in c.items where item.stackCount > 1 {
                let frames = StackPipMetrics.frames(centerX: item.frame.midX,
                                                    centerY: item.frame.maxY + StackPipMetrics.offset(gap: c.gap),
                                                    count: item.stackCount, front: 0, gap: c.gap)
                pipSpecs += frames.enumerated().map { ($1, $0 == 0 ? 1 : 0.6) }
            }
        }
        sync(&pips, count: pipSpecs.count) { CALayer() }
        for (layer, spec) in zip(pips, pipSpecs) {
            layer.frame = spec.0
            layer.cornerRadius = spec.0.height / 2
            layer.backgroundColor = NSColor.white.cgColor
            layer.opacity = spec.1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 1.5
            layer.shadowOffset = .zero
        }
        CATransaction.commit()
    }

    /// Grows or shrinks a layer pool to `count`.
    private func sync<L: CALayer>(_ pool: inout [L], count: Int, make: () -> L) {
        while pool.count > count { pool.removeLast().removeFromSuperlayer() }
        while pool.count < count {
            let l = make()
            l.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(l)
            pool.append(l)
        }
    }
}

/// The pips that mark a stack, like page dots: centered in the gap above the tile (over its
/// border), the front window's pip longer than the rest.
enum StackPipMetrics {
    static let maxCount = 6

    static func isDrawn(gap: CGFloat) -> Bool { gap >= 4 }

    static func height(gap: CGFloat) -> CGFloat { gap >= 8 ? 6 : gap >= 6 ? 4 : 3 }

    /// Distance from the window's top edge to the pips' center line.
    static func offset(gap: CGFloat) -> CGFloat { max(gap / 2, height(gap: gap) / 2 + 0.5) }

    /// Pip frames around a center point, in stack order (`scale` enlarges them for miniatures).
    static func frames(centerX: CGFloat, centerY: CGFloat, count: Int, front: Int, gap: CGFloat, scale: CGFloat = 1) -> [CGRect] {
        let n = min(count, maxCount)
        guard n > 1 else { return [] }
        let h = height(gap: gap) * scale, long = h * 3, spacing = h * 0.75
        let total = long + CGFloat(n - 1) * (h + spacing)
        var x = centerX - total / 2
        return (0..<n).map { i in
            let w = i == min(front, n - 1) ? long : h
            defer { x += w + spacing }
            return CGRect(x: x, y: centerY - h / 2, width: w, height: h)
        }
    }
}

/// No peek and Clean Space: a dark veil (optionally blurred) or an opaque curtain over a
/// display, with a hole where the window in use is. Click-through, below the highlight.
@MainActor
final class SpotlightOverlay {
    struct Hole: Equatable {
        /// Window frame, top-left coordinates.
        var frame: CGRect
        var radius: CGFloat
    }

    private var panels: [CGDirectDisplayID: (panel: OverlayPanel, view: SpotlightView)] = [:]

    static let level = NSWindow.Level.floating

    func update(displays: [TileDisplay], veil: Hole?, darkness: Double, blur: Bool,
                curtain: (display: TileDisplay, hole: Hole)?) {
        let ids = Set(displays.map(\.displayID))
        for (id, p) in panels where !ids.contains(id) {
            p.panel.close()
            panels[id] = nil
        }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        for d in displays {
            let mode: SpotlightView.Mode
            if let curtain, curtain.display.key == d.key {
                mode = .curtain(hole: local(curtain.hole, in: d))
            } else if let veil {
                // A hole only where the window is on this display.
                let hole = d.frame.intersects(veil.frame) ? local(veil, in: d) : nil
                mode = .veil(hole: hole, darkness: min(max(darkness, 0.2), 0.95) + (reduceTransparency && blur ? 0.1 : 0),
                             blur: blur && !reduceTransparency)
            } else {
                if let p = panels[d.displayID], p.panel.isVisible { fadeOut(p.panel) }
                continue
            }
            let cocoa = ScreenGeometry.toCocoa(d.frame)
            let entry = panels[d.displayID] ?? makePanel(cocoa)
            panels[d.displayID] = entry
            if entry.panel.frame != cocoa { entry.panel.setFrame(cocoa, display: false) }
            entry.view.mode = mode
            if !entry.panel.isVisible || entry.panel.alphaValue < 1 { fadeIn(entry.panel) }
        }
    }

    func hide() {
        for p in panels.values where p.panel.isVisible { fadeOut(p.panel) }
    }

    func tearDown() {
        for p in panels.values { p.panel.close() }
        panels.removeAll()
    }

    private func local(_ hole: Hole, in d: TileDisplay) -> Hole {
        Hole(frame: CGRect(x: hole.frame.minX - d.frame.minX, y: d.frame.maxY - hole.frame.maxY,
                           width: hole.frame.width, height: hole.frame.height), radius: hole.radius)
    }

    private func makePanel(_ frame: CGRect) -> (panel: OverlayPanel, view: SpotlightView) {
        let panel = OverlayPanel(frame: frame, interactive: false, level: Self.level)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.alphaValue = 0
        let view = SpotlightView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return (panel, view)
    }

    private func fadeIn(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { panel.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }
}

/// The veil or curtain of one display (view coordinates: origin bottom-left).
final class SpotlightView: NSView {
    enum Mode: Equatable {
        case none
        case veil(hole: SpotlightOverlay.Hole?, darkness: Double, blur: Bool)
        case curtain(hole: SpotlightOverlay.Hole)
    }

    var mode: Mode = .none {
        didSet { if mode != oldValue { apply() } }
    }

    private let shade = CAShapeLayer()
    private let effect = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isHidden = true
        addSubview(effect)
        shade.fillRule = .evenOdd
        layer?.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        switch mode {
        case .none:
            shade.path = nil
            effect.isHidden = true
        case .veil(let hole, let darkness, let blur):
            shade.path = Self.path(bounds, hole: hole)
            shade.fillColor = NSColor.black.withAlphaComponent(blur ? darkness * 0.75 : darkness).cgColor
            effect.isHidden = !blur
            if blur { effect.maskImage = Self.mask(size: bounds.size, hole: hole) }
        case .curtain(let hole):
            shade.path = Self.path(bounds, hole: hole)
            shade.fillColor = NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1).cgColor
            effect.isHidden = true
        }
        CATransaction.commit()
    }

    private static func path(_ bounds: CGRect, hole: SpotlightOverlay.Hole?) -> CGPath {
        let p = CGMutablePath()
        p.addRect(bounds)
        if let hole {
            p.addPath(CGPath(roundedRect: hole.frame, cornerWidth: hole.radius, cornerHeight: hole.radius, transform: nil))
        }
        return p
    }

    /// Opaque everywhere except the hole (NSVisualEffectView shows where its mask is opaque).
    private static func mask(size: CGSize, hole: SpotlightOverlay.Hole?) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            if let hole {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(roundedRect: hole.frame, xRadius: hole.radius, yRadius: hole.radius).fill()
            }
            return true
        }
    }
}
