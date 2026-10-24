import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Zoom steps for the loupe: cells across the circle (odd so one pixel sits in the middle).
enum LoupeZoom {
    static let steps = [41, 31, 23, 17, 13, 11, 9, 7]

    /// The next step toward more (`in`) or less magnification.
    static func step(_ cells: Int, zoomIn: Bool) -> Int {
        let i = steps.firstIndex(of: cells) ?? steps.firstIndex(of: 13) ?? 0
        return steps[max(0, min(steps.count - 1, i + (zoomIn ? 1 : -1)))]
    }
}

/// Shared state of a picking session, observed by every screen's loupe view.
@MainActor
@Observable
final class PickerModel {
    /// Index of the screen under the pointer.
    var screen: Int?
    /// Pointer in the active screen's view, points, origin top-left.
    var point: CGPoint = .zero
    var color = ColorValue(red: 0, green: 0, blue: 0)
    var patch: CGImage?
    var cells = 13
    var label = ""
    var name: String?
}

/// The loupe of design 06: circular pixel grid with the picked pixel ringed, and a chip below.
struct LoupeView: View {
    let patch: CGImage?
    let cells: Int
    let color: ColorValue
    let label: String
    let name: String?
    static let diameter: CGFloat = 148

    var body: some View {
        let d = Self.diameter
        ZStack {
            Circle().fill(Color.black.opacity(0.35))
            if let patch {
                Image(decorative: patch, scale: 1).resizable().interpolation(.none)
            }
            grid
            centerRing
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private var grid: some View {
        Canvas { ctx, size in
            let cell = size.width / CGFloat(cells)
            var path = Path()
            for i in 1..<cells {
                let p = CGFloat(i) * cell
                path.move(to: CGPoint(x: p, y: 0)); path.addLine(to: CGPoint(x: p, y: size.height))
                path.move(to: CGPoint(x: 0, y: p)); path.addLine(to: CGPoint(x: size.width, y: p))
            }
            ctx.stroke(path, with: .color(.black.opacity(cells > 23 ? 0.06 : 0.12)), lineWidth: 0.5)
        }
    }

    private var centerRing: some View {
        let cell = Self.diameter / CGFloat(cells)
        return ZStack {
            Rectangle().strokeBorder(.black.opacity(0.45), lineWidth: 1).frame(width: cell + 4, height: cell + 4)
            Rectangle().strokeBorder(.white, lineWidth: 2).frame(width: cell + 2, height: cell + 2)
        }
    }
}

/// The value chip under the loupe: swatch + the color in the copy format.
struct ColorChip: View {
    let color: ColorValue
    let label: String
    let name: String?

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.rgba.color)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                if let name { Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
            }
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.leading, 8).padding(.trailing, 11).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .fixedSize()
    }
}

/// Loupe and chip placed around the pointer, chip flipped above when near the bottom edge.
struct LoupeOverlay: View {
    let model: PickerModel
    let index: Int

