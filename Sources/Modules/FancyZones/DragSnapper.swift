import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Detects window drags and snaps the window into the zone under the pointer.
///
/// A drag is a left-button press followed by the window under the pointer changing position
/// (and not size) through Accessibility. For mouse moves the event-tap handler only copies a few
/// scalars; a 60 Hz timer running while the button is down does the Accessibility reads, hit
/// testing and drawing. On release the tap computes the target zones (pure geometry) and queues
/// the window move, so no Accessibility call ever runs inside the tap.
///
/// Zones show while the activation key is held (or always, without one). While they are hidden,
/// edge snap (when on) previews and snaps to a half, quarter or all of the display at its free
/// edges. Esc during the drag hides either and lets the window drop where it is. Displays Auto
/// Tiling arranges get neither.
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
    private var swallowEscapeUp = false
    /// Esc was pressed during this drag: nothing shows or snaps until the button is released.
    private var cancelled = false
    private var lastEvent: TimeInterval = 0
    // Settings snapshot taken when a drag starts, read by the tap handler.
    private var cfgNonPrimary = false
    private var cfgMiddleSpans = false
    private var cfgActivation = ActivationKey.shift
    private var wheelEnabled = false
    private var zonesShown = false
    /// The edge-snap preview on screen: screen index and region.
    private var edgeShown: (screen: Int, region: EdgeSnapRegion)?

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
    // Edge snap and Auto Tiling, fixed for the drag.
    private var edgeEnabled = false
    private var screens: [ScreenSlot] = []
    private var screenNeighbors: [[CGRect]] = []
    private var gate = AutoTilingGate.open

    init(engine: ZoneEngine) {
        self.engine = engine
    }

    var isDragging: Bool { phase == .dragging }

    func start() {
        InputTap.shared.add(Self.tapID, priority: 40,
                            events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                     .otherMouseDown, .otherMouseUp, .flagsChanged, .scrollWheel, .keyDown, .keyUp]) { [weak self] type, event in
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
        if zonesShown { engine.overlay.showLayoutName(layouts[i].displayName, on: displays[i], settings: engine.settings.value) }
        update()
    }

    // MARK: Tap (hot path: scalars only)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .leftMouseDown:
            if phase != .idle { release() }       // the previous release never reached us
            phase = .pressed
            pressLocation = event.location
            location = pressLocation
            flags = event.flags
            lastEvent = ProcessInfo.processInfo.systemUptime
            return .pass
        case .leftMouseDragged:
            guard phase == .pressed || phase == .candidate || phase == .dragging else { return .pass }
            location = event.location
            flags = event.flags
            lastEvent = ProcessInfo.processInfo.systemUptime
            if pump == nil { startPump() }
            return .pass
        case .leftMouseUp:
            guard phase != .idle else { return .pass }
            location = event.location
            flags = event.flags
            release()
            return .pass
        case .flagsChanged:
            if phase != .idle { flags = event.flags }
            return .pass
        case .keyDown:
            // Esc cancels a drag that shows zones or an edge preview; every other key, and Esc
            // at any other time, goes on to the apps.
            guard phase == .dragging, zonesShown || edgeShown != nil || cancelled,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else { return .pass }
            cancelled = true
            swallowEscapeUp = true
            return .consume
        case .keyUp:
            guard swallowEscapeUp, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else { return .pass }
            swallowEscapeUp = false
            return .consume
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
        cfgActivation = s.activation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer      // first tick runs outside the tap callback
    }

    private func tick() {
        ticks += 1
        // A release the tap never saw (it can be disabled while the main thread is busy) must
        // not leave zones on screen: end once the button is up and nothing arrived for a second.
        if ProcessInfo.processInfo.systemUptime - lastEvent > 1,
           !CGEventSource.buttonState(.hidSystemState, button: .left) {
            release()
            return
        }
        switch phase {
        case .pressed:
            guard !Self.isOverOwnWindow(location), let w = WindowRef.at(location), engine.isSnappable(w),
                  let f = w.frame else { ignore(); return }
            // An app that stops responding must not stall the drag for the 6 s default.
            AXUIElementSetMessagingTimeout(w.element, 0.25)
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
        screens = ScreenSlot.current
        screenNeighbors = screens.map { s in screens.map(\.frame).filter { $0 != s.frame } }
        gate = engine.autoTilingGate(screens: screens)
        edgeEnabled = s.edgeSnap
        if let record = engine.liveRecord(for: w, frame: startFrame) {
            originalSize = record.originalSize
            engine.forget(w)
            if s.restoreSizeOnUnsnap, record.originalSize != frame.size, frame.width > 0, !gate.blocks(pressLocation) {
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

    /// Whether zones are active: the activation key held (or, without one, ⇧ not held), flipped
    /// by the non-primary-button toggle; never after Esc or over a display Auto Tiling arranges.
    private var zonesActive: Bool {
        !cancelled && cfgActivation.zonesActive(flags: flags, toggled: mouseToggled) && !gate.blocks(location)
    }

    private func displayIndex(at p: CGPoint) -> Int? {
        displays.firstIndex { $0.frame.containsInclusive(p) }
            ?? displays.indices.min { displays[$0].frame.distance(to: p) < displays[$1].frame.distance(to: p) }
    }

    /// The display and zones under the pointer (nil while zones are inactive). Pure geometry,
    /// apart from tracking where a ⌘ span started.
    private func currentTarget() -> (display: Int, zones: [Int])? {
        guard !displays.isEmpty, zonesActive, let index = displayIndex(at: location) else { return nil }
        if index != activeIndex { activeIndex = index; spanAnchor = nil }
        let zones = displayZones[index]
        var hits = ZoneGeometry.zones(at: location, in: zones, distance: CGFloat(layouts[index].highlightDistance),
                                      algorithm: engine.settings.value.overlapAlgorithm)
        if flags.contains(.maskCommand) != spanToggled {
            if spanAnchor == nil && !hits.isEmpty { spanAnchor = hits }
            if let anchor = spanAnchor { hits = hits.isEmpty ? highlighted : ZoneGeometry.span(from: anchor, to: hits, in: zones) }
        } else {
            spanAnchor = nil
        }
        return (index, hits)
    }

    /// The edge-snap region under the pointer while zones are inactive. Pure geometry.
    private func currentEdge() -> (screen: Int, region: EdgeSnapRegion)? {
        guard edgeEnabled, !cancelled, !gate.blocks(location), !zonesActive,
              let i = screens.firstIndex(where: { $0.frame.contains(location) }),
              let region = EdgeSnap.region(at: location, display: screens[i].frame, others: screenNeighbors[i]) else { return nil }
        return (i, region)
    }

    /// Recomputes activation and highlight; redraws only when something changed.
    private func update() {
        guard !displays.isEmpty else { return }
        guard zonesActive else {
            if zonesShown { engine.overlay.hide(); zonesShown = false; highlighted = []; renderedIndex = nil }
            spanAnchor = nil
            updateEdgePreview()
            return
        }
        edgeShown = nil      // zones replace the edge preview on the same panels
        if wheelSteps != 0, let index = displayIndex(at: location) {
            let steps = wheelSteps
            wheelSteps = 0
            if let next = engine.library.value.cycled(from: layouts[index].id, steps: steps) {
                engine.apply(next, to: displays[index], announce: false)   // redraws through layoutChanged
                return
            }
        }
        guard let target = currentTarget() else { return }
        guard !zonesShown || target.zones != highlighted || renderedIndex != target.display else { return }
        highlighted = target.zones
        renderedIndex = target.display
        render(target.display, showAll: engine.settings.value.showZonesOnAllDisplays)
    }

    private func render(_ index: Int, showAll: Bool) {
        let layers = displays.indices.map { i in
            ZoneLayer(display: displays[i], zones: displayZones[i], highlighted: i == index ? Set(highlighted) : [])
        }
        let screen = NSScreen.screens.map(\.axFrame).first { $0.containsInclusive(location) }
        engine.overlay.show(layers, style: engine.style, onlyScreen: showAll ? nil : screen, excluding: gate.managed)
        zonesShown = true
    }

    /// Shows, moves or hides the edge-snap preview: the target drawn like a highlighted zone.
    private func updateEdgePreview() {
        let next = currentEdge()
        guard next?.screen != edgeShown?.screen || next?.region != edgeShown?.region else { return }
        edgeShown = next
        guard let next else { engine.overlay.hide(); return }
        let slot = screens[next.screen]
        let display = ZoneDisplay(key: "edge-snap", name: "", number: 0, frame: slot.frame, workArea: slot.workArea,
                                  isBuiltIn: false)
        var style = engine.style
        style.showNumbers = false
        engine.overlay.show([ZoneLayer(display: display, zones: [next.region.rect(in: slot.workArea)], highlighted: [0])],
                            style: style, onlyScreen: slot.frame)
    }

    /// Mouse released: snap to the zones under the pointer when zones are active. Runs inside the
    /// tap, so the window move itself is queued for right after.
    private func release() {
        if phase == .dragging, let w = window {
            let engine = self.engine, original = originalSize
            if let target = currentTarget(), !target.zones.isEmpty {
                let display = displays[target.display], zones = target.zones
                DispatchQueue.main.async { engine.snap(w, to: zones, on: display, originalSize: original) }
            } else if let edge = currentEdge(), let index = displayIndex(at: location) {
                let work = screens[edge.screen].workArea, key = displays[index].key
                DispatchQueue.main.async {
                    engine.snap(w, edge: edge.region, work: work, displayKey: key, originalSize: original)
                }
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
        if zonesShown || edgeShown != nil { engine.overlay.hide() }
        phase = .idle
        zonesShown = false
        edgeShown = nil
        cancelled = false
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
        edgeEnabled = false
        screens = []
        screenNeighbors = []
        gate = .open
    }
}
