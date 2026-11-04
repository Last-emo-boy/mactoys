import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import WindowGestures

// MARK: - Helpers

private func scroll(_ phase: GesturePhase, dx: CGFloat = 0, dy: CGFloat = 0, momentum: MomentumPhase = .none,
                    natural: Bool = true, continuous: Bool = true) -> ScrollSample {
    ScrollSample(phase: phase, momentum: momentum, delta: CGVector(dx: dx, dy: dy), isContinuous: continuous,
                 isInverted: natural)
}

/// A swipe of `steps` equal moves totalling (dx, dy) of finger travel (natural scrolling, so the
/// deltas are the finger travel).
private func swipe(dx: CGFloat, dy: CGFloat, steps: Int = 6) -> [ScrollSample] {
    [scroll(.began)] + (0..<steps).map { _ in scroll(.changed, dx: dx / CGFloat(steps), dy: dy / CGFloat(steps)) }
        + [scroll(.ended)]
}

private struct Run {
    var tracker = GestureTracker()
    var accepts = true
    var asked: [GestureKind] = []
    var effects: [GestureTracker.Effect] = []
    var consumed: [Bool] = []

    mutating func feed(_ samples: [ScrollSample]) {
        for s in samples {
            let accept = accepts
            var kinds: [GestureKind] = []
            let step = tracker.handle(s) { kind in kinds.append(kind); return accept }
            asked += kinds
            consumed.append(step.consume)
            if let e = step.effect { effects.append(e) }
        }
    }

    mutating func feed(_ gestures: [TrackpadGesture], at time: TimeInterval = 0) {
        for g in gestures {
            let accept = accepts
            var kinds: [GestureKind] = []
            let step = tracker.handle(g, at: time) { kind in kinds.append(kind); return accept }
            asked += kinds
            consumed.append(step.consume)
            if let e = step.effect { effects.append(e) }
        }
    }

    var lastStroke: Stroke? {
        for e in effects.reversed() {
            if case .swipeEnded(let s) = e { return s }
        }
        return nil
    }
}

// MARK: - Event decoding

@Suite struct GestureInputTests {
    @Test func phasesDecodeFromTheirBits() {
        #expect(GesturePhase(bits: 1) == .began)
        #expect(GesturePhase(bits: 2) == .changed)
        #expect(GesturePhase(bits: 4) == .ended)
        #expect(GesturePhase(bits: 8) == .cancelled)
        #expect(GesturePhase(bits: 128) == .mayBegin)
        #expect(GesturePhase(bits: 0) == .none)
        #expect(MomentumPhase(raw: 1) == .began)
        #expect(MomentumPhase(raw: 2) == .changed)
        #expect(MomentumPhase(raw: 3) == .ended)
        #expect(MomentumPhase(raw: 0) == .none)
    }

    @Test func scrollSampleReadsTheEvent() throws {
        let e = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -12)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 5)
        e.setIntegerValueField(GestureFields.scrollInverted, value: 1)
        let s = ScrollSample(e)
        #expect(s.phase == .changed)
        #expect(s.momentum == .none)
        #expect(s.isContinuous)
        #expect(s.isInverted)
        #expect(s.delta == CGVector(dx: 5, dy: -12))
        // AppKit reads the same fields.
        let ns = try #require(NSEvent(cgEvent: e))
        #expect(ns.phase == .changed)
        #expect(ns.isDirectionInvertedFromDevice)
        #expect(ns.hasPreciseScrollingDeltas)
    }

    @Test func momentumFieldMatchesAppKit() throws {
        let e = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        #expect(ScrollSample(e).momentum == .ended)
        #expect(NSEvent(cgEvent: e)?.momentumPhase == .ended)
    }

    @Test func magnifyEventsDecodeLikeAppKit() throws {
        let e = try #require(CGEvent(source: nil))
        e.type = GestureFields.gestureType
        e.setIntegerValueField(GestureFields.subtype, value: GestureFields.magnifySubtype)
        e.setDoubleValueField(GestureFields.magnification, value: -0.25)
        e.setIntegerValueField(GestureFields.phase, value: 1)
        #expect(TrackpadGesture(e) == .magnify(phase: .began, delta: -0.25))
        let ns = try #require(NSEvent(cgEvent: e))
        #expect(ns.type == .magnify)
        #expect(ns.magnification == -0.25)
        #expect(ns.phase == .began)
        e.setIntegerValueField(GestureFields.phase, value: 4)
        #expect(TrackpadGesture(e) == .magnify(phase: .ended, delta: -0.25))
        #expect(NSEvent(cgEvent: e)?.phase == .ended)
    }

    @Test func smartMagnifyIsTheDoubleTap() throws {
        let e = try #require(CGEvent(source: nil))
        e.type = GestureFields.gestureType
        e.setIntegerValueField(GestureFields.subtype, value: GestureFields.smartMagnifySubtype)
        #expect(TrackpadGesture(e) == .smartMagnify)
        #expect(NSEvent(cgEvent: e)?.type == .smartMagnify)
        e.setIntegerValueField(GestureFields.subtype, value: 5)      // rotation
        #expect(TrackpadGesture(e) == .other)
    }

    @Test func fingerDeltaFollowsTheFingersEitherWay() {
        // Natural scrolling: the deltas already point where the fingers went.
        #expect(scroll(.changed, dx: -10, dy: 4, natural: true).fingerDelta == CGVector(dx: -10, dy: 4))
        // Traditional scrolling: the same finger movement arrives flipped.
        #expect(scroll(.changed, dx: 10, dy: -4, natural: false).fingerDelta == CGVector(dx: -10, dy: 4))
    }
}

// MARK: - Recognizers