    var body: some View {
        GeometryReader { geo in
            if model.screen == index {
                let p = model.point
                let d = LoupeView.diameter
                let below = p.y + d / 2 + 52 < geo.size.height
                LoupeView(patch: model.patch, cells: model.cells, color: model.color, label: model.label, name: model.name)
                    .position(p)
                ColorChip(color: model.color, label: model.label, name: model.name)
                    .position(x: p.x, y: below ? p.y + d / 2 + 26 : p.y - d / 2 - 26)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Receives the pointer, clicks, scroll and keys for one screen of the picker.
final class PickerEventView: NSView {
    weak var session: PickerSession?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { session?.pointerMoved() }
    override func mouseEntered(with event: NSEvent) { session?.pointerMoved() }
    override func mouseDragged(with event: NSEvent) { session?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { session?.click(button: 0) }
    override func rightMouseDown(with event: NSEvent) { session?.click(button: 1) }
    override func otherMouseDown(with event: NSEvent) {
        session?.click(button: event.buttonNumber == 2 ? 2 : 1)
    }
    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        session?.scroll(dy)
    }
    override func keyDown(with event: NSEvent) {
        if session?.key(event) != true { super.keyDown(with: event) }
    }
}

/// One activation of the picker: a frozen capture per screen, the loupe following the pointer.
///
/// Clicks map to the mouse actions in settings; Return picks like a left click; arrow keys move
/// the pointer one pixel (⇧: ten); scroll changes the magnification; Esc cancels.
@MainActor
final class PickerSession {
    enum Outcome {
        case picked(ColorValue, ColorPickerClick)
        case cancelled
    }

    private struct Screen {
        let screen: NSScreen
        let pixels: ScreenPixels
        let panel: OverlayPanel
        /// Image pixels per point (the capture's real scale, which may differ from the backing scale).
        let scale: CGFloat
    }

    let model = PickerModel()
    private var screens: [Screen] = []
    private let settings: ColorPickerSettings
    private let finish: (Outcome) -> Void
    private var finished = false
    private var cursorHidden = false
    private var scrollAccumulator: CGFloat = 0
    /// Pixel position tracked separately so 1-px nudges survive point rounding.
    private var pixel: (x: Int, y: Int) = (0, 0)

    init(settings: ColorPickerSettings, finish: @escaping (Outcome) -> Void) {
        self.settings = settings
        self.finish = finish
        model.cells = LoupeZoom.steps.contains(settings.magnifierCells) ? settings.magnifierCells : 13
    }

    /// Shows the overlays. Returns false when no capture could be converted.
    func begin(_ captures: [(NSScreen, CGImage)]) -> Bool {
        for (screen, image) in captures {
            guard let pixels = ScreenPixels(image) else { continue }
            let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
            panel.acceptsMouseMovedEvents = true
            let root = PickerEventView(frame: CGRect(origin: .zero, size: screen.frame.size))
            root.session = self
            root.wantsLayer = true
            root.layer?.contents = pixels.image
            root.layer?.contentsGravity = .resize
            root.layer?.magnificationFilter = .nearest
            // `screens` skips captures that couldn't be converted, so index by its count.
            let host = NSHostingView(rootView: LoupeOverlay(model: model, index: screens.count))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            panel.contentView = root
            screens.append(Screen(screen: screen, pixels: pixels, panel: panel,
                                  scale: CGFloat(pixels.width) / max(1, screen.frame.width)))
        }
        guard !screens.isEmpty else { return false }
        for s in screens { s.panel.orderFrontRegardless() }
        let underMouse = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) } ?? screens[0]
        underMouse.panel.present()
        underMouse.panel.makeFirstResponder(underMouse.panel.contentView)
        NSCursor.hide()
        cursorHidden = true
        pointerMoved()
        return true
    }

    /// Closes everything without reporting (module stopped).
    func tearDown() {
        finished = true
        close()
    }

    // MARK: Input

    func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        guard let index = screens.firstIndex(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) else { return }
        let s = screens[index]
        let local = CGPoint(x: mouse.x - s.screen.frame.minX, y: s.screen.frame.maxY - mouse.y)
        let px = Int((local.x * s.scale).rounded(.down)), py = Int((local.y * s.scale).rounded(.down))
        pixel = (min(max(px, 0), s.pixels.width - 1), min(max(py, 0), s.pixels.height - 1))
        update(screen: index, point: local)
        if !s.panel.isKeyWindow {
            s.panel.makeKey()
            s.panel.makeFirstResponder(s.panel.contentView)
        }
    }

    func scroll(_ dy: CGFloat) {
        scrollAccumulator += dy
        guard abs(scrollAccumulator) >= 1 else { return }
        model.cells = LoupeZoom.step(model.cells, zoomIn: scrollAccumulator > 0)
        scrollAccumulator = 0
        refresh()
    }

    func click(button: Int) {
        pointerMoved()
        let action = settings.action(forButton: button)
        complete(action == .close ? .cancelled : .picked(model.color, action))
    }

    /// Returns true when the key was handled.
    func key(_ event: NSEvent) -> Bool {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 53: complete(.cancelled)                                         // esc
        case 36, 76: complete(.picked(model.color, settings.leftClick == .close ? .pickAndClose : settings.leftClick))
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: step)
        case 126: nudge(dx: 0, dy: -step)
        case 24, 69: scroll(1)                                                // = / keypad +
        case 27, 78: scroll(-1)                                               // - / keypad -
        default: return false
        }
        return true
    }

    // MARK: Private

    private func nudge(dx: Int, dy: Int) {
        guard let index = model.screen else { return }
        let s = screens[index]
        pixel = (min(max(pixel.x + dx, 0), s.pixels.width - 1), min(max(pixel.y + dy, 0), s.pixels.height - 1))
        let local = CGPoint(x: (CGFloat(pixel.x) + 0.5) / s.scale, y: (CGFloat(pixel.y) + 0.5) / s.scale)
        let global = CGPoint(x: s.screen.frame.minX + local.x, y: s.screen.frame.maxY - local.y)
        MouseSynth.warp(to: ScreenGeometry.toAX(global))
        update(screen: index, point: local)
    }

    private func update(screen index: Int, point: CGPoint) {
        model.screen = index
        model.point = point
        refresh()
    }

    private func refresh() {
        guard let index = model.screen else { return }
        let s = screens[index]
        let color = s.pixels.color(x: pixel.x, y: pixel.y) ?? model.color
        model.color = color
        model.patch = s.pixels.patch(centerX: pixel.x, centerY: pixel.y, size: model.cells)
        model.label = ColorFormatter.format(color, settings.copyFormat.format)
        model.name = settings.showColorName ? ColorNames.name(for: color) : nil
    }

    private func complete(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        close()
        finish(outcome)
    }

    private func close() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        for s in screens {
            s.panel.orderOut(nil)
            (s.panel.contentView as? PickerEventView)?.session = nil
            s.panel.contentView = nil
        }
        screens.removeAll()
    }
}
