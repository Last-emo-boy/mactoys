import Foundation

/// Why hidden items are showing; it decides how they hide again.
enum RevealReason: Equatable, Sendable {
    /// The chevron, the shortcut, a URL or the quick action. Follows the rehide settings.
    case manual
    /// The pointer rested in empty menu bar space: they hide once it leaves.
    case hover
    /// A click in empty menu bar space. Follows the rehide settings.
    case click
    /// A hidden item changed or a new one appeared: shown for a few seconds.
    case update
    /// Opening an item from the separate bar or search: hides once its menu closes.
    case activation
    /// The arrangement card is open: stays until it's closed.
    case arranging
}

/// When shown items hide again on their own.
struct RehideSchedule: Equatable, Sendable {
    /// Seconds after showing (counted while nothing holds them open); nil for never.
    var afterDelay: TimeInterval?
    /// Hide shortly after the pointer leaves the menu bar (having been in it).
    var whenPointerLeaves: Bool
}

/// The auto-rehide state machine: a pure value fed with events and the current time, so every rule
/// is testable without timers or a screen.
///
/// Items are *held* open while the pointer is over the menu bar (or the separate bar) and while a
/// menu or popover opened from the menu bar is up; the countdown restarts when the hold ends.
struct RehideMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case reveal(RevealReason)
        case hide
        case pointerEntered
        case pointerLeft
        case menuOpened
        case menuClosed
    }

    /// Grace period after the pointer leaves (or a menu closes) before items hide.
    static let leaveGrace: TimeInterval = 0.6
    /// How long items shown for an update stay.
    static let updateDuration: TimeInterval = 5

    var schedule: RehideSchedule
    private(set) var isShown = false
    private(set) var reason: RevealReason?
    private(set) var pointerInside = false
    private(set) var menuOpen = false
    /// The pointer has been over the menu bar since the items appeared.
    private(set) var pointerVisited = false
    /// When the items hide if nothing changes; nil while held or when they stay.
    private(set) var deadline: Date?

    init(schedule: RehideSchedule) {
        self.schedule = schedule
    }

    var isHeld: Bool { pointerInside || menuOpen }

    mutating func handle(_ event: Event, now: Date) {
        switch event {
        case .reveal(let r):
            // A deliberate reveal upgrades a passive one (hover, update); never the other way round.
            if !isShown || Self.priority(r) >= Self.priority(reason ?? .update) { reason = r }
            if !isShown { pointerVisited = pointerInside }
            isShown = true
        case .hide:
            isShown = false
            reason = nil
            pointerVisited = false
        case .pointerEntered:
            pointerInside = true
            if isShown { pointerVisited = true }
        case .pointerLeft:
            pointerInside = false
        case .menuOpened:
            menuOpen = true
        case .menuClosed:
            menuOpen = false
        }
        deadline = computeDeadline(now: now)
    }

    /// Call when the deadline passes. Returns true when the items should hide now (and records it).
    mutating func tick(now: Date) -> Bool {
        guard isShown, !isHeld, let deadline, deadline <= now else { return false }
        handle(.hide, now: now)
        return true
    }

    /// Changing settings while items show restarts the countdown with the new rules.
    mutating func update(schedule: RehideSchedule, now: Date) {
        self.schedule = schedule
        deadline = computeDeadline(now: now)
    }

    private func computeDeadline(now: Date) -> Date? {
        guard isShown, !isHeld, let reason else { return nil }
        var delays: [TimeInterval] = []
        switch reason {
        case .arranging:
            return nil
        case .hover:
            delays.append(Self.leaveGrace)
        case .update:
            delays.append(pointerVisited ? Self.leaveGrace : Self.updateDuration)
        case .activation:
            delays.append(Self.leaveGrace)
        case .manual, .click:
            if schedule.whenPointerLeaves && pointerVisited { delays.append(Self.leaveGrace) }
        }
        if let after = schedule.afterDelay, reason != .update { delays.append(after) }
        return delays.min().map { now.addingTimeInterval($0) }
    }

    private static func priority(_ r: RevealReason) -> Int {
        switch r {
        case .update: 0
        case .hover: 1
        case .activation: 2
        case .click, .manual: 3
        case .arranging: 4
        }
    }
}
