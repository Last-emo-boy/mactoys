import CoreGraphics
import Foundation

/// Where the fingers went.
public enum SwipeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var isHorizontal: Bool { self == .left || self == .right }

    public var opposite: SwipeDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    /// The arrow shown on keycaps and in the cheat sheet.
    public var arrow: String {
        switch self {
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
    }
}

/// What a two-finger swipe drew: a direction, optionally turned into a perpendicular one
/// (an L-shaped or diagonal stroke, which aims at a corner).
public struct Stroke: Equatable, Hashable, Sendable {
    public var primary: SwipeDirection
    public var turn: SwipeDirection?

    public init(_ primary: SwipeDirection, turn: SwipeDirection? = nil) {
        self.primary = primary
        self.turn = turn
    }

    /// The left/right part of the stroke, if any.
    public var horizontal: SwipeDirection? { primary.isHorizontal ? primary : turn }
    /// The up/down part of the stroke, if any.
    public var vertical: SwipeDirection? { primary.isHorizontal ? turn : primary }
}

/// Distances (in points of finger travel) that decide a swipe. Higher sensitivity, shorter swipes.
public struct SwipeThresholds: Equatable, Sendable {
    /// Travel along one axis before the swipe locks onto it.
    public var lock: CGFloat
    /// Sideways travel after the lock that turns the stroke toward a corner.
    public var turn: CGFloat

    public static let base = SwipeThresholds(lock: 30, turn: 60)

    public init(lock: CGFloat, turn: CGFloat) {
        self.lock = lock
        self.turn = turn
    }

    public init(sensitivity: Double) {
        let s = CGFloat(min(max(sensitivity, 0.25), 4))
        self.init(lock: Self.base.lock / s, turn: Self.base.turn / s)
    }
}

/// Turns the finger travel of one swipe into a `Stroke`, live, so the target can be previewed
/// before the fingers lift.
///
/// The swipe locks onto the axis it first travels along (a nearly diagonal swipe locks once it has
/// gone twice the lock distance). Going back toward the start clears the stroke (lifting then does
/// nothing); going past the start flips it. Sideways travel of at least `turn`, and at least 30 % of
/// the travel along the locked axis (so a long, slightly drifting swipe stays straight), adds a turn.
/// Pure value type with no allocation: it runs in the event tap.
public struct SwipeRecognizer: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case horizontal, vertical }

    public let thresholds: SwipeThresholds
    public let allowsTurns: Bool
    /// Total finger travel since the swipe began (x right, y down).
    public private(set) var travel = CGVector.zero
    public private(set) var axis: Axis?
    public private(set) var stroke: Stroke?

    public init(thresholds: SwipeThresholds = .base, allowsTurns: Bool = true) {
        self.thresholds = thresholds
        self.allowsTurns = allowsTurns
    }

    /// Adds finger movement. Returns true when the stroke changed.
    @discardableResult
    public mutating func add(_ d: CGVector) -> Bool {
        travel.dx += d.dx
        travel.dy += d.dy
        let next = evaluate()
        guard next != stroke else { return false }
        stroke = next
        return true
    }

    private mutating func evaluate() -> Stroke? {
        let ax = abs(travel.dx), ay = abs(travel.dy)
        if axis == nil {
            let major = max(ax, ay), minor = min(ax, ay)
            guard major >= thresholds.lock,
                  major >= minor * 1.25 || (ax * ax + ay * ay).squareRoot() >= thresholds.lock * 2 else { return nil }
            axis = ax >= ay ? .horizontal : .vertical
        }
        let horizontal = axis == .horizontal
        let along = horizontal ? travel.dx : travel.dy
        let across = horizontal ? travel.dy : travel.dx
        // Hysteresis: a shown stroke survives down to half the lock distance.
        guard abs(along) >= (stroke == nil ? thresholds.lock : thresholds.lock / 2) else { return nil }
        let primary: SwipeDirection = horizontal ? (along < 0 ? .left : .right) : (along < 0 ? .up : .down)
        guard allowsTurns else { return Stroke(primary) }
        let sideways: SwipeDirection = horizontal ? (across < 0 ? .up : .down) : (across < 0 ? .left : .right)
        var needed = max(thresholds.turn, abs(along) * 0.3)
        if stroke?.primary == primary, stroke?.turn == sideways { needed *= 0.6 }
        return Stroke(primary, turn: abs(across) >= needed ? sideways : nil)
    }
}

/// Which way a pinch is going.
public enum PinchIntent: Equatable, Sendable {
    case pinchIn, pinchOut
}

/// Sums the magnification of one pinch and decides whether it pinches in or out; tracks how long
/// a pinch-in has been held, for close confirmation.
public struct PinchRecognizer: Equatable, Sendable {
    /// Total magnification needed (0.18 is a comfortable pinch).
    public let threshold: Double
    public private(set) var total: Double = 0
    public private(set) var intent: PinchIntent?
    /// When the pinch-in began (seconds, the caller's clock).
    public private(set) var armedAt: TimeInterval?

    public static let baseThreshold = 0.18

    public init(threshold: Double = baseThreshold) {
        self.threshold = threshold
    }

    public init(sensitivity: Double) {
        self.init(threshold: Self.baseThreshold / min(max(sensitivity, 0.25), 4))
    }

    /// Adds a magnification change at `time`. Returns true when the intent changed.
    @discardableResult
    public mutating func add(_ delta: Double, at time: TimeInterval) -> Bool {
        total += delta
        let keepIn = intent == .pinchIn ? threshold * 0.6 : threshold
        let keepOut = intent == .pinchOut ? threshold * 0.6 : threshold
        let next: PinchIntent? = total <= -keepIn ? .pinchIn : total >= keepOut ? .pinchOut : nil
        guard next != intent else { return false }
        intent = next
        armedAt = next == .pinchIn ? time : nil
        return true
    }

    /// 0…1: how far a pinch-in is through the confirmation hold.
    public func holdProgress(at time: TimeInterval, hold: TimeInterval) -> Double {
        guard let armedAt else { return 0 }
        guard hold > 0 else { return 1 }
        return min(1, max(0, (time - armedAt) / hold))
    }
}
