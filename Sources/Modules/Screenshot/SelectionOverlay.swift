import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What a capture session ended with.
enum CaptureTarget {
    /// An area of a display (its points, top-left origin), with the frozen image it was picked on, if any.
    case area(NSScreen, CGRect, frozen: (CGImage, CGFloat)?)
    case window(CaptureWindow, NSScreen)
    case display(NSScreen)
}

/// A window the pointer can pick, from the window server's list.
struct CaptureWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    /// Global top-left frame.
    let frame: CGRect
    /// Set for sample windows (previews) whose app isn't running.
    var bundleID: String?

    init(id: CGWindowID, pid: pid_t, app: String, title: String, frame: CGRect, bundleID: String? = nil) {
        self.id = id
        self.pid = pid
        self.app = app
        self.title = title
        self.frame = frame
        self.bundleID = bundleID
    }

    init(_ info: WindowInfo) {
        self.init(id: info.id, pid: info.pid, app: info.ownerName, title: info.title, frame: info.frame)
    }

    var appIcon: NSImage? {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// Live state of a capture session, shared by every display's overlay.
@MainActor
@Observable
final class SelectionModel {
    enum Mode: Equatable { case area, window, display }

    struct Display {
        let screen: NSScreen?
        /// Global top-left frame.
        let axFrame: CGRect
        let scale: CGFloat
        /// A still of the display: shown when frozen, magnified in the loupe.
        let snapshot: CGImage?
        let name: String
        var size: CGSize { axFrame.size }
        var bounds: CGRect { CGRect(origin: .zero, size: axFrame.size) }
        /// A global top-left rect in this display's local points.
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -axFrame.minX, dy: -axFrame.minY) }
    }

    var mode: Mode
    let displays: [Display]
    let frozen: Bool
    let showMagnifier: Bool
    let showCrosshair: Bool
    /// The display under the pointer.
    var active: Int?
    /// Pointer in the active display's local points.
    var pointer: CGPoint = .zero
    var selection: CGRect?
    var selectionDisplay: Int?
    /// The selection waits for Return (a remembered area); it shows handles and can be moved.
    var adjusting = false
    var dragging = false
    /// Zoomed pixels around the pointer.
    var loupe: CGImage?
    var hoveredWindow: CaptureWindow?
    /// On-screen windows, front to back (window mode).
    @ObservationIgnored var windows: [CaptureWindow] = []
    /// Whether Space may switch between area and window mode.
    let canSwitchMode: Bool

    init(mode: Mode, displays: [Display], frozen: Bool, showMagnifier: Bool, showCrosshair: Bool, canSwitchMode: Bool) {
        self.mode = mode
        self.displays = displays
        self.frozen = frozen
        self.showMagnifier = showMagnifier
        self.showCrosshair = showCrosshair
        self.canSwitchMode = canSwitchMode
    }

    static let loupeCells = 15
}

// MARK: - Drawing

/// One display's overlay: dimming, selection, handles, size, crosshair, loupe, window highlight and hints.
struct SelectionOverlayView: View {
    let model: SelectionModel
    let index: Int