@Suite struct SwipeRecognizerTests {
    @Test func needsTheLockDistance() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: -20, dy: 2))
        #expect(r.stroke == nil)
        #expect(r.axis == nil)
        r.add(CGVector(dx: -12, dy: 0))
        #expect(r.stroke == Stroke(.left))
        #expect(r.axis == .horizontal)
    }

    @Test func eachDirection() {
        for (v, d) in [(CGVector(dx: 40, dy: 0), SwipeDirection.right), (CGVector(dx: -40, dy: 0), .left),
                       (CGVector(dx: 0, dy: -40), .up), (CGVector(dx: 0, dy: 40), .down)] {
            var r = SwipeRecognizer()
            r.add(v)
            #expect(r.stroke == Stroke(d))
        }
    }

    @Test func directionLocksOntoTheFirstAxis() {
        var r = SwipeRecognizer(allowsTurns: false)
        r.add(CGVector(dx: 40, dy: 0))
        #expect(r.axis == .horizontal)
        // Lots of vertical travel afterwards doesn't make it a vertical swipe.
        r.add(CGVector(dx: 0, dy: 200))
        #expect(r.axis == .horizontal)
        #expect(r.stroke == Stroke(.right))
    }

    @Test func nearlyDiagonalWaitsThenLocks() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: 32, dy: 30))       // ambiguous: no lock yet
        #expect(r.axis == nil)
        r.add(CGVector(dx: 12, dy: 2))        // 44 × 32, clearly horizontal now
        #expect(r.axis == .horizontal)
    }

    @Test func goingBackClearsAndPastTheStartFlips() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: -40, dy: 0))
        #expect(r.stroke == Stroke(.left))
        r.add(CGVector(dx: 30, dy: 0))        // back to -10: under half the lock distance
        #expect(r.stroke == nil)
        r.add(CGVector(dx: 45, dy: 0))        // +35
        #expect(r.stroke == Stroke(.right))
    }

    @Test func hysteresisKeepsAShownStroke() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: -32, dy: 0))
        #expect(r.stroke == Stroke(.left))
        r.add(CGVector(dx: 14, dy: 0))        // -18: still past half the lock distance
        #expect(r.stroke == Stroke(.left))
    }

    @Test func sidewaysTravelTurnsTowardACorner() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: 50, dy: 0))
        r.add(CGVector(dx: 0, dy: -70))
        #expect(r.stroke == Stroke(.right, turn: .up))
        #expect(r.stroke?.horizontal == .right)
        #expect(r.stroke?.vertical == .up)
        var v = SwipeRecognizer()
        v.add(CGVector(dx: 0, dy: 60))
        v.add(CGVector(dx: -80, dy: 0))
        #expect(v.stroke == Stroke(.down, turn: .left))
    }

    @Test func longSlightlyDriftingSwipeStaysStraight() {
        var r = SwipeRecognizer()
        r.add(CGVector(dx: -300, dy: 70))     // 70 sideways is under 30 % of 300
        #expect(r.stroke == Stroke(.left))
    }

    @Test func turnsCanBeOff() {
        var r = SwipeRecognizer(allowsTurns: false)
        r.add(CGVector(dx: 50, dy: 0))
        r.add(CGVector(dx: 0, dy: -100))
        #expect(r.stroke == Stroke(.right))
    }

    @Test func sensitivityScalesTheDistances() {
        let quick = SwipeThresholds(sensitivity: 2), gentle = SwipeThresholds(sensitivity: 0.5)
        #expect(quick.lock == 15 && quick.turn == 30)
        #expect(gentle.lock == 60 && gentle.turn == 120)
        #expect(SwipeThresholds(sensitivity: 100).lock == SwipeThresholds(sensitivity: 4).lock)
        var r = SwipeRecognizer(thresholds: quick)
        r.add(CGVector(dx: 16, dy: 0))
        #expect(r.stroke == Stroke(.right))
    }

    @Test func addReportsChangesOnly() {
        var r = SwipeRecognizer()
        let first = r.add(CGVector(dx: 10, dy: 0))
        let second = r.add(CGVector(dx: 25, dy: 0))
        let third = r.add(CGVector(dx: 25, dy: 0))
        #expect(!first && second && !third)
    }
}

@Suite struct PinchRecognizerTests {
    @Test func pinchInAndOut() {
        var r = PinchRecognizer()
        r.add(-0.1, at: 0)
        #expect(r.intent == nil)
        r.add(-0.1, at: 0.1)
        #expect(r.intent == .pinchIn)
        #expect(r.armedAt == 0.1)
        r.add(0.5, at: 0.2)
        #expect(r.intent == .pinchOut)
        #expect(r.armedAt == nil)
    }

    @Test func hysteresisKeepsThePinchIn() {
        var r = PinchRecognizer()
        r.add(-0.2, at: 0)
        r.add(0.07, at: 0.1)                  // -0.13: above -0.18, still past 60 %
        #expect(r.intent == .pinchIn)
        r.add(0.06, at: 0.2)                  // -0.07
        #expect(r.intent == nil)
    }

    @Test func holdProgress() {
        var r = PinchRecognizer()
        #expect(r.holdProgress(at: 5, hold: 0.6) == 0)
        r.add(-0.3, at: 1)
        #expect(abs(r.holdProgress(at: 1.3, hold: 0.6) - 0.5) < 1e-9)
        #expect(r.holdProgress(at: 2, hold: 0.6) == 1)
        #expect(r.holdProgress(at: 1, hold: 0) == 1)
    }

    @Test func sensitivity() {
        #expect(PinchRecognizer(sensitivity: 2).threshold == PinchRecognizer.baseThreshold / 2)
    }
}

// MARK: - Tracker state machine

@Suite struct GestureTrackerTests {
    @Test func takenSwipeIsConsumedWithItsMomentum() {
        var run = Run()
        run.feed(swipe(dx: -60, dy: 0))
        run.feed([scroll(.none, dx: -8, momentum: .began), scroll(.none, dx: -4, momentum: .changed),
                  scroll(.none, momentum: .ended)])
        #expect(run.consumed.allSatisfy { $0 })
        #expect(run.asked == [.swipe])
        #expect(run.effects.first == .swipeBegan)
        #expect(run.effects.contains(.strokeChanged(Stroke(.left))))
        #expect(run.lastStroke == Stroke(.left))
        // The next scroll starts fresh.
        run.accepts = false
        run.feed([scroll(.began, dy: 5)])
        #expect(run.consumed.last == false)
    }

