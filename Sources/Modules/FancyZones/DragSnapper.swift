import AppKit
import MacToysCore

/// Detects window drags and snaps the window into the zone under the pointer.
///
/// A drag is a left-button press followed by the window under the pointer changing position
/// (and not size) through Accessibility. The event-tap handler only copies a few scalars; a
/// 60 Hz timer running while the button is down does the Accessibility reads, hit testing and
/// drawing, so the tap stays allocation-free and never blocks.
@MainActor
final class DragSnapper {
    private unowned let engine: ZoneEngine
    private static let tapID = "fancyzones.drag"

    private enum Phase { case idle, pressed, candidate, dragging, ignored }

    // Written by the tap handler (scalars only).
    private var phase = Phase.idle
    private var location = CGPoint.zero
    private var pressLocation = CGPoint.zero
    private var flags = CGEventFlags()
    private var mouseToggled = false
    private var spanToggled = false
    private var wheelSteps = 0
    private var wheelAccumulator: Double = 0
    private var swallowRightUp = false
    private var swallowOtherUp = false
    private var released = false
    // Settings snapshot taken when a drag starts, read by the tap handler.
    private var cfgNonPrimary = false
    private var cfgMiddleSpans = false
    private var wheelEnabled = false
    private var zonesShown = false

    // Drag session, owned by the timer.
    private var pump: Timer?
    private var ticks = 0
    private var window: WindowRef?
    private var startFrame = CGRect.zero
    private var originalSize: CGSize?
    private var displays: [ZoneDisplay] = []
    private var layouts: [ZoneLayout] = []
    private var displayZones: [[CGRect]] = []
    private var activeIndex: Int?
    private var highlighted: [Int] = []
    private var renderedIndex: Int?
    private var spanAnchor: [Int]?

    init(engine: ZoneEngine) {
        self.engine = engine
    }

    var isDragging: Bool { phase == .dragging }