    var body: some View {
        let display = model.displays[index]
        ZStack(alignment: .topLeading) {
            switch model.mode {
            case .area: areaLayer(display)
            case .window: windowLayer(display)
            case .display: displayLayer(display)
            }
            if model.active == index, !model.dragging {
                SelectionHint(mode: model.mode, adjusting: model.adjusting, canSwitchMode: model.canSwitchMode)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 44)
                    .transition(.opacity)
            }
        }
        .frame(width: display.size.width, height: display.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Area

    @ViewBuilder private func areaLayer(_ display: SelectionModel.Display) -> some View {
        let selection = model.selectionDisplay == index ? model.selection : nil
        let isActive = model.active == index
        Canvas { ctx, size in
            if let r = selection, r.width > 0 || r.height > 0 {
                var dim = Path(CGRect(origin: .zero, size: size))
                dim.addRect(r)
                ctx.fill(dim, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(r.insetBy(dx: -0.5, dy: -0.5)), with: .color(.black.opacity(0.35)), lineWidth: 2)
                ctx.stroke(Path(r.insetBy(dx: -0.5, dy: -0.5)), with: .color(.white), lineWidth: 1)
            }
            if isActive, model.showCrosshair, !model.adjusting || model.dragging {
                let p = model.pointer
                var lines = Path()
                lines.move(to: CGPoint(x: 0, y: p.y.rounded() + 0.5)); lines.addLine(to: CGPoint(x: size.width, y: p.y.rounded() + 0.5))
                lines.move(to: CGPoint(x: p.x.rounded() + 0.5, y: 0)); lines.addLine(to: CGPoint(x: p.x.rounded() + 0.5, y: size.height))
                ctx.stroke(lines, with: .color(.black.opacity(0.28)), lineWidth: 3)
                ctx.stroke(lines, with: .color(.white.opacity(0.85)), lineWidth: 1)
            }
        }
        if let r = selection, model.adjusting, !model.dragging {
            ForEach(AreaGeometry.Handle.allCases, id: \.self) { h in
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .position(h.point(in: r))
            }
        }
        if let r = selection, r.width >= 1, r.height >= 1 {
            let px = AreaGeometry.pixelSize(r, scale: display.scale)
            SizeLabel(text: "\(px.width) × \(px.height)")
                .fixedSize()
                .position(SizeLabel.position(for: r, in: display.bounds))
        }
        if isActive, model.showMagnifier, !(model.adjusting && !model.dragging), model.loupe != nil {
            let size = LoupeCard.size
            let origin = AreaGeometry.loupeOrigin(pointer: model.pointer, size: size, in: display.bounds)
            LoupeCard(patch: model.loupe, cells: SelectionModel.loupeCells,
                      coordinate: "\(Int(model.pointer.x.rounded())), \(Int(model.pointer.y.rounded()))")
                .frame(width: size.width, height: size.height)
                .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        }
    }

    // MARK: Window

    @ViewBuilder private func windowLayer(_ display: SelectionModel.Display) -> some View {
        if let w = model.hoveredWindow {
            let r = display.local(w.frame)
            if r.intersects(display.bounds) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                WindowLabel(window: w, scale: display.scale)
                    .fixedSize()
                    .position(x: min(max(r.midX, 160), display.size.width - 160),
                              y: min(max(r.maxY - 34, r.minY + 30), display.size.height - 40))
            }
        }
    }

    // MARK: Display

    @ViewBuilder private func displayLayer(_ display: SelectionModel.Display) -> some View {
        if model.active == index {
            Rectangle().fill(Color.accentColor.opacity(0.14))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 5))
            DisplayCard(name: display.name, size: display.size, scale: display.scale)
                .fixedSize()
                .position(x: display.size.width / 2, y: display.size.height / 2)
        } else {
            Rectangle().fill(.black.opacity(0.32))
        }
    }
}

/// The selection size, in pixels, near the selection's bottom-right corner.
struct SizeLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(white: 0.08).opacity(0.86)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
    }

    /// Below the selection's bottom-right corner, inside it when there's no room below.
    static func position(for r: CGRect, in bounds: CGRect) -> CGPoint {
        let below = r.maxY + 22 < bounds.maxY
        let x = min(max(r.maxX - 44, bounds.minX + 50), bounds.maxX - 50)
        return CGPoint(x: x, y: below ? r.maxY + 16 : r.maxY - 18)
    }
}

