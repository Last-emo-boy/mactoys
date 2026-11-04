import AppKit
import MacToysCore
import SwiftUI

/// The detached mirror: a borderless, shaped window you drag anywhere, resize from its grip
/// (keeping its proportions) and keep on top. Double-click puts it back in the menu bar.
@MainActor
final class MirrorFloatingWindow: NSPanel, NSWindowDelegate {
    private weak var module: CameraMirrorModule?

    init(module: CameraMirrorModule, frame: CGRect) {
        self.module = module
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = true
        animationBehavior = .utilityWindow
        tabbingMode = .disallowed
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
        let host = NSHostingView(rootView: MirrorFloatingView(module: module, feed: .live(module.camera)))
        host.sizingOptions = []
        contentView = host
        apply(module.settings.value)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Level, opacity and shape from the settings. Shape changes resize around the center.
    func apply(_ s: MirrorSettings) {
        level = s.floatOnTop ? .floating : .normal
        alphaValue = max(0.25, min(1, s.opacity))
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        let size = FloatingGeometry.constrain(frame.size, shape: s.shape, aspect: s.aspect, visible: visible.size)
        if size != frame.size {
            let r = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            setFrame(FloatingGeometry.fit(r, in: visible), display: true, animate: false)
        }
        invalidateShadow()
    }

    override func cancelOperation(_ sender: Any?) { module?.closeMirror() }

    override func keyDown(with event: NSEvent) {
        guard let module, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ", "\r": module.takePhoto()
        case "m": module.settings.value.mirrored.toggle()
        default: super.keyDown(with: event)
        }
    }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidResize(_ notification: Notification) { invalidateShadow(); remember() }

    private func remember() {
        guard isVisible else { return }
        module?.settings.value.floatingFrame = StoredFrame(frame)
    }
}

/// The floating mirror's content: the picture in its shape, with controls while the pointer is over it.
struct MirrorFloatingView: View {
    let module: CameraMirrorModule
    let feed: MirrorFeed
    @Bindable var settings: Persisted<MirrorSettings>
    var camera: MirrorCamera
    var ui: MirrorUIState
    /// Previews show the controls without a pointer.
    var forceControls = false

    init(module: CameraMirrorModule, feed: MirrorFeed, forceControls: Bool = false) {
        self.module = module
        self.feed = feed
        self.settings = module.settings
        self.camera = module.camera
        self.ui = module.ui
        self.forceControls = forceControls
    }

    var body: some View {
        GeometryReader { geo in
            let s = settings.value
            let shape = MirrorOutline(shape: s.shape, size: geo.size)
            let showControls = ui.hovering || forceControls
            ZStack {
                if case .needsPermission = camera.status {
                    MirrorMessage(symbol: "video.slash.fill", title: Text("Camera access needed"), message: Text(""),
                                  actionTitle: nil, action: nil)
                } else {
                    MirrorVideo(feed: feed, framing: s.framing, mirrored: s.mirrored, showGrid: s.showGrid)
                }
                if ui.flash { Color.white }
                WindowDragArea(onDoubleClick: { module.attach() }, onHover: { inside in
                    withAnimation(.smooth(duration: 0.18)) { ui.hovering = inside }
                })
                if showControls {
                    FloatingControls(module: module, size: geo.size, shape: s.shape)
                        .transition(.opacity)
                }
                if s.lightCheck && camera.hint != .good && geo.size.width >= 180 {
                    LightChip(hint: camera.hint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: s.shape == .circle ? .top : .topLeading)
                        .padding(s.shape == .circle ? geo.size.height * 0.12 : 10)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 1))
            .contentShape(shape)
            .onAppear { ui.videoSize = geo.size }
            .onChange(of: geo.size) { _, new in ui.videoSize = new }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The window outline for a shape and size.
struct MirrorOutline: Shape {
    let shape: MirrorShape
    let size: CGSize

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle: Path(ellipseIn: rect)
        case .rounded, .rectangle:
            Path(roundedRect: rect, cornerRadius: FloatingGeometry.cornerRadius(shape: shape, size: size), style: .continuous)
        }
    }
}

/// Close (top right), a small glass bar (back to the menu bar, shape, photo) and the resize grip.
private struct FloatingControls: View {
    let module: CameraMirrorModule
    let size: CGSize
    let shape: MirrorShape

