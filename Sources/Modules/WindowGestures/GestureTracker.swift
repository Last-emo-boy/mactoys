import CoreGraphics
import Foundation

/// Which gesture is starting, so the hit test can accept swipes on the Dock and the menu bar but
/// pinches and taps only on title bars.
public enum GestureKind: Equatable, Sendable {
    case swipe, pinch, doubleTap
}

/// The lifecycle of trackpad gestures, from raw scroll and pinch samples to swipe/pinch/tap
/// effects, and whether each event is taken (consumed) or left to the apps.
///
/// A gesture is taken only if `accept` (the title bar hit test) says so when it begins; then
/// every event of it is consumed, including the momentum scroll that follows lifting the fingers,
/// so the app underneath never scrolls. Gestures that begin elsewhere pass through untouched, to
/// their end. Wheels (non-continuous scrolls) always pass. Pure value type, allocation-free: it
/// runs in the event tap.
public struct GestureTracker: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        /// A swipe was taken (any previous gesture's UI should go).
        case swipeBegan
        case strokeChanged(Stroke?)
        /// The fingers lifted: act on the stroke (nil: nothing).
        case swipeEnded(Stroke?)
        case swipeCancelled
        case pinchBegan
        case pinchChanged(PinchIntent?)
        case pinchEnded(PinchIntent?)
        case pinchCancelled
        case doubleTap
    }

    public struct Step: Equatable, Sendable {
        public var consume: Bool
        public var effect: Effect?

        public static let pass = Step(consume: false, effect: nil)
        public static func take(_ effect: Effect? = nil) -> Step { Step(consume: true, effect: effect) }
    }

    enum ScrollState: Equatable, Sendable {
        /// No scroll gesture, or one we never saw begin.
        case idle
        /// A scroll gesture that began somewhere else: everything passes until it ends.
        case passing
        case swiping
        /// The rest of a swipe that turned into a pinch: swallowed until it ends.
        case swallowing
        /// The swipe ended; its momentum events are swallowed.
        case coasting
    }

    enum PinchState: Equatable, Sendable { case idle, passing, pinching }

    public var thresholds: SwipeThresholds
    public var allowsTurns: Bool
    public var pinchThreshold: Double
    /// Flip every direction (the "reverse swipe directions" setting).
    public var reversed: Bool

    private(set) var scrollState = ScrollState.idle
    private(set) var pinchState = PinchState.idle
    public private(set) var swipe: SwipeRecognizer
    public private(set) var pinch: PinchRecognizer

    public init(thresholds: SwipeThresholds = .base, allowsTurns: Bool = true,
                pinchThreshold: Double = PinchRecognizer.baseThreshold, reversed: Bool = false) {
        self.thresholds = thresholds
        self.allowsTurns = allowsTurns
        self.pinchThreshold = pinchThreshold
        self.reversed = reversed
        swipe = SwipeRecognizer(thresholds: thresholds, allowsTurns: allowsTurns)
        pinch = PinchRecognizer(threshold: pinchThreshold)
    }

    /// A swipe or pinch is in progress (taken).
    public var isTracking: Bool { scrollState == .swiping || pinchState == .pinching }

    // MARK: Scroll

    public mutating func handle(_ s: ScrollSample, accept: (GestureKind) -> Bool) -> Step {
        guard s.isContinuous else { return .pass }
        // Momentum belongs to the swipe that just ended, if we took it; otherwise to the app.
        if s.momentum != .none {
            switch scrollState {
            case .coasting:
                if s.momentum == .ended { scrollState = .idle }
                return .take()
            case .swallowing, .swiping:
                return .take()
            case .idle, .passing:
                return .pass
            }
        }
        if scrollState == .coasting { scrollState = .idle }      // fingers are back: that swipe is over
        switch s.phase {
        case .began:
            let interrupted = scrollState == .swiping
            if pinchState != .pinching, accept(.swipe) {
                scrollState = .swiping
                swipe = SwipeRecognizer(thresholds: thresholds, allowsTurns: allowsTurns)
                swipe.add(finger(s))
                return .take(.swipeBegan)
            }
            scrollState = .passing
            return Step(consume: false, effect: interrupted ? .swipeCancelled : nil)
        case .changed:
            switch scrollState {
            case .swiping: return .take(swipe.add(finger(s)) ? .strokeChanged(swipe.stroke) : nil)
            case .swallowing: return .take()
            case .idle, .passing, .coasting: return .pass
            }
        case .ended:
            switch scrollState {
            case .swiping:
                swipe.add(finger(s))
                scrollState = .coasting
                return .take(.swipeEnded(swipe.stroke))
            case .swallowing:
                scrollState = .coasting
                return .take()
            case .idle, .passing, .coasting:
                scrollState = .idle
                return .pass
            }
        case .cancelled:
            switch scrollState {
            case .swiping:
                scrollState = .idle
                return .take(.swipeCancelled)
            case .swallowing:
                scrollState = .idle
                return .take()
            case .idle, .passing, .coasting:
                scrollState = .idle
                return .pass
            }
        case .mayBegin, .none:
            return scrollState == .swiping || scrollState == .swallowing ? .take() : .pass
        }
    }

    private func finger(_ s: ScrollSample) -> CGVector {
        let d = s.fingerDelta
        return reversed ? CGVector(dx: -d.dx, dy: -d.dy) : d
    }

    // MARK: Pinch and tap

    public mutating func handle(_ g: TrackpadGesture, at time: TimeInterval, accept: (GestureKind) -> Bool) -> Step {
        switch g {
        case .other:
            return .pass
        case .smartMagnify:
            return accept(.doubleTap) ? .take(.doubleTap) : .pass
        case .magnify(let phase, let delta):
            switch phase {
            case .began:
                guard accept(.pinch) else { pinchState = .passing; return .pass }
                pinchState = .pinching
                pinch = PinchRecognizer(threshold: pinchThreshold)
                pinch.add(delta, at: time)
                // A swipe the fingers turned into a pinch is over; its leftovers are swallowed.
                if scrollState == .swiping { scrollState = .swallowing }
                return .take(.pinchBegan)
            case .changed:
                guard pinchState == .pinching else { return .pass }
                return .take(pinch.add(delta, at: time) ? .pinchChanged(pinch.intent) : nil)
            case .ended:
                guard pinchState == .pinching else { pinchState = .idle; return .pass }
                pinch.add(delta, at: time)
                pinchState = .idle
                return .take(.pinchEnded(pinch.intent))
            case .cancelled:
                guard pinchState == .pinching else { pinchState = .idle; return .pass }
                pinchState = .idle
                return .take(.pinchCancelled)
            case .mayBegin, .none:
                return pinchState == .pinching ? .take() : .pass
            }
        }
    }

    /// No event arrived for a while (an end event got lost): cancels what is in progress.
    public mutating func expire() -> Effect? {
        if pinchState == .pinching {
            pinchState = .idle
            return .pinchCancelled
        }
        if scrollState == .swiping {
            scrollState = .idle
            return .swipeCancelled
        }
        // Swallowing or coasting with no end in sight: let scrolling through again.
        scrollState = .idle
        pinchState = .idle
        return nil
    }
}