    func start() {
        InputTap.shared.add(Self.tapID, priority: 40,
                            events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                     .otherMouseDown, .otherMouseUp, .flagsChanged, .scrollWheel]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    func stop() {
        InputTap.shared.remove(Self.tapID)
        endSession()
    }

    /// A display's layout changed (quick key or wheel) during a drag: redraw with the new zones.
    func layoutChanged(on display: ZoneDisplay) {
        guard phase == .dragging, let i = displays.firstIndex(where: { $0.key == display.key }) else { return }
        layouts[i] = engine.layout(for: displays[i])
        displayZones[i] = layouts[i].zones(in: displays[i].workArea)
        highlighted = []
        spanAnchor = nil
        renderedIndex = nil
        if zonesShown { engine.overlay.showLayoutName(layouts[i].name, on: displays[i], settings: engine.settings.value) }
        update()
    }

    // MARK: Tap (hot path: scalars only)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .leftMouseDown:
            if released { finish() }
            endSession()
            phase = .pressed
            pressLocation = event.location
            location = pressLocation
            flags = event.flags
            return .pass
        case .leftMouseDragged:
            guard phase == .pressed || phase == .candidate || phase == .dragging else { return .pass }
            location = event.location
            flags = event.flags
            if pump == nil { startPump() }
            return .pass
        case .leftMouseUp:
            guard phase != .idle else { return .pass }
            location = event.location
            if pump == nil || phase == .ignored { endSession(); return .pass }
            released = true
            DispatchQueue.main.async { [weak self] in self?.finish() }
            return .pass
        case .flagsChanged:
            if phase != .idle { flags = event.flags }
            return .pass
        case .rightMouseDown, .otherMouseDown:
            guard phase == .dragging else { return .pass }
            if type == .otherMouseDown && cfgMiddleSpans && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                spanToggled.toggle()
                swallowOtherUp = true
                return .consume
            }
            guard cfgNonPrimary else { return .pass }
            mouseToggled.toggle()
            if type == .rightMouseDown { swallowRightUp = true } else { swallowOtherUp = true }
            return .consume
        case .rightMouseUp:
            guard swallowRightUp else { return .pass }
            swallowRightUp = false
            return .consume
        case .otherMouseUp:
            guard swallowOtherUp else { return .pass }
            swallowOtherUp = false
            return .consume
        case .scrollWheel:
            guard phase == .dragging, zonesShown, wheelEnabled else { return .pass }
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return .consume }
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                wheelAccumulator += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                if abs(wheelAccumulator) >= 40 {
                    wheelSteps += wheelAccumulator < 0 ? 1 : -1
                    wheelAccumulator = 0
                }
            } else {
                let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                if delta != 0 { wheelSteps += delta < 0 ? 1 : -1 }
            }
            return .consume
        default:
            return .pass
        }
    }

    // MARK: Session

    private func startPump() {
        let s = engine.settings.value
        cfgNonPrimary = s.nonPrimaryButtonToggles
        cfgMiddleSpans = s.middleButtonSpansZones
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer      // first tick runs outside the tap callback
    }

    private func tick() {
        ticks += 1
        switch phase {
        case .pressed:
            guard !Self.isOverOwnWindow(location), let w = WindowRef.at(location), engine.isSnappable(w),
                  let f = w.frame else { ignore(); return }
            window = w
            startFrame = f
            phase = .candidate
        case .candidate:
            guard ticks % 2 == 0, let w = window else { return }
            guard let f = w.frame else { ignore(); return }
            if abs(f.width - startFrame.width) > 1 || abs(f.height - startFrame.height) > 1 { ignore(); return }
            if abs(f.minX - startFrame.minX) > 1 || abs(f.minY - startFrame.minY) > 1 {
                beginDrag(w, frame: f)
            } else if hypot(location.x - pressLocation.x, location.y - pressLocation.y) > 24 {
                ignore()      // the pointer travelled but the window stayed: selecting text, dragging a file…
            }
        case .dragging:
            update()
        case .idle, .ignored:
            break
        }
    }

    private func beginDrag(_ w: WindowRef, frame: CGRect) {
        phase = .dragging
        let s = engine.settings.value
        displays = engine.displays
        layouts = displays.map { engine.layout(for: $0) }
        displayZones = zip(layouts, displays).map { $0.zones(in: $1.workArea) }
        wheelEnabled = s.mouseWheelSwitchesLayouts && engine.library.value.wheelCycle.count >= 2
        if let record = engine.record(for: w) {
            originalSize = record.originalSize
            engine.forget(w)
            if s.restoreSizeOnUnsnap, record.originalSize != frame.size, frame.width > 0 {
                // Keep the pointer at the same relative spot of the narrower title bar.
                let ratio = (location.x - frame.minX) / frame.width
                w.setSize(record.originalSize)
                w.setPosition(CGPoint(x: location.x - ratio * record.originalSize.width, y: frame.minY))
                originalSize = nil
            }
        } else {
            originalSize = startFrame.size
        }
        update()
    }

    /// Recomputes activation and highlight; redraws only when something changed.
    private func update() {
        guard !displays.isEmpty else { return }
        let s = engine.settings.value
        let toggledShift = flags.contains(.maskShift) != mouseToggled
        let active = s.holdShiftToActivate ? toggledShift : !toggledShift
        guard active else {
            if zonesShown { engine.overlay.hide(); zonesShown = false; highlighted = []; renderedIndex = nil }
            spanAnchor = nil
            return
        }
        let index = displays.firstIndex { $0.frame.containsInclusive(location) }
            ?? displays.indices.min { displays[$0].frame.distance(to: location) < displays[$1].frame.distance(to: location) }
        guard let index else { return }
        if index != activeIndex { activeIndex = index; spanAnchor = nil }

        if wheelSteps != 0 {
            let steps = wheelSteps
            wheelSteps = 0
            if let next = engine.library.value.cycled(from: layouts[index].id, steps: steps) {
                engine.apply(next, to: displays[index], announce: false)   // redraws through layoutChanged
                return
            }
        }

        let zones = displayZones[index]
        var hits = ZoneGeometry.zones(at: location, in: zones, distance: CGFloat(layouts[index].highlightDistance),
                                      algorithm: s.overlapAlgorithm)
        if flags.contains(.maskCommand) != spanToggled {
            if spanAnchor == nil && !hits.isEmpty { spanAnchor = hits }
            if let anchor = spanAnchor { hits = hits.isEmpty ? highlighted : ZoneGeometry.span(from: anchor, to: hits, in: zones) }
        } else {
            spanAnchor = nil
        }
        guard !zonesShown || hits != highlighted || renderedIndex != index else { return }
        highlighted = hits
        renderedIndex = index
        render(index, showAll: s.showZonesOnAllDisplays)
    }

    private func render(_ index: Int, showAll: Bool) {
        let layers = displays.indices.map { i in
            ZoneLayer(display: displays[i], zones: displayZones[i], highlighted: i == index ? Set(highlighted) : [])
        }
        let screen = NSScreen.screens.map(\.axFrame).first { $0.containsInclusive(location) }
        engine.overlay.show(layers, style: engine.style, onlyScreen: showAll ? nil : screen)
        zonesShown = true
    }

    /// Mouse released: snap if zones are showing and one is highlighted.
    private func finish() {
        guard released else { return }
        if phase == .dragging {
            update()
            if zonesShown, !highlighted.isEmpty, let w = window, let i = activeIndex {
                engine.snap(w, to: highlighted, on: displays[i], originalSize: originalSize)
            }
        }
        endSession()
    }

    /// Dragging inside a MacToys window (Settings, the editor): never hit-test ourselves through
    /// Accessibility, which would block the main thread on its own reply.
    private static func isOverOwnWindow(_ p: CGPoint) -> Bool {
        let cocoa = ScreenGeometry.toCocoa(p)
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(cocoa) }
    }

    private func ignore() {
        phase = .ignored
        pump?.invalidate()
        pump = nil
    }

    private func endSession() {
        pump?.invalidate()
        pump = nil
        if zonesShown { engine.overlay.hide() }
        phase = .idle
        released = false
        zonesShown = false
        mouseToggled = false
        spanToggled = false
        wheelSteps = 0
        wheelAccumulator = 0
        ticks = 0
        window = nil
        originalSize = nil
        displays = []
        layouts = []
        displayZones = []
        activeIndex = nil
        renderedIndex = nil
        highlighted = []
        spanAnchor = nil
    }
}