/// Magnified pixels around the crosshair, with the pointer position.
struct LoupeCard: View {
    let patch: CGImage?
    let cells: Int
    let coordinate: String
    static let size = CGSize(width: 132, height: 158)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let patch { Image(decorative: patch, scale: 1).resizable().interpolation(.none) }
                Canvas { ctx, size in
                    let cell = size.width / CGFloat(cells)
                    var grid = Path()
                    for i in 1..<cells {
                        let p = CGFloat(i) * cell
                        grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: size.width, y: p))
                    }
                    ctx.stroke(grid, with: .color(.black.opacity(0.1)), lineWidth: 0.5)
                    let mid = CGFloat(cells / 2) * cell
                    var cross = Path()
                    cross.move(to: CGPoint(x: mid + cell / 2, y: 0)); cross.addLine(to: CGPoint(x: mid + cell / 2, y: mid))
                    cross.move(to: CGPoint(x: mid + cell / 2, y: mid + cell)); cross.addLine(to: CGPoint(x: mid + cell / 2, y: size.height))
                    cross.move(to: CGPoint(x: 0, y: mid + cell / 2)); cross.addLine(to: CGPoint(x: mid, y: mid + cell / 2))
                    cross.move(to: CGPoint(x: mid + cell, y: mid + cell / 2)); cross.addLine(to: CGPoint(x: size.width, y: mid + cell / 2))
                    ctx.stroke(cross, with: .color(Tint.pink.color.opacity(0.75)), lineWidth: 1)
                    let center = CGRect(x: mid, y: mid, width: cell, height: cell)
                    ctx.stroke(Path(center.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.5)), lineWidth: 1)
                    ctx.stroke(Path(center), with: .color(.white), lineWidth: 1.5)
                }
            }
            .frame(width: Self.size.width - 8, height: Self.size.width - 8)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(verbatim: coordinate)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxHeight: .infinity)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }

    /// `cells`×`cells` pixels of `image` centered on a pixel; transparent beyond the edges.
    static func patch(of image: CGImage, centerX cx: Int, centerY cy: Int, cells: Int) -> CGImage? {
        let half = cells / 2
        let want = CGRect(x: cx - half, y: cy - half, width: cells, height: cells)
        let have = want.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !have.isNull, let piece = image.cropping(to: have),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cells, height: cells, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // Bitmap y runs up: place the piece by its distance from the patch's bottom edge.
        let x = have.minX - want.minX
        let y = want.maxY - have.maxY
        ctx.draw(piece, in: CGRect(x: x, y: y, width: have.width, height: have.height))
        return ctx.makeImage()
    }
}

/// App, title and size of the window under the pointer.
struct WindowLabel: View {
    let window: CaptureWindow
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let icon = window.appIcon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(verbatim: window.title.isEmpty ? window.app : "\(window.app) — \(window.title)")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 280, alignment: .leading)
            Text(verbatim: "\(Int(window.frame.width * scale)) × \(Int(window.frame.height * scale))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(white: 0.08).opacity(0.88)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
    }
}

/// "Click to capture" card on the display under the pointer.
struct DisplayCard: View {
    let name: String
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 38, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                Text(verbatim: name).font(.system(size: 17, weight: .semibold))
                Text(verbatim: "\(Int(size.width * scale)) × \(Int(size.height * scale))")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Click to capture this display", comment: "Screenshot: choosing which display to capture")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
    }
}

/// Keys that work right now, at the top of the active display.
struct SelectionHint: View {
    let mode: SelectionModel.Mode
    let adjusting: Bool
    let canSwitchMode: Bool

    var body: some View {
        HStack(spacing: 14) {
            switch mode {
            case .area:
                if adjusting {
                    item(Text("Capture", comment: "Area selection hint: Return captures the selection"), keys: ["↩"])
                    item(Text("Nudge", comment: "Area selection hint: arrow keys move the selection"), keys: ["←", "→"])
                    item(Text("Resize", comment: "Area selection hint: option + arrow keys resize"), keys: ["⌥", "→"])
                } else {
                    Text("Drag to select an area", comment: "Area selection hint").font(.system(size: 12.5, weight: .semibold))
                    item(Text("Square", comment: "Area selection hint: hold shift for a square"), keys: ["⇧"])
                    item(Text("From center", comment: "Area selection hint: hold option to draw from the center"), keys: ["⌥"])
                }
                if canSwitchMode {
                    item(Text("Window", comment: "Area selection hint: Space switches to window capture"), keys: [KeyCodes.name(for: 49)])
                }
            case .window:
                Text("Click a window to capture it", comment: "Window capture hint").font(.system(size: 12.5, weight: .semibold))
                if canSwitchMode {
                    item(Text("Area", comment: "Window capture hint: Space switches back to area selection"), keys: [KeyCodes.name(for: 49)])
                }
            case .display:
                Text("Click a display to capture it", comment: "Display capture hint").font(.system(size: 12.5, weight: .semibold))
            }
            item(Text("Cancel", comment: "Capture hint: esc cancels"), keys: ["esc"])
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.86)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .fixedSize()
    }