    /// Points on the outline's diagonal, inset so round controls sit inside the shape.
    private func corner(_ dx: CGFloat, _ dy: CGFloat, inset: CGFloat) -> CGPoint {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        if shape == .circle {
            let r = min(size.width, size.height) / 2 - inset
            return CGPoint(x: c.x + dx * r * 0.7071, y: c.y + dy * r * 0.7071)
        }
        let inner = max(inset, FloatingGeometry.cornerRadius(shape: shape, size: size) * 0.35 + inset * 0.6)
        return CGPoint(x: dx > 0 ? size.width - inner : inner, y: dy > 0 ? size.height - inner : inner)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.28), .clear, .clear, .black.opacity(0.38)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            RoundGlassButton(symbol: "xmark", help: Text("Close the mirror")) { module.closeMirror() }
                .position(corner(1, -1, inset: 18))
            ResizeGrip(module: module)
                .position(corner(1, 1, inset: 18))
            bar.position(x: size.width / 2, y: size.height - (shape == .circle ? size.height * 0.16 : 26))
        }
        .foregroundStyle(.white)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            if size.width >= 200 {
                barButton("menubar.arrow.up.rectangle", Text("Back to the menu bar (double-click)")) { module.attach() }
                barButton(nextShape.symbol, Text("Shape: \(nextShape.title)", comment: "Camera Mirror button: switch the window to this shape")) {
                    module.settings.value.shape = nextShape
                }
            }
            ShutterButton(size: 26) { module.takePhoto() }
                .padding(.horizontal, 2)
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.35)))
        .glassEffect(.regular, in: .capsule)
    }

    private var nextShape: MirrorShape {
        let all = MirrorShape.allCases
        let i = all.firstIndex(of: shape) ?? 0
        return all[(i + 1) % all.count]
    }

    private func barButton(_ symbol: String, _ help: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RoundGlassButton: View {
    let symbol: String
    let help: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.35)))
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The corner grip: drag to resize with the aspect ratio locked; the top-left corner stays put.
private struct ResizeGrip: View {
    let module: CameraMirrorModule

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.35)))
            .glassEffect(.regular, in: .circle)
            .overlay(ResizeTracker(module: module))
            .help(Text("Drag to resize"))
    }
}

private struct ResizeTracker: NSViewRepresentable {
    let module: CameraMirrorModule

    func makeNSView(context: Context) -> ResizeTrackerView {
        let v = ResizeTrackerView()
        v.module = module
        return v
    }

    func updateNSView(_ view: ResizeTrackerView, context: Context) { view.module = module }
}

final class ResizeTrackerView: NSView {
    weak var module: CameraMirrorModule?
    private var start: (mouse: CGPoint, frame: CGRect)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start, let module else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - start.mouse.x, dy = start.mouse.y - p.y
        let s = module.settings.value
        let ratio = FloatingGeometry.ratio(shape: s.shape, aspect: s.aspect)
        // Follow whichever direction the pointer moved more, measured as width.
        let grow = abs(dx) > abs(dy * ratio) ? dx : dy * ratio
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? start.frame
        let size = FloatingGeometry.constrain(CGSize(width: start.frame.width + grow, height: start.frame.height + grow / ratio),
                                              shape: s.shape, aspect: s.aspect, visible: visible.size)
        window.setFrame(CGRect(x: start.frame.minX, y: start.frame.maxY - size.height, width: size.width, height: size.height),
                        display: true)
    }

    override func mouseUp(with event: NSEvent) { start = nil }
}

/// Moves the window with the pointer (AppKit's own window drag, smooth on every display),
/// reports double-clicks and whether the pointer is inside.
struct WindowDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragAreaView {
        let v = DragAreaView()
        v.onDoubleClick = onDoubleClick
        v.onHover = onHover
        return v
    }

    func updateNSView(_ view: DragAreaView, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
    }
}

final class DragAreaView: NSView {
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