    @Test func settingsChangedWhileCoastingKeepTheMomentumAndApplyToTheNextSwipe() {
        var run = Run()
        run.feed(swipe(dx: -60, dy: 0))
        // The settings change while the window coasts: what the controller does in refreshConfig.
        run.tracker.reversed = true
        run.tracker.allowsTurns = false
        run.feed([scroll(.none, dx: -8, momentum: .began), scroll(.none, momentum: .ended)])
        #expect(run.consumed.allSatisfy { $0 })
        run.feed(swipe(dx: -60, dy: 0))
        #expect(run.lastStroke == Stroke(.right))
    }

    @Test func swipesThatBeginElsewherePassUntouched() {
        var run = Run()
        run.accepts = false
        run.feed(swipe(dx: -60, dy: 0))
        run.feed([scroll(.none, dx: -8, momentum: .began), scroll(.none, momentum: .ended)])
        #expect(run.consumed.allSatisfy { !$0 })
        #expect(run.effects.isEmpty)
        #expect(run.asked == [.swipe])        // asked once, at the start
    }

    @Test func movingOntoATitleBarMidScrollDoesNothing() {
        var run = Run()
        run.accepts = false
        run.feed([scroll(.began), scroll(.changed, dy: 10)])
        run.accepts = true                    // pointer is now over a title bar
        run.feed([scroll(.changed, dx: -80), scroll(.ended)])
        #expect(run.consumed.allSatisfy { !$0 })
        #expect(run.effects.isEmpty)
    }

    @Test func wheelsAlwaysPass() {
        var run = Run()
        run.feed([scroll(.none, dy: 3, continuous: false), scroll(.began, dy: 3, continuous: false)])
        #expect(run.consumed == [false, false])
        #expect(run.asked.isEmpty)
    }

    @Test func touchingWithoutMovingPasses() {
        var run = Run()
        run.feed([scroll(.mayBegin), scroll(.cancelled)])
        #expect(run.consumed == [false, false])
        #expect(run.asked.isEmpty)
        #expect(run.effects.isEmpty)
    }

    @Test func shortSwipeEndsWithNoStroke() {
        var run = Run()
        run.feed(swipe(dx: 12, dy: 0))
        #expect(run.consumed.allSatisfy { $0 })
        #expect(run.effects.contains(.swipeEnded(nil)))
    }

    @Test func cancelledSwipe() {
        var run = Run()
        run.feed([scroll(.began), scroll(.changed, dx: 50), scroll(.cancelled)])
        #expect(run.effects.last == .swipeCancelled)
        #expect(!run.tracker.isTracking)
    }

    @Test func traditionalScrollingKeepsDirections() {
        var run = Run()
        // Fingers move left; with natural scrolling off the deltas point right.
        run.feed([scroll(.began, natural: false)] + (0..<5).map { _ in scroll(.changed, dx: 12, natural: false) }
                 + [scroll(.ended, natural: false)])
        #expect(run.lastStroke == Stroke(.left))
    }

    @Test func reversedSetting() {
        var run = Run(tracker: GestureTracker(reversed: true))
        run.feed(swipe(dx: -60, dy: 0))
        #expect(run.lastStroke == Stroke(.right))
    }

    @Test func cornerStrokeArrivesBeforeTheFingersLift() {
        var run = Run()
        run.feed([scroll(.began), scroll(.changed, dx: 50)])
        #expect(run.effects.last == .strokeChanged(Stroke(.right)))
        run.feed([scroll(.changed, dy: -40), scroll(.changed, dy: -40)])
        #expect(run.effects.last == .strokeChanged(Stroke(.right, turn: .up)))
        run.feed([scroll(.ended)])
        #expect(run.lastStroke == Stroke(.right, turn: .up))
    }

    @Test func pinchOnATitleBar() {
        var run = Run()
        run.feed([.magnify(phase: .began, delta: -0.05), .magnify(phase: .changed, delta: -0.1),
                  .magnify(phase: .changed, delta: -0.1), .magnify(phase: .ended, delta: 0)])
        #expect(run.asked == [.pinch])
        #expect(run.consumed.allSatisfy { $0 })
        #expect(run.effects == [.pinchBegan, .pinchChanged(.pinchIn), .pinchEnded(.pinchIn)])
    }

    @Test func pinchElsewherePasses() {
        var run = Run()
        run.accepts = false
        run.feed([.magnify(phase: .began, delta: 0.1), .magnify(phase: .changed, delta: 0.3),
                  .magnify(phase: .ended, delta: 0)])
        #expect(run.consumed.allSatisfy { !$0 })
        #expect(run.effects.isEmpty)
    }

    @Test func otherGestureEventsPass() {
        var run = Run()
        run.feed([.other, .other])
        #expect(run.consumed == [false, false])
        #expect(run.asked.isEmpty)
    }

    @Test func swipeThatTurnsIntoAPinchIsSwallowed() {
        var run = Run()
        run.feed([scroll(.began), scroll(.changed, dx: -50)])
        run.feed([.magnify(phase: .began, delta: 0.05)])
        run.feed([scroll(.changed, dx: -50), scroll(.ended)])
        run.feed([scroll(.none, momentum: .began), scroll(.none, momentum: .ended)])
        #expect(run.consumed.allSatisfy { $0 })
        #expect(!run.effects.contains { if case .swipeEnded = $0 { return true } else { return false } })
    }

    @Test func noSwipeStartsDuringAPinch() {
        var run = Run()
        run.feed([.magnify(phase: .began, delta: -0.05)])
        run.feed([scroll(.began), scroll(.changed, dx: 60)])
        #expect(run.consumed[1] == false)
    }