    private func item(_ label: Text, keys: [String]) -> some View {
        HStack(spacing: 5) {
            Keycaps(keys, dark: true)
            label.font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - Events

/// Receives the pointer and keys for one display of a capture session.
final class SelectionEventView: NSView {
    weak var session: CaptureSession?
    let index: Int
    /// Live (not frozen) overlays are nearly clear: fully clear pixels would let clicks through.
    var catchesClicks = true

    init(frame: NSRect, index: Int) {
        self.index = index
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard catchesClicks else { return }
        NSColor(white: 0, alpha: 0.008).setFill()
        dirtyRect.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited,
                                                              .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { session?.updateCursor() }
    override func mouseEntered(with event: NSEvent) { session?.pointerMoved() }
    override func mouseMoved(with event: NSEvent) { session?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { session?.mouseDown(clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { session?.mouseUp() }
    override func rightMouseDown(with event: NSEvent) { session?.cancel() }
    override func flagsChanged(with event: NSEvent) { session?.modifiersChanged(event.modifierFlags) }
    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) != true { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
}

// MARK: - Session

/// One capture: overlays on every display until an area, window or display is picked (or Esc).
@MainActor
final class CaptureSession {
    let model: SelectionModel
    var onFinish: ((CaptureTarget?) -> Void)?

    private var panels: [OverlayPanel] = []
    private var anchor: CGPoint?
    private var resizing: AreaGeometry.Handle?
    private var moving: (start: CGPoint, rect: CGRect)?
    private var spaceHeld = false
    private var lastPointer: CGPoint = .zero
    private var modifiers: NSEvent.ModifierFlags = []
    private var finished = false
    private var windowsLoaded = false
    private let previousApp = NSWorkspace.shared.frontmostApplication

    /// - Parameter initial: a remembered area to start with (display index, local rect).
    init(model: SelectionModel, initial: (Int, CGRect)? = nil) {
        self.model = model
        if let (i, r) = initial, model.mode == .area {
            model.selection = r
            model.selectionDisplay = i
            model.adjusting = true
        }
        if model.mode == .window { loadWindows() }
    }

    func begin() {
        for (i, display) in model.displays.enumerated() {
            guard let screen = display.screen else { continue }
            let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
            panel.acceptsMouseMovedEvents = true
            let root = SelectionEventView(frame: CGRect(origin: .zero, size: screen.frame.size), index: i)
            root.session = self
            root.wantsLayer = true
            if model.frozen, let still = display.snapshot {
                root.layer?.contents = still
                root.layer?.contentsGravity = .resize
                root.catchesClicks = false
            }
            let host = NSHostingView(rootView: SelectionOverlayView(model: model, index: i))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            panel.contentView = root
            panels.append(panel)
        }
        for p in panels { p.orderFrontRegardless() }
        pointerMoved()
        let key = model.active.flatMap { $0 < panels.count ? panels[$0] : nil } ?? panels.first
        key?.present()
        key?.makeFirstResponder(key?.contentView)
        updateCursor()
    }

    func cancel() { finish(nil) }

    // MARK: Pointer

    /// The display under the pointer and the pointer in its local points.
    private func locate() -> (Int, CGPoint)? {
        let global = ScreenGeometry.toAX(NSEvent.mouseLocation)
        guard let i = model.displays.firstIndex(where: { $0.axFrame.insetBy(dx: -0.5, dy: -0.5).contains(global) }) else { return nil }
        let f = model.displays[i].axFrame
        return (i, CGPoint(x: global.x - f.minX, y: global.y - f.minY))
    }

    func pointerMoved() {
        guard let (i, p) = locate() else { return }
        if model.active != i {
            model.active = i
            if i < panels.count, !panels[i].isKeyWindow {
                panels[i].makeKey()
                panels[i].makeFirstResponder(panels[i].contentView)
            }
        }
        model.pointer = p
        if model.mode == .window { hoverWindow() }
        updateLoupe()
    }

    func mouseDown(clickCount: Int) {
        guard let (i, p) = locate() else { return }
        switch model.mode {
        case .window:
            hoverWindow()
            if let w = model.hoveredWindow, let screen = ScreenGeometry.screen(forAX: w.frame) { finish(.window(w, screen)) }
        case .display:
            if let screen = model.displays[i].screen { finish(.display(screen)) }
        case .area:
            if model.adjusting, model.selectionDisplay == i, let r = model.selection {
                if clickCount >= 2, r.contains(p) { finishArea(); return }
                if let h = AreaGeometry.handle(at: p, of: r, radius: 9) { resizing = h; return }
                if r.contains(p) { moving = (p, r); return }
            }
            model.adjusting = false
            model.selectionDisplay = i
            model.selection = CGRect(origin: p, size: .zero)
            model.dragging = true
            anchor = p
            lastPointer = p
        }
    }

    func mouseDragged() {
        guard model.mode == .area, let d = model.selectionDisplay else { pointerMoved(); return }
        let global = ScreenGeometry.toAX(NSEvent.mouseLocation)
        let f = model.displays[d].axFrame
        let p = CGPoint(x: global.x - f.minX, y: global.y - f.minY)
        drag(to: p, display: d)
        if let (i, local) = locate() {
            model.active = i
            model.pointer = i == d ? p : local
        }
        updateLoupe()
    }

    private func drag(to p: CGPoint, display d: Int) {
        let bounds = model.displays[d].bounds
        if let h = resizing, let r = model.selection {
            model.selection = AreaGeometry.resized(r, handle: h, to: p, in: bounds)
        } else if let m = moving {
            model.selection = AreaGeometry.moved(m.rect, by: CGVector(dx: p.x - m.start.x, dy: p.y - m.start.y), in: bounds)
        } else if let a = anchor {
            if spaceHeld, let r = model.selection {
                let moved = AreaGeometry.moved(r, by: CGVector(dx: p.x - lastPointer.x, dy: p.y - lastPointer.y), in: bounds)
                anchor = CGPoint(x: a.x + moved.minX - r.minX, y: a.y + moved.minY - r.minY)
                model.selection = moved
            } else {
                model.selection = AreaGeometry.rect(anchor: a, current: p, square: modifiers.contains(.shift),
                                                    fromCenter: modifiers.contains(.option), in: bounds)
            }
        }
        lastPointer = p
    }

    func mouseUp() {
        if resizing != nil || moving != nil {
            resizing = nil
            moving = nil
            return
        }
        guard anchor != nil else { return }
        anchor = nil
        spaceHeld = false
        model.dragging = false
        if let r = model.selection, AreaGeometry.isUsable(r) {
            finishArea()
        } else {
            model.selection = nil
            model.selectionDisplay = nil
        }
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        modifiers = flags.intersection(.deviceIndependentFlagsMask)
        if anchor != nil, !spaceHeld, let d = model.selectionDisplay { drag(to: lastPointer, display: d) }
    }

    // MARK: Keys

    func keyDown(_ event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 53: cancel()                                                     // esc
        case 49:                                                              // space
            if anchor != nil {
                spaceHeld = true
            } else if !event.isARepeat, model.canSwitchMode {
                toggleMode()
            }
        case 36, 76:                                                          // return, enter
            if model.mode == .area, model.adjusting { finishArea() }
            if model.mode == .window, let w = model.hoveredWindow, let screen = ScreenGeometry.screen(forAX: w.frame) {
                finish(.window(w, screen))
            }
        case 123: arrow(dx: -step, dy: 0, resize: event.modifierFlags.contains(.option))
        case 124: arrow(dx: step, dy: 0, resize: event.modifierFlags.contains(.option))
        case 125: arrow(dx: 0, dy: step, resize: event.modifierFlags.contains(.option))
        case 126: arrow(dx: 0, dy: -step, resize: event.modifierFlags.contains(.option))
        default: return false
        }
        return true
    }

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    /// Arrows nudge an adjustable selection; otherwise they move the pointer one point (⇧: ten).
    private func arrow(dx: CGFloat, dy: CGFloat, resize: Bool) {
        if model.mode == .area, model.adjusting, anchor == nil, let r = model.selection, let d = model.selectionDisplay {
            model.selection = AreaGeometry.nudged(r, dx: dx, dy: dy, resize: resize, in: model.displays[d].bounds)
            return
        }
        guard let (i, p) = locate() else { return }
        let display = model.displays[i]
        let q = AreaGeometry.clamp(CGPoint(x: p.x + dx, y: p.y + dy), to: display.bounds.insetBy(dx: 0, dy: 0))
        MouseSynth.warp(to: CGPoint(x: display.axFrame.minX + q.x, y: display.axFrame.minY + q.y))
        if anchor != nil, let d = model.selectionDisplay {
            drag(to: q, display: d)
            model.pointer = q
            updateLoupe()
        } else {
            pointerMoved()
        }
    }

    private func toggleMode() {
        switch model.mode {
        case .area:
            model.mode = .window
            model.selection = nil
            model.adjusting = false
            loadWindows()
            hoverWindow()
        case .window:
            model.mode = .area
            model.hoveredWindow = nil
        case .display:
            return
        }
        updateCursor()
    }

    // MARK: Windows

    private func loadWindows() {
        guard !windowsLoaded else { return }
        windowsLoaded = true
        model.windows = WindowInfo.onScreen(includeOwn: true).filter { $0.isOnScreen }.map(CaptureWindow.init)
    }

    private func hoverWindow() {
        guard let (i, p) = locate() else { return }
        let f = model.displays[i].axFrame
        let global = CGPoint(x: f.minX + p.x, y: f.minY + p.y)
        let hit = model.windows.first { $0.frame.contains(global) }
        if hit != model.hoveredWindow { model.hoveredWindow = hit }
    }

    // MARK: Loupe and cursor

    private func updateLoupe() {
        guard model.showMagnifier, model.mode == .area, let i = model.active, let still = model.displays[i].snapshot else {
            if model.loupe != nil { model.loupe = nil }
            return
        }
        let scale = CGFloat(still.width) / max(1, model.displays[i].size.width)
        let px = Int((model.pointer.x * scale).rounded(.down)), py = Int((model.pointer.y * scale).rounded(.down))
        model.loupe = LoupeCard.patch(of: still, centerX: px, centerY: py, cells: SelectionModel.loupeCells)
    }

    func updateCursor() {
        switch model.mode {
        case .area, .display: NSCursor.crosshair.set()
        case .window: CaptureCursor.camera.set()
        }
    }

    // MARK: Finish

    private func finishArea() {
        guard let r = model.selection, let d = model.selectionDisplay, AreaGeometry.isUsable(r),
              let screen = model.displays[d].screen else { return }
        let display = model.displays[d]
        let snapped = AreaGeometry.snapped(r, scale: display.scale)
        let frozen: (CGImage, CGFloat)? = model.frozen ? display.snapshot.map { ($0, CGFloat($0.width) / max(1, display.size.width)) } : nil
        finish(.area(screen, snapped, frozen: frozen))
    }

    private func finish(_ target: CaptureTarget?) {
        guard !finished else { return }
        finished = true
        for p in panels {
            p.orderOut(nil)
            (p.contentView as? SelectionEventView)?.session = nil
            p.contentView = nil
        }
        panels.removeAll()
        NSCursor.arrow.set()
        if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        let callback = onFinish
        onFinish = nil
        callback?(target)
    }
}

/// The camera pointer shown while picking a window.
@MainActor
enum CaptureCursor {
    static let camera: NSCursor = {
        let side: CGFloat = 30
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1
            ring.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()
}
