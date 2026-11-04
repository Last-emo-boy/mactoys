import CoreGraphics
import Foundation

/// "Keep this resolution?": after a mode change the old mode comes back on its own unless the user
/// keeps the new one within `duration` seconds. Pure state; the module applies the effects.
///
/// One change is pending at a time. Changing the same display again keeps the mode to fall back to
/// (the last one the user confirmed); changing another display keeps the first change, since the
/// user could evidently see and use the screen.
struct ModeConfirmation: Equatable {
    struct Pending: Equatable {
        var displayID: CGDirectDisplayID
        /// The mode to go back to.
        var previous: DisplayModeInfo
        var applied: DisplayModeInfo
        var deadline: Date
    }

    enum Phase: Equatable {
        case idle
        case pending(Pending)
    }

    /// What the module must do.
    enum Effect: Equatable {
        /// Switch the display back.
        case revert(CGDirectDisplayID, DisplayModeInfo)
        /// The change is final: close the prompt.
        case kept(CGDirectDisplayID)
    }

    static let duration: TimeInterval = 15

    private(set) var phase = Phase.idle

    var pending: Pending? {
        if case .pending(let p) = phase { return p }
        return nil
    }

    var isPending: Bool { pending != nil }

    /// A mode was just applied. Returns the effect for a change that was still pending elsewhere.
    @discardableResult
    mutating func begin(display: CGDirectDisplayID, previous: DisplayModeInfo, applied: DisplayModeInfo,
                        now: Date, duration: TimeInterval = ModeConfirmation.duration) -> Effect? {
        var effect: Effect?
        var fallback = previous
        if let p = pending {
            if p.displayID == display { fallback = p.previous } else { effect = .kept(p.displayID) }
        }
        if fallback == applied {
            // Back where we started: nothing to confirm.
            phase = .idle
            return effect
        }
        phase = .pending(Pending(displayID: display, previous: fallback, applied: applied,
                                 deadline: now.addingTimeInterval(duration)))
        return effect
    }

    /// Whole seconds left, rounded up (15 … 1), or 0 when nothing is pending.
    func secondsLeft(at now: Date) -> Int {
        guard let p = pending else { return 0 }
        return max(0, Int(p.deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// Fraction of the time left, 1 … 0, for the countdown ring.
    func progress(at now: Date, duration: TimeInterval = ModeConfirmation.duration) -> Double {
        guard let p = pending, duration > 0 else { return 0 }
        return max(0, min(1, p.deadline.timeIntervalSince(now) / duration))
    }

    /// Call periodically; reverts once the deadline passes.
    mutating func tick(now: Date) -> Effect? {
        guard let p = pending, now >= p.deadline else { return nil }
        phase = .idle
        return .revert(p.displayID, p.previous)
    }

    mutating func keep() -> Effect? {
        guard let p = pending else { return nil }
        phase = .idle
        return .kept(p.displayID)
    }

    mutating func revert() -> Effect? {
        guard let p = pending else { return nil }
        phase = .idle
        return .revert(p.displayID, p.previous)
    }

    /// The display went away: nothing left to revert.
    mutating func displayRemoved(_ id: CGDirectDisplayID) {
        if pending?.displayID == id { phase = .idle }
    }
}