    @Test func doubleTap() {
        var run = Run()
        run.feed([.smartMagnify])
        #expect(run.effects == [.doubleTap])
        #expect(run.consumed == [true])
        run.accepts = false
        run.feed([.smartMagnify])
        #expect(run.consumed.last == false)
        #expect(run.asked == [.doubleTap, .doubleTap])
    }

    @Test func expireCancelsWhatIsInProgress() {
        var t = GestureTracker()
        _ = t.handle(scroll(.began)) { _ in true }
        #expect(t.isTracking)
        #expect(t.expire() == .swipeCancelled)
        #expect(!t.isTracking)
        #expect(t.expire() == nil)
        _ = t.handle(.magnify(phase: .began, delta: 0), at: 0) { _ in true }
        #expect(t.expire() == .pinchCancelled)
    }

    @Test func aNewSwipeInterruptsAnUnfinishedOne() {
        var run = Run()
        run.feed([scroll(.began), scroll(.changed, dx: -50)])
        run.accepts = false
        run.feed([scroll(.began)])            // the end never arrived; this one began elsewhere
        #expect(run.effects.last == .swipeCancelled)
        #expect(run.consumed.last == false)
    }
}

// MARK: - Hit testing

@Suite struct SurfaceHitTestTests {
    static let own: pid_t = 100, dock: pid_t = 200, app: pid_t = 300, other: pid_t = 400
    static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let strip = CGRect(x: 0, y: 0, width: 1440, height: 25)

    static let window = WindowEntry(id: 1, pid: app, layer: 0, frame: CGRect(x: 200, y: 100, width: 800, height: 600))

    func context(menuBar: CGRect? = strip, skipFullScreen: Bool = true) -> SurfaceHitTest.Context {
        SurfaceHitTest.Context(ownPID: Self.own, dockPID: Self.dock, displays: [Self.display], menuBar: menuBar,
                               skipFullScreen: skipFullScreen)
    }

    func hit(_ p: CGPoint, _ entries: [WindowEntry], band: CGFloat = 32, context c: SurfaceHitTest.Context? = nil,
             asked: UnsafeMutablePointer<Int>? = nil) -> GestureSurface {
        SurfaceHitTest.surface(at: p, entries: entries, context: c ?? context()) { _ in
            asked?.pointee += 1
            return band
        }
    }

    @Test func titleBarBandOnly() {
        #expect(hit(CGPoint(x: 500, y: 110), [Self.window]) == .titleBar(Self.window, fullScreen: false))
        #expect(hit(CGPoint(x: 500, y: 131), [Self.window]) == .titleBar(Self.window, fullScreen: false))
        #expect(hit(CGPoint(x: 500, y: 133), [Self.window]) == .none)       // content
        #expect(hit(CGPoint(x: 500, y: 150), [Self.window], band: 52) == .titleBar(Self.window, fullScreen: false))
    }

    @Test func deepPointsNeverAskForTheBand() {
        var asked = 0
        _ = withUnsafeMutablePointer(to: &asked) { hit(CGPoint(x: 500, y: 400), [Self.window], asked: $0) }
        #expect(asked == 0)
        _ = withUnsafeMutablePointer(to: &asked) { hit(CGPoint(x: 500, y: 120), [Self.window], asked: $0) }
        #expect(asked == 1)
    }

    @Test func theFrontWindowDecides() {
        // A window in front covers the back window's title bar with its content.
        let front = WindowEntry(id: 2, pid: Self.other, layer: 0, frame: CGRect(x: 400, y: 60, width: 500, height: 400))
        #expect(hit(CGPoint(x: 500, y: 110), [front, Self.window]) == .none)
        // Its own title bar is a title bar.
        #expect(hit(CGPoint(x: 500, y: 70), [front, Self.window]) == .titleBar(front, fullScreen: false))
    }

    @Test func otherAppsFloatingWindowsBlock() {
        let palette = WindowEntry(id: 3, pid: Self.other, layer: 3, frame: CGRect(x: 450, y: 90, width: 200, height: 300))
        #expect(hit(CGPoint(x: 500, y: 110), [palette, Self.window]) == .none)
        let menu = WindowEntry(id: 4, pid: Self.app, layer: 101, frame: CGRect(x: 450, y: 90, width: 200, height: 300))
        #expect(hit(CGPoint(x: 500, y: 110), [menu, Self.window]) == .none)
    }

    @Test func ownOverlaysAreLookedThroughButOwnWindowsAreNot() {
        let overlay = WindowEntry(id: 5, pid: Self.own, layer: 3, frame: Self.display)
        #expect(hit(CGPoint(x: 500, y: 110), [overlay, Self.window]) == .titleBar(Self.window, fullScreen: false))
        let settings = WindowEntry(id: 6, pid: Self.own, layer: 0, frame: CGRect(x: 300, y: 100, width: 600, height: 400))
        #expect(hit(CGPoint(x: 500, y: 110), [settings, Self.window]) == .none)
    }

    @Test func invisibleWindowsAreSkipped() {
        var ghost = WindowEntry(id: 7, pid: Self.other, layer: 0, frame: Self.display)
        ghost.alpha = 0
        #expect(hit(CGPoint(x: 500, y: 110), [ghost, Self.window]) == .titleBar(Self.window, fullScreen: false))
    }

    @Test func dock() {
        let dockWindow = WindowEntry(id: 8, pid: Self.dock, layer: SurfaceHitTest.dockLevel,
                                     frame: CGRect(x: 400, y: 820, width: 640, height: 80))
        #expect(hit(CGPoint(x: 600, y: 860), [dockWindow]) == .dock(dockWindow))
        // Dock gestures off: the Dock isn't recognized.
        var c = context()
        c.dockPID = nil
        #expect(hit(CGPoint(x: 600, y: 860), [dockWindow], context: c) == .none)
    }

