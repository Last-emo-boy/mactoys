import CoreGraphics
import Foundation

/// The phase of a trackpad scroll or pinch, as the window server reports it. Pinch events use the
/// same bit values as `CGScrollPhase`.
public enum GesturePhase: Equatable, Sendable {
    case none, mayBegin, began, changed, ended, cancelled

    public init(bits: Int64) {
        switch bits {
        case 1: self = .began
        case 2: self = .changed
        case 4: self = .ended
        case 8: self = .cancelled
        case 128: self = .mayBegin
        default: self = .none
        }
    }
}

/// The momentum (coasting) part of a scroll that follows lifting the fingers.
public enum MomentumPhase: Equatable, Sendable {
    case none, began, changed, ended

    public init(raw: Int64) {
        switch raw {
        case 1: self = .began
        case 2: self = .changed
        case 3: self = .ended
        default: self = .none
        }
    }
}

/// Event fields the CoreGraphics headers don't name. `NSEvent(cgEvent:)` reads the same fields, so
/// the decoding below is checked against it in the tests.
enum GestureFields {
    /// Subtype of a gesture event (an IOHID event type): 8 magnify, 22 smart magnify.
    static let subtype = CGEventField(rawValue: 110)!
    static let magnification = CGEventField(rawValue: 113)!
    static let phase = CGEventField(rawValue: 132)!
    /// Set on scroll events whose deltas natural scrolling flipped.
    static let scrollInverted = CGEventField(rawValue: 137)!

    static let magnifySubtype: Int64 = 8
    static let smartMagnifySubtype: Int64 = 22
    /// `NSEvent.EventType.gesture`: the CGEvent type of every trackpad gesture event.
    static let gestureType = CGEventType(rawValue: 29)!
}

/// One scroll event, reduced to what gesture recognition needs.
public struct ScrollSample: Equatable, Sendable {
    public var phase: GesturePhase
    public var momentum: MomentumPhase
    /// Point deltas as the event carries them: `dx` is axis 2 (horizontal), `dy` axis 1 (vertical).
    /// Positive values scroll toward the top-left of a document.
    public var delta: CGVector
    /// A trackpad or Magic Mouse (phased, precise), rather than a wheel with notches.
    public var isContinuous: Bool
    /// Natural scrolling flipped the deltas.
    public var isInverted: Bool

    public init(phase: GesturePhase, momentum: MomentumPhase = .none, delta: CGVector = .zero,
                isContinuous: Bool = true, isInverted: Bool = true) {
        self.phase = phase
        self.momentum = momentum
        self.delta = delta
        self.isContinuous = isContinuous
        self.isInverted = isInverted
    }

    /// Reads a scroll-wheel event. No allocation: safe for the event tap.
    public init(_ event: CGEvent) {
        self.init(phase: GesturePhase(bits: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                  momentum: MomentumPhase(raw: event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                  delta: CGVector(dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                                  dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                  isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                  isInverted: event.getIntegerValueField(GestureFields.scrollInverted) != 0)
    }

    /// Where the fingers moved, in screen terms (x right, y down). Scroll deltas follow the
    /// content: with natural scrolling the content moves with the fingers, so the deltas already
    /// point where they went; with traditional scrolling they point the other way.
    public var fingerDelta: CGVector {
        isInverted ? delta : CGVector(dx: -delta.dx, dy: -delta.dy)
    }
}

/// A trackpad gesture event (CGEvent type 29), reduced to the two kinds Window Gestures uses.
public enum TrackpadGesture: Equatable, Sendable {
    /// A pinch: `delta` is the change in magnification since the last event (negative pinches in).
    case magnify(phase: GesturePhase, delta: Double)
    /// A two-finger double-tap (macOS sends it while Smart zoom is on in Trackpad settings).
    case smartMagnify
    /// Touches, rotation and everything else.
    case other

    /// Reads a gesture event; one integer read for the many events that aren't pinches or taps.
    public init(_ event: CGEvent) {
        switch event.getIntegerValueField(GestureFields.subtype) {
        case GestureFields.magnifySubtype:
            self = .magnify(phase: GesturePhase(bits: event.getIntegerValueField(GestureFields.phase)),
                            delta: event.getDoubleValueField(GestureFields.magnification))
        case GestureFields.smartMagnifySubtype:
            self = .smartMagnify
        default:
            self = .other
        }
    }
}
