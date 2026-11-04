import CoreGraphics
import Foundation

/// Which window sits where: for every display an ordered list of tiles (slot 0 is the main
/// tile), each tile a stack of windows with the visible one first, plus the windows that float.
///
/// Windows stay in the board while they're away (minimized, hidden, on another Space), so they
/// come back to their place. Everything that counts tiles takes a `present` set: only windows on
/// screen right now occupy a tile.
public struct TileBoard: Equatable, Sendable {
    public typealias WindowID = UInt32

    /// Why a window isn't tiled.
    public enum FloatReason: String, Equatable, Sendable {
        /// The user floated it; it stays floating until they tile it again.
        case user
        /// Its display was full and stacking is off; it rejoins when a tile frees up.
        case overflow
        /// It doesn't fit at its minimum size; it rejoins when there is room.
        case tooBig
    }

    public struct Floating: Equatable, Sendable {
        public var reason: FloatReason
        /// The display it belongs to.
        public var display: String
    }

    /// Where a window was placed by `add`.
    public enum Placement: Equatable, Sendable { case tiled, stacked, floated }

    /// Where a window is moved to on another display.
    public enum InsertPosition: Sendable { case first, last }

    public private(set) var slots: [String: [[WindowID]]] = [:]
    public private(set) var floating: [WindowID: Floating] = [:]

    public init() {}

    // MARK: Queries

    public func contains(_ id: WindowID) -> Bool { location(of: id) != nil || floating[id] != nil }

    public func isTiled(_ id: WindowID) -> Bool { location(of: id) != nil }

    /// Display, slot index (into the full list) and depth in the stack (0 = visible).
    public func location(of id: WindowID) -> (display: String, slot: Int, depth: Int)? {
        for (display, tiles) in slots {
            for (s, stack) in tiles.enumerated() {
                if let d = stack.firstIndex(of: id) { return (display, s, d) }
            }
        }
        return nil
    }

    /// The display a tiled or floating window belongs to.
    public func display(of id: WindowID) -> String? { location(of: id)?.display ?? floating[id]?.display }

    /// The tiles shown on a display: stacks filtered to present windows, empty ones dropped.
    public func visibleTiles(on display: String, present: Set<WindowID>) -> [[WindowID]] {
        (slots[display] ?? []).map { $0.filter(present.contains) }.filter { !$0.isEmpty }
    }

    /// Every window of the board, tiled and floating.
    public var allWindows: Set<WindowID> {
        Set(slots.values.flatMap { $0.flatMap { $0 } }).union(floating.keys)
    }

    private func visibleSlotIndices(_ tiles: [[WindowID]], present: Set<WindowID>) -> [Int] {
        tiles.indices.filter { tiles[$0].contains(where: present.contains) }
    }

    // MARK: Adding and removing

    /// Places a window on `display`: in a tile of its own while there is room, else stacked on
    /// the tile of `active` (the window last used there) or the last tile, else floating.
    @discardableResult
    public mutating func add(_ id: WindowID, to display: String, capacity: Int, present: Set<WindowID>,
                             stackWhenFull: Bool, active: WindowID? = nil) -> Placement {
        remove(id)
        var tiles = slots[display] ?? []
        let visible = visibleSlotIndices(tiles, present: present)
        if visible.count < max(1, capacity) {
            tiles.append([id])
            slots[display] = tiles
            return .tiled
        }
        if stackWhenFull, let last = visible.last {
            let target = active.flatMap { a in visible.first { tiles[$0].contains(a) } } ?? last
            tiles[target].insert(id, at: 0)
            slots[display] = tiles
            return .stacked
        }
        floating[id] = Floating(reason: .overflow, display: display)
        return .floated
    }

