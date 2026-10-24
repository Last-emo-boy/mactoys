import AppKit
import SwiftUI

/// A borderless, transparent panel that floats over everything on every Space —
/// the base for zone highlights, rulers, spotlights, pickers and HUDs.
open class OverlayPanel: NSPanel {
    /// Whether the panel may take keyboard focus (pickers, editors). Click-through overlays leave this false.
    public var acceptsKey: Bool

    /// - Parameters:
    ///   - frame: Cocoa coordinates.
    ///   - interactive: receives mouse events; otherwise clicks pass through.
    ///   - acceptsKey: can become key window (for Esc/typing).
    public init(frame: CGRect, interactive: Bool = false, acceptsKey: Bool = false, level: NSWindow.Level = .screenSaver) {
        self.acceptsKey = acceptsKey
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
    }

    open override var canBecomeKey: Bool { acceptsKey }
    open override var canBecomeMain: Bool { false }

    /// Hosts a SwiftUI view as the panel content.
    public func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    /// Shows the panel; when it accepts keys, makes it key and activates MacToys.
    public func present() {
        if acceptsKey {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }

    /// One panel per screen, covering it fully.
    public static func perScreen(interactive: Bool = false, acceptsKey: Bool = false,
                                 level: NSWindow.Level = .screenSaver) -> [(NSScreen, OverlayPanel)] {
        NSScreen.screens.map { ($0, OverlayPanel(frame: $0.frame, interactive: interactive, acceptsKey: acceptsKey, level: level)) }
    }
}

/// A floating, key-capable panel for launcher-style UIs (Command Palette, Run, Advanced Paste).
/// It hides when it loses focus unless `hidesOnResign` is false.
open class FloatingPanel: NSPanel, NSWindowDelegate {
    public var hidesOnResign = true
    public var onClose: (() -> Void)?

    public init(size: CGSize, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        delegate = self
    }

    open override var canBecomeKey: Bool { true }

    public func setContent<V: View>(_ view: V) {
        contentView = NSHostingView(rootView: view)
    }

    /// Centers horizontally on the screen under the mouse, at `verticalFraction` from the top.
    public func show(verticalFraction: CGFloat = 0.22) {
        let screen = NSScreen.underMouse ?? NSScreen.main!
        let vf = screen.visibleFrame
        let origin = CGPoint(x: vf.midX - frame.width / 2, y: vf.maxY - vf.height * verticalFraction - frame.height)
        setFrameOrigin(origin)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        orderOut(nil)
        onClose?()
    }

    open override func cancelOperation(_ sender: Any?) { dismiss() }

    public func windowDidResignKey(_ notification: Notification) {
        if hidesOnResign && isVisible { dismiss() }
    }
}