    @Test func menuBar() {
        let menuWindow = WindowEntry(id: 9, pid: Self.other, layer: SurfaceHitTest.menuBarLevel, frame: Self.strip)
        let status = WindowEntry(id: 10, pid: Self.other, layer: SurfaceHitTest.statusLevel,
                                 frame: CGRect(x: 1300, y: 0, width: 30, height: 25))
        #expect(hit(CGPoint(x: 300, y: 10), [menuWindow, Self.window]) == .menuBar)
        #expect(hit(CGPoint(x: 1310, y: 10), [status, menuWindow]) == .menuBar)
        #expect(hit(CGPoint(x: 300, y: 10), [], context: context(menuBar: nil)) == .none)
        #expect(hit(CGPoint(x: 300, y: 50), []) == .none)          // the desktop
    }

    @Test func fullScreenWindows() {
        let full = WindowEntry(id: 11, pid: Self.app, layer: 0, frame: Self.display)
        #expect(hit(CGPoint(x: 300, y: 10), [full]) == .none)
        #expect(hit(CGPoint(x: 300, y: 10), [full], context: context(skipFullScreen: false)) == .titleBar(full, fullScreen: true))
    }

    @Test func bandFromTheCloseButton() {
        let w = CGRect(x: 100, y: 200, width: 800, height: 600)
        // A plain title bar: buttons centered 14 pt down.
        #expect(SurfaceHitTest.band(window: w, closeButton: CGRect(x: 108, y: 207, width: 14, height: 14)) == 28)
        // A unified toolbar: centered 26 pt down.
        #expect(SurfaceHitTest.band(window: w, closeButton: CGRect(x: 120, y: 219, width: 14, height: 14)) == 52)
        #expect(SurfaceHitTest.band(window: w, closeButton: nil) == nil)
        #expect(SurfaceHitTest.band(window: w, closeButton: CGRect(x: 120, y: 500, width: 14, height: 14)) == nil)
        #expect(SurfaceHitTest.band(window: w, closeButton: CGRect(x: 108, y: 201, width: 4, height: 4)) == 22)
    }

    @Test func menuBarStrip() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Notched display: the menu bar is as tall as the camera housing.
        #expect(SurfaceHitTest.menuBarStrip(frame: frame, work: CGRect(x: 0, y: 38, width: 1512, height: 944), safeTop: 38).height == 38)
        // Menu bar hidden: the visible frame reaches the top; fall back to the housing or 24 pt.
        #expect(SurfaceHitTest.menuBarStrip(frame: frame, work: frame, safeTop: 38).height == 38)
        #expect(SurfaceHitTest.menuBarStrip(frame: frame, work: frame, safeTop: 0).height == 24)
        // A display to the left of the primary one.
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let strip = SurfaceHitTest.menuBarStrip(frame: left, work: CGRect(x: -1920, y: -175, width: 1920, height: 1055), safeTop: 0)
        #expect(strip == CGRect(x: -1920, y: -200, width: 1920, height: 25))
    }
}

// MARK: - Tile geometry

@Suite struct TileGridTests {
    /// 1440 × 900 with a 25 pt menu bar and a 75 pt Dock.
    static let laptop = CGRect(x: 0, y: 25, width: 1440, height: 800)
    /// Notched 14" display: 38 pt menu bar, odd width.
    static let notch = CGRect(x: 0, y: 38, width: 1511, height: 944)
    /// Portrait display above and to the left of the primary one.
    static let portrait = CGRect(x: -1080, y: -1200, width: 1080, height: 1895)

    @Test func halves() {
        #expect(Tile.half(.left).frame(in: Self.laptop) == CGRect(x: 0, y: 25, width: 720, height: 800))
        #expect(Tile.half(.right).frame(in: Self.laptop) == CGRect(x: 720, y: 25, width: 720, height: 800))
        #expect(Tile.fill.frame(in: Self.notch) == Self.notch)
    }

    @Test func thirdsOnAnOddWidthShareEdges() {
        let thirds = (0..<3).map { Tile(columns: 3, column: $0).frame(in: Self.notch) }
        #expect(thirds[0].minX == 0)
        #expect(thirds[0].maxX == thirds[1].minX)
        #expect(thirds[1].maxX == thirds[2].minX)
        #expect(thirds[2].maxX == Self.notch.maxX)
        #expect(thirds.allSatisfy { $0.minY == 38 && $0.height == 944 })
        #expect(thirds.allSatisfy { abs($0.width - 1511.0 / 3) <= 1 })
        let twoThirds = Tile(columns: 3, column: 1, columnSpan: 2).frame(in: Self.notch)
        #expect(twoThirds.minX == thirds[1].minX && twoThirds.maxX == thirds[2].maxX)
    }

    @Test func quartersAndSixthsTileTheArea() {
        for (columns, area) in [(2, Self.laptop), (3, Self.notch), (2, Self.portrait), (3, Self.portrait)] {
            var cells: [CGRect] = []
            for r in 0..<2 { for c in 0..<columns { cells.append(Tile(columns: columns, rows: 2, column: c, row: r).frame(in: area)) } }
            let union = cells.reduce(CGRect.null) { $0.union($1) }
            #expect(union == area)
            #expect(cells.reduce(0) { $0 + $1.area } == area.area)          // no overlap, no gaps
        }
    }

    @Test func portraitDisplayWithNegativeCoordinates() {
        let q = Tile.quarter(.right, top: false).frame(in: Self.portrait)
        #expect(q == CGRect(x: -540, y: -253, width: 540, height: 948))
        let topSixth = Tile(columns: 3, rows: 2, column: 0, row: 0).frame(in: Self.portrait)
        #expect(topSixth == CGRect(x: -1080, y: -1200, width: 360, height: 947))
    }

