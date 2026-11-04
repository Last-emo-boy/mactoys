import AppKit
import MacToysCore
import QuartzCore
import SwiftUI

/// Window levels of the blur modes.
enum BlurLevels {
    /// Focus Blur, Private Apps and App Lock covers: above other apps' normal and floating windows,
    /// below the menu bar, Dock, menus and popovers, so the active app's menus stay sharp.
    static let window = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    /// Blur Screen: above everything an app shows, including the menu bar and Dock.
    static let screen = NSWindow.Level.screenSaver
    /// The App Lock island: above the covers and the menu bar.
    static let appLockIsland = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

/// SwiftUI content that never takes clicks: they go to the panel underneath it.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Content view that catches clicks and keys for interactive blur panels.
final class BlurRootView: NSView {
    var onMouseDown: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { onKeyDown != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?() }
    override func otherMouseDown(with event: NSEvent) { onMouseDown?() }
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}

/// Dims or brightens the blur, following the appearance it is shown in.
final class WashView: NSView {
    var opacity: Double = 0 { didSet { needsDisplay = true } }
    /// nil follows the effective appearance.
    var dark: Bool? { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        let isDark = dark ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        layer?.backgroundColor = (isDark ? NSColor.black : NSColor.white)
            .withAlphaComponent(opacity * (isDark ? 1 : 0.75)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A borderless panel whose content is the window server's behind-window blur — nothing on screen
/// is captured or read; macOS frosts what lies behind the window, as it does for the menu bar.
final class BlurPanel: NSPanel {
    let root: BlurRootView
    let effect = NSVisualEffectView()
    private let wash = WashView()
    private let maskLayer = CAShapeLayer()
    private let canKey: Bool

    init(frame: CGRect, level: NSWindow.Level, interactive: Bool, acceptsKey: Bool = false) {
        root = BlurRootView(frame: CGRect(origin: .zero, size: frame.size))
        canKey = acceptsKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        root.wantsLayer = true
        effect.frame = root.bounds
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .fullScreenUI
        effect.state = .active
        root.addSubview(effect)
        wash.wantsLayer = true
        wash.frame = root.bounds
        wash.autoresizingMask = [.width, .height]
        root.addSubview(wash)
        contentView = root
    }

    override var canBecomeKey: Bool { canKey }
    override var canBecomeMain: Bool { false }

    /// Wash strength; `dark` forces dark frost (lock, app lock), nil follows the system appearance.
    func configure(washOpacity: Double, dark: Bool?) {
        effect.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        wash.dark = dark
        wash.opacity = washOpacity
    }

    /// Limits the blur to `path` (view coordinates, bottom-left origin); nil shows it everywhere.
    func setMask(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let path {
            maskLayer.frame = root.bounds
            maskLayer.path = path
            root.layer?.mask = maskLayer
        } else {
            root.layer?.mask = nil
        }
        CATransaction.commit()
    }

    /// Puts a SwiftUI view above the blur (badges, text); nil removes it.
    func setOverlay<V: View>(_ view: V?) {
        root.subviews.filter { $0 !== effect && $0 !== wash }.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        let host = PassthroughHostingView(rootView: view)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
    }
}

/// Several blur panels stacked over the same area: each one blurs the result of those below it,
/// which is how strength goes past a single material without private filters.
@MainActor
final class BlurStack {
    private(set) var panels: [BlurPanel] = []
    private let level: NSWindow.Level
    private let interactive: Bool
    private let acceptsKey: Bool
    private(set) var frame: CGRect
    private var recipe = BlurRecipe.make(strength: 0.5)
    private var dark: Bool?
    private var mask: CGPath?
    private(set) var isShown = false

    /// Mouse and key handlers of the top panel (interactive stacks only).
    var onMouseDown: (() -> Void)? { didSet { panels.last?.root.onMouseDown = onMouseDown } }
    var onKeyDown: ((NSEvent) -> Bool)? { didSet { panels.last?.root.onKeyDown = onKeyDown } }

    init(frame: CGRect, level: NSWindow.Level, interactive: Bool = false, acceptsKey: Bool = false) {
        self.frame = frame
        self.level = level
        self.interactive = interactive
        self.acceptsKey = acceptsKey
    }

    var top: BlurPanel? { panels.last }

    func configure(_ recipe: BlurRecipe, dark: Bool?) {
        self.recipe = recipe
        self.dark = dark
        rebuild()
    }

    func setFrame(_ frame: CGRect) {
        guard frame != self.frame else { return }
        self.frame = frame
        for p in panels { p.setFrame(frame, display: false) }
    }

    func setMask(_ path: CGPath?) {
        mask = path
        for p in panels { p.setMask(path) }
    }

    func show() {
        isShown = true
        for p in panels { p.orderFrontRegardless() }
    }

    func hide() {
        isShown = false
        for p in panels { p.orderOut(nil) }
    }

    func close() {
        hide()
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    private func rebuild() {
        if panels.count == recipe.layers {
            for (i, p) in panels.enumerated() {
                p.configure(washOpacity: i == panels.count - 1 ? recipe.wash : 0, dark: dark)
            }
            return
        }
        let wasShown = isShown
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels = (0..<recipe.layers).map { i in
            let isTop = i == recipe.layers - 1
            let p = BlurPanel(frame: frame, level: level, interactive: interactive && isTop, acceptsKey: acceptsKey && isTop)
            p.configure(washOpacity: isTop ? recipe.wash : 0, dark: dark)
            p.setMask(mask)
            if isTop {
                p.root.onMouseDown = onMouseDown
                p.root.onKeyDown = onKeyDown
            }
            return p
        }
        if wasShown { show() }
    }
}

/// One `BlurStack` per display, following display changes.
@MainActor
final class DisplayBlurSet {
    private(set) var stacks: [CGDirectDisplayID: BlurStack] = [:]
    private let level: NSWindow.Level
    private let interactive: Bool
    private let acceptsKey: Bool
    private var recipe = BlurRecipe.make(strength: 0.5)
    private var dark: Bool?
    var onMouseDown: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    init(level: NSWindow.Level, interactive: Bool = false, acceptsKey: Bool = false) {
        self.level = level
        self.interactive = interactive
        self.acceptsKey = acceptsKey
    }

    func configure(_ recipe: BlurRecipe, dark: Bool?) {
        self.recipe = recipe
        self.dark = dark
        for s in stacks.values { s.configure(recipe, dark: dark) }
    }

    /// Creates, moves or drops stacks so every display has one.
    func syncScreens() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = screen.displayID
            seen.insert(id)
            if let s = stacks[id] {
                s.setFrame(screen.frame)
            } else {
                let s = BlurStack(frame: screen.frame, level: level, interactive: interactive, acceptsKey: acceptsKey)
                s.onMouseDown = onMouseDown
                s.onKeyDown = onKeyDown
                s.configure(recipe, dark: dark)
                stacks[id] = s
            }
        }
        for (id, s) in stacks where !seen.contains(id) {
            s.close()
            stacks[id] = nil
        }
    }

    func show() { for s in stacks.values { s.show() } }
    func hide() { for s in stacks.values { s.hide() } }

    func close() {
        for s in stacks.values { s.close() }
        stacks.removeAll()
    }

    /// Masks every display with one global path in top-left (AX) coordinates; nil = no blur at all.
    func setGlobalMask(_ path: CGPath?) {
        let primary = ScreenGeometry.primaryHeight
        for screen in NSScreen.screens {
            guard let stack = stacks[screen.displayID] else { continue }
            guard let path else {
                stack.hide()
                continue
            }
            let f = screen.frame
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -f.minX, ty: primary - f.minY)
            let local = path.copy(using: &t)
            let bounds = CGRect(origin: .zero, size: f.size)
            if let local, local.boundingBoxOfPath.intersects(bounds) {
                stack.setMask(local)
                if !stack.isShown { stack.show() }
            } else {
                stack.hide()
            }
        }
    }

    /// The stack of the display under the pointer.
    var stackUnderMouse: BlurStack? {
        (NSScreen.underMouse).flatMap { stacks[$0.displayID] } ?? stacks.values.first
    }
}

enum MaskPaths {
    /// Approximate corner radius of macOS 26 windows.
    static let windowRadius: CGFloat = 12

    /// Everything in `bounds` except the rounded `holes`.
    static func excluding(_ holes: [CGRect], from bounds: CGRect, radius: CGFloat = windowRadius) -> CGPath {
        let base = CGPath(rect: bounds, transform: nil)
        guard !holes.isEmpty else { return base }
        let cut = CGMutablePath()
        for h in holes where h.width > 1 && h.height > 1 {
            let r = min(radius, h.width / 2, h.height / 2)
            cut.addRoundedRect(in: h, cornerWidth: r, cornerHeight: r)
        }
        return base.subtracting(cut, using: .winding)
    }

    /// The union of `parts`, clipped to `window`'s rounded shape.
    static func visible(parts: [CGRect], of window: CGRect, radius: CGFloat = windowRadius) -> CGPath {
        let union = CGMutablePath()
        for p in parts { union.addRect(p) }
        let r = min(radius, window.width / 2, window.height / 2)
        let shape = CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)
        return shape.intersection(union, using: .winding)
    }
}