    /// Takes a window out of the board altogether.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Bool {
        var removed = floating.removeValue(forKey: id) != nil
        if let loc = location(of: id) {
            var tiles = slots[loc.display] ?? []
            tiles[loc.slot].remove(at: loc.depth)
            if tiles[loc.slot].isEmpty { tiles.remove(at: loc.slot) }
            slots[loc.display] = tiles.isEmpty ? nil : tiles
            removed = true
        }
        return removed
    }

    /// Removes every window that `keep` rejects.
    public mutating func removeAll(where reject: (WindowID) -> Bool) {
        for id in allWindows where reject(id) { remove(id) }
    }

    /// Floats a window (it leaves its tile; the others re-flow).
    public mutating func float(_ id: WindowID, reason: FloatReason, display: String? = nil) {
        guard let home = display ?? self.display(of: id) else { return }
        remove(id)
        floating[id] = Floating(reason: reason, display: home)
    }

    /// Moves every window of a display that disappeared to `display`, in order.
    public mutating func merge(display gone: String, into display: String) {
        guard gone != display else { return }
        let tiles = slots.removeValue(forKey: gone) ?? []
        if !tiles.isEmpty { slots[display, default: []].append(contentsOf: tiles) }
        for (id, f) in floating where f.display == gone { floating[id]?.display = display }
    }

    // MARK: Rearranging

    /// Exchanges two tiled windows (tile and stack position, across displays too).
    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard a != b, let la = location(of: a), let lb = location(of: b) else { return }
        slots[la.display]?[la.slot][la.depth] = b
        slots[lb.display]?[lb.slot][lb.depth] = a
    }

    /// Swaps a window with the visible window of its display's main tile.
    public mutating func makeMain(_ id: WindowID, present: Set<WindowID>) {
        guard let loc = location(of: id), let main = visibleTiles(on: loc.display, present: present).first?.first,
              main != id else { return }
        if let mainLoc = location(of: main), mainLoc.slot == loc.slot {
            // Already in the main tile's stack: just bring it to the front.
            bringToFront(id)
            return
        }
        swap(id, main)
    }

    /// Makes a window the visible one of its stack (it was focused).
    public mutating func bringToFront(_ id: WindowID) {
        guard let loc = location(of: id), loc.depth > 0 else { return }
        slots[loc.display]?[loc.slot].remove(at: loc.depth)
        slots[loc.display]?[loc.slot].insert(id, at: 0)
    }

    /// The next (or previous) present window in the stack of `id`, now brought to the front.
    @discardableResult
    public mutating func cycleStack(of id: WindowID, forward: Bool, present: Set<WindowID>) -> WindowID? {
        guard let loc = location(of: id), var stack = slots[loc.display]?[loc.slot] else { return nil }
        let members = stack.filter(present.contains)
        guard members.count > 1, let i = members.firstIndex(of: id) else { return nil }
        let next = members[(i + (forward ? 1 : members.count - 1)) % members.count]
        if forward {
            // The old front goes to the back, so repeated presses visit every window.
            stack.removeAll { $0 == id }
            stack.append(id)
        }
        stack.removeAll { $0 == next }
        stack.insert(next, at: 0)
        slots[loc.display]?[loc.slot] = stack
        return next
    }

    /// Moves a tiled window to another display: into a tile of its own placed first or last
    /// when there is room; else stacked on the first or last tile; else swapped with that tile's
    /// window. Returns the window it was swapped with, if any.
    @discardableResult
    public mutating func move(_ id: WindowID, to display: String, at position: InsertPosition, capacity: Int,
                              present: Set<WindowID>, stackWhenFull: Bool) -> WindowID? {
        guard let loc = location(of: id), loc.display != display else { return nil }
        let tiles = slots[display] ?? []
        let visible = visibleSlotIndices(tiles, present: present)
        if visible.count < max(1, capacity) {
            remove(id)
            var target = slots[display] ?? []
            let index = position == .first ? (visible.first ?? 0) : target.count
            target.insert([id], at: min(index, target.count))
            slots[display] = target
            return nil
        }
        guard let slot = position == .first ? visible.first : visible.last,
              let front = tiles[slot].first(where: present.contains) else { return nil }
        if stackWhenFull {
            remove(id)
            if let s = slots[display]?.firstIndex(where: { $0.contains(front) }) {
                slots[display]?[s].insert(id, at: 0)
            }
            return nil
        }
        swap(id, front)
        return front
    }

    /// Takes a floating window back into the tiles of its display.
    @discardableResult
    public mutating func unfloat(_ id: WindowID, capacity: Int, present: Set<WindowID>, stackWhenFull: Bool,
                                 active: WindowID? = nil) -> Placement? {
        guard let f = floating[id] else { return nil }
        floating[id] = nil
        return add(id, to: f.display, capacity: capacity, present: present, stackWhenFull: stackWhenFull, active: active)
    }

    /// Brings a display back to `capacity` tiles: extra tiles are stacked on the last one (or
    /// float, without stacking); free tiles take a window off the deepest stack, then a window
    /// that floated because the display was full.
    public mutating func rebalance(_ display: String, capacity: Int, present: Set<WindowID>, stackWhenFull: Bool) {
        let cap = max(1, capacity)
        for _ in 0..<64 {
            var tiles = slots[display] ?? []
            let visible = visibleSlotIndices(tiles, present: present)
            if visible.count > cap, let extra = visible.last {
                let moved = tiles.remove(at: extra)
                if stackWhenFull, let keep = visibleSlotIndices(tiles, present: present).last {
                    tiles[keep].append(contentsOf: moved)
                    slots[display] = tiles
                } else {
                    slots[display] = tiles.isEmpty ? nil : tiles
                    for id in moved { floating[id] = Floating(reason: .overflow, display: display) }
                }
                continue
            }
            guard visible.count < cap else { return }
            // The deepest stack (the last one on ties) gives up its last window.
            let stacked = visible.filter { tiles[$0].filter(present.contains).count > 1 }
            if let from = stacked.max(by: { a, b in
                let ca = tiles[a].filter(present.contains).count, cb = tiles[b].filter(present.contains).count
                return ca != cb ? ca < cb : a < b
            }), let id = tiles[from].last(where: present.contains) {
                tiles[from].removeAll { $0 == id }
                tiles.append([id])
                slots[display] = tiles
                continue
            }
            let waiting = floating.filter { $0.value.display == display && $0.value.reason == .overflow && present.contains($0.key) }
            if let id = waiting.keys.min() {
                floating[id] = nil
                tiles.append([id])
                slots[display] = tiles
                continue
            }
            return
        }
    }
}