    @Test func gapsKeepSpaceBetweenAndAround() {
        let gap: CGFloat = 10
        let left = Tile.half(.left).frame(in: Self.laptop, gap: gap)
        let right = Tile.half(.right).frame(in: Self.laptop, gap: gap)
        #expect(left == CGRect(x: 10, y: 35, width: 705, height: 780))
        #expect(right.minX - left.maxX == gap)
        #expect(Self.laptop.maxX - right.maxX == gap)
        #expect(Tile.fill.frame(in: Self.laptop, gap: gap) == Self.laptop.insetBy(dx: 10, dy: 10))
    }

    @Test func cells() {
        #expect(Tile.fill.cells(in: Self.laptop).isEmpty)
        #expect(Tile.half(.left).cells(in: Self.laptop).count == 2)
        #expect(Tile(columns: 3, rows: 2, column: 0).cells(in: Self.laptop).count == 6)
    }

    @Test func widthCycle() {
        let half = Tile.half(.left)
        let third = half.cycled(toward: .left)
        #expect(third == Tile(columns: 3, column: 0))
        let twoThirds = third.cycled(toward: .left)
        #expect(twoThirds == Tile(columns: 3, column: 0, columnSpan: 2))
        #expect(twoThirds.cycled(toward: .left) == half)
        #expect(Tile.half(.right).cycled(toward: .right) == Tile(columns: 3, column: 2))
        #expect(Tile(columns: 3, column: 2).cycled(toward: .right) == Tile(columns: 3, column: 1, columnSpan: 2))
        // Rows are kept: a top-left quarter cycles through the top row.
        #expect(Tile.quarter(.left, top: true).cycled(toward: .left) == Tile(columns: 3, rows: 2, column: 0, row: 0))
    }

    @Test func slide() {
        #expect(Tile(columns: 3, column: 0).slid(toward: .right) == Tile(columns: 3, column: 1))
        #expect(Tile(columns: 3, column: 1).slid(toward: .right) == Tile(columns: 3, column: 2))
        #expect(Tile(columns: 3, column: 2).slid(toward: .right) == nil)
        #expect(Tile.half(.right).slid(toward: .left) == Tile.half(.left))
    }

    @Test func clampsOutOfRangeValues() {
        let t = Tile(columns: 3, column: 5, columnSpan: 9, row: 3, rowSpan: 4)
        #expect(t.column == 2 && t.columnSpan == 1 && t.row == 0 && t.rowSpan == 1)
    }

    @Test func titles() {
        #expect(Tile.half(.left).title == "Left Half")
        #expect(Tile.quarter(.right, top: false).title == "Bottom Right Quarter")
        #expect(Tile(columns: 3, column: 1).title == "Center Third")
        #expect(Tile(columns: 3, column: 1, columnSpan: 2).title == "Right Two Thirds")
        #expect(Tile(columns: 3, rows: 2, column: 1, row: 1).title == "Bottom Center Sixth")
        #expect(Tile.fill.title == "Fill")
        #expect(Tile(columns: 3, column: 0, columnSpan: 2).fraction == "⅔")
        #expect(Tile.half(.right).fraction == "½")
        #expect(Tile.quarter(.left, top: true).fraction == "¼")
        #expect(Tile(columns: 3, rows: 2, column: 2, row: 1).fraction == "⅙")
        #expect(Tile(columns: 3, rows: 2, column: 0, columnSpan: 2, row: 0).fraction == "⅓")
        #expect(Tile.fill.fraction == "1")
    }
}

// MARK: - Gesture → action

@Suite struct GestureResolverTests {
    static let laptop = DisplaySlot(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    work: CGRect(x: 0, y: 25, width: 1440, height: 800))
    static let external = DisplaySlot(id: 2, frame: CGRect(x: 1440, y: -180, width: 2560, height: 1440),
                                      work: CGRect(x: 1440, y: -155, width: 2560, height: 1415))
    static let floating = CGRect(x: 300, y: 120, width: 800, height: 600)
    let options = GestureOptions()

    func window(_ frame: CGRect = floating, tile: Tile? = nil, original: CGRect? = nil, display: Int = 0,
                fullScreen: Bool = false) -> WindowContext {
        WindowContext(frame: frame, tile: tile, original: original, display: display,
                      displays: [Self.laptop, Self.external], isFullScreen: fullScreen)
    }

    @Test func swipeToHalves() {
        #expect(GestureResolver.swipe(Stroke(.left), window: window(), options: options)
                == .tile(.half(.left), frame: CGRect(x: 0, y: 25, width: 720, height: 800)))
        #expect(GestureResolver.swipe(Stroke(.right), window: window(display: 1), options: options)
                == .tile(.half(.right), frame: CGRect(x: 2720, y: -155, width: 1280, height: 1415)))
    }

    @Test func swipeAgainCyclesAndTheOtherWaySlides() {
        let third = Tile(columns: 3, column: 0)
        #expect(GestureResolver.swipe(Stroke(.left), window: window(tile: .half(.left)), options: options)?.tile == third)
        #expect(GestureResolver.swipe(Stroke(.right), window: window(tile: third), options: options)?.tile == Tile(columns: 3, column: 1))
        #expect(GestureResolver.swipe(Stroke(.right), window: window(tile: .half(.left)), options: options)?.tile == .half(.right))
        var noCycle = options
        noCycle.cycleSizes = false
        #expect(GestureResolver.swipe(Stroke(.left), window: window(tile: .half(.left)), options: noCycle)?.tile == .half(.left))
        // A filled window starts over at a half.
        #expect(GestureResolver.swipe(Stroke(.left), window: window(tile: .fill), options: options)?.tile == .half(.left))
    }

    @Test func cornersAndSixths() {
        let topRight = Tile.quarter(.right, top: true)
        #expect(GestureResolver.swipe(Stroke(.right, turn: .up), window: window(), options: options)
                == .tile(topRight, frame: CGRect(x: 720, y: 25, width: 720, height: 400)))
        #expect(GestureResolver.swipe(Stroke(.up, turn: .right), window: window(), options: options)?.tile == topRight)
        #expect(GestureResolver.swipe(Stroke(.right, turn: .up), window: window(tile: topRight), options: options)?.tile
                == Tile(columns: 3, rows: 2, column: 2, row: 0))
        // A bottom corner swipe on a top quarter starts over in the bottom row.
        #expect(GestureResolver.swipe(Stroke(.right, turn: .down), window: window(tile: topRight), options: options)?.tile
                == .quarter(.right, top: false))
        var noCorners = options
        noCorners.corners = false
        #expect(GestureResolver.swipe(Stroke(.right, turn: .up), window: window(), options: noCorners)?.tile == .half(.right))
    }

    @Test func swipeUp() {
        #expect(GestureResolver.swipe(Stroke(.up), window: window(), options: options)
                == .tile(.fill, frame: Self.laptop.work))
        var full = options
        full.up = .fullScreen
        #expect(GestureResolver.swipe(Stroke(.up), window: window(), options: full) == .enterFullScreen)
        full.up = .nothing
        #expect(GestureResolver.swipe(Stroke(.up), window: window(), options: full) == nil)
    }

    @Test func swipeDownRestoresThenMinimizes() {
        let tiled = window(Tile.half(.left).frame(in: Self.laptop.work), tile: .half(.left), original: Self.floating)
        #expect(GestureResolver.swipe(Stroke(.down), window: tiled, options: options) == .restore(frame: Self.floating))
        #expect(GestureResolver.swipe(Stroke(.down), window: window(), options: options) == .minimize)
        var minimize = options
        minimize.down = .minimize
        #expect(GestureResolver.swipe(Stroke(.down), window: tiled, options: minimize) == .minimize)
    }

    @Test func restoreAnOffscreenOriginalOntoTheDisplay() {
        let lost = CGRect(x: 5000, y: 3000, width: 900, height: 700)
        let tiled = window(tile: .half(.left), original: lost)
        #expect(GestureResolver.swipe(Stroke(.down), window: tiled, options: options)
                == .restore(frame: CGRect(x: 270, y: 75, width: 900, height: 700)))
    }

    @Test func pinches() {
        #expect(GestureResolver.pinch(.pinchIn, window: window(), options: options) == .close)
        #expect(GestureResolver.pinch(.pinchOut, window: window(), options: options) == .tile(.fill, frame: Self.laptop.work))
        var o = options
        o.pinchIn = .quitApp
        o.pinchOut = .fullScreen
        #expect(GestureResolver.pinch(.pinchIn, window: window(), options: o) == .quit)
        #expect(GestureResolver.pinch(.pinchOut, window: window(), options: o) == .enterFullScreen)
        #expect(GestureResolver.pinch(.pinchOut, window: window(fullScreen: true), options: o) == nil)
        #expect(WindowAction.close.isDestructive && WindowAction.quit.isDestructive && !WindowAction.minimize.isDestructive)
    }

    @Test func doubleTapToggles() {
        #expect(GestureResolver.doubleTap(window: window(), options: options) == .tile(.fill, frame: Self.laptop.work))
        let filled = window(Self.laptop.work, tile: .fill, original: Self.floating)
        #expect(GestureResolver.doubleTap(window: filled, options: options) == .restore(frame: Self.floating))
        #expect(GestureResolver.doubleTap(window: window(fullScreen: true), options: options) == .exitFullScreen)
        var fs = options
        fs.doubleTap = .toggleFullScreen
        #expect(GestureResolver.doubleTap(window: window(), options: fs) == .enterFullScreen)
    }

    @Test func fullScreenWindowsOnlyLeave() {
        let fs = window(Self.laptop.frame, fullScreen: true)
        #expect(GestureResolver.swipe(Stroke(.down), window: fs, options: options) == .exitFullScreen)
        #expect(GestureResolver.swipe(Stroke(.left), window: fs, options: options) == nil)
    }

    @Test func moveToAnotherDisplayKeepsTheTile() {
        let tiled = window(Tile.half(.left).frame(in: Self.laptop.work), tile: .half(.left), original: Self.floating)
        #expect(GestureResolver.swipe(Stroke(.right), toDisplay: true, window: tiled, options: options)
                == .moveToDisplay(1, frame: CGRect(x: 1440, y: -155, width: 1280, height: 1415), tile: .half(.left)))
        // Untiled: same size, same relative place.
        guard case let .moveToDisplay(i, frame, tile)? = GestureResolver.swipe(Stroke(.right), toDisplay: true, window: window(),
                                                                                options: options) else {
            Issue.record("expected a move")
            return
        }
        #expect(i == 1 && tile == nil && frame.size == Self.floating.size)
        #expect(Self.external.work.contains(frame))
    }

    @Test func gapIsApplied() {
        var o = options
        o.gap = 8
        #expect(GestureResolver.swipe(Stroke(.left), window: window(), options: o)?.targetFrame
                == CGRect(x: 8, y: 33, width: 708, height: 784))
    }
}

extension WindowAction {
    fileprivate var tile: Tile? {
        if case .tile(let t, _) = self { return t }
        return nil
    }
}

// MARK: - Displays

@Suite struct DisplayMapTests {
    static let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let right = CGRect(x: 1440, y: -180, width: 2560, height: 1440)
    static let above = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
    static let left = CGRect(x: -1080, y: -500, width: 1080, height: 1920)

    @Test func neighbors() {
        let frames = [Self.main, Self.right, Self.above, Self.left]
        #expect(DisplayMap.neighbor(of: 0, toward: .right, in: frames) == 1)
        #expect(DisplayMap.neighbor(of: 0, toward: .up, in: frames) == 2)
        #expect(DisplayMap.neighbor(of: 0, toward: .left, in: frames) == 3)
        #expect(DisplayMap.neighbor(of: 1, toward: .left, in: frames) == 0)
    }

    @Test func wrapsAroundToTheFarthest() {
        let frames = [Self.left, Self.main, Self.right]
        #expect(DisplayMap.neighbor(of: 2, toward: .right, in: frames) == 0)
        #expect(DisplayMap.neighbor(of: 0, toward: .left, in: frames) == 2)
        // Two displays: every direction reaches the other one.
        #expect(DisplayMap.neighbor(of: 0, toward: .down, in: [Self.main, Self.right]) == 1)
        #expect(DisplayMap.neighbor(of: 0, toward: .left, in: [Self.main]) == nil)
    }

    @Test func remapKeepsRelativePlaceAndShrinksToFit() {
        let from = CGRect(x: 0, y: 25, width: 1440, height: 800)
        let to = CGRect(x: 1440, y: -155, width: 2560, height: 1415)
        let centered = CGRect(x: 320, y: 125, width: 800, height: 600)
        let moved = DisplayMap.remap(centered, from: from, to: to)
        #expect(moved.size == centered.size)
        #expect(abs(moved.midX - to.midX) <= 1 && abs(moved.midY - to.midY) <= 1)
        let huge = CGRect(x: 0, y: -155, width: 2560, height: 1415)
        #expect(DisplayMap.remap(huge, from: to, to: from) == from)
    }

    @Test func restoredStaysWhereItWasWhenVisible() {
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(DisplayMap.restored(original, displays: [Self.main], work: Self.main) == original)
    }
}

// MARK: - Dock, URL names, catalog, settings

@Suite struct WindowGesturesMiscTests {
    @Test func dockEdgeAndIntents() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(DockEdge.of(dock: CGRect(x: 400, y: 820, width: 640, height: 80), screen: screen) == .bottom)
        #expect(DockEdge.of(dock: CGRect(x: 0, y: 200, width: 80, height: 500), screen: screen) == .left)
        #expect(DockEdge.of(dock: CGRect(x: 1360, y: 200, width: 80, height: 500), screen: screen) == .right)
        #expect(DockEdge.bottom.intent(for: .up) == .show)
        #expect(DockEdge.bottom.intent(for: .down) == .hide)
        #expect(DockEdge.bottom.intent(for: .left) == nil)
        #expect(DockEdge.left.intent(for: .right) == .show)
        #expect(DockEdge.left.intent(for: .left) == .hide)
        #expect(DockEdge.right.intent(for: .left) == .show)
    }

    @Test func namedGestures() {
        #expect(NamedGesture("swipe-left") == .swipe(Stroke(.left), toDisplay: false))
        #expect(NamedGesture("swipe-right-up") == .swipe(Stroke(.right, turn: .up), toDisplay: false))
        #expect(NamedGesture("display-left") == .swipe(Stroke(.left), toDisplay: true))
        #expect(NamedGesture("pinch-in") == .pinch(.pinchIn))
        #expect(NamedGesture("Pinch-Out") == .pinch(.pinchOut))
        #expect(NamedGesture("double-tap") == .doubleTap)
        #expect(NamedGesture("swipe-left-right") == nil)
        #expect(NamedGesture("swipe") == nil)
        #expect(NamedGesture("wave") == nil)
    }

    @Test func catalogFollowsTheSettings() {
        var s = WindowGesturesSettings()
        let all = GestureCatalog.entries(s)
        #expect(all.contains { $0.id == "halves" })
        #expect(all.contains { $0.id == "dock-up" && $0.place == .dock })
        #expect(all.contains { $0.id == "menubar" && $0.place == .menuBar })
        #expect(all.allSatisfy { !$0.keys.isEmpty })
        s.swipeToHalves = false
        s.pinchIn = .nothing
        s.dockGestures = false
        s.menuBarFill = false
        s.displayModifier = .off
        let fewer = GestureCatalog.entries(s)
        #expect(!fewer.contains { ["halves", "slide", "pinch-in", "dock-up", "dock-down", "menubar", "display"].contains($0.id) })
        #expect(GestureCatalog.bindings(s).count == fewer.count)
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func settingsRoundTripAndOldFilesKeepDefaults() throws {
        var s = WindowGesturesSettings()
        s.swipeUp = .fullScreen
        s.sensitivity = 1.5
        s.excludedApps = ["Figma"]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WindowGesturesSettings.self, from: data) == s)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gestures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        try Data(#"{"swipeDown": "minimize"}"#.utf8).write(to: store.url(for: "gestures"))
        let loaded = store.load("gestures", default: WindowGesturesSettings())
        #expect(loaded.swipeDown == .minimize)
        #expect(loaded.swipeUp == .fill && loaded.active && loaded.titleBarHeight == 32)
    }

    @Test func optionsMirrorTheSettings() {
        var s = WindowGesturesSettings()
        s.gap = -4
        s.doubleTap = .nothing
        #expect(s.options.gap == 0)
        #expect(s.options.doubleTap == .nothing)
    }

    @Test func overlayContentIsLocalizedToTheScreen() {
        let screen = CGRect(x: 1440, y: -180, width: 2560, height: 1440)
        let content = OverlayContent.target(frame: CGRect(x: 1440, y: -155, width: 1280, height: 1415), title: "Left Half",
                                            tile: .half(.left), symbol: nil, cells: [CGRect(x: 2720, y: -155, width: 1280, height: 1415)])
        #expect(GestureOverlay.localize(content, in: screen)
                == .target(frame: CGRect(x: 0, y: 25, width: 1280, height: 1415), title: "Left Half", tile: .half(.left),
                           symbol: nil, cells: [CGRect(x: 1280, y: 25, width: 1280, height: 1415)]))
    }

    @Test func nearFrames() {
        let a = CGRect(x: 0, y: 25, width: 720, height: 800)
        #expect(a.isNear(CGRect(x: 1, y: 26, width: 718, height: 800)))
        #expect(!a.isNear(CGRect(x: 0, y: 25, width: 700, height: 800)))
    }
}
