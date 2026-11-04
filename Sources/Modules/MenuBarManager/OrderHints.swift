import Foundation

/// What Menu Bar Manager remembers about the menu bar between launches.
///
/// - `controlPositions`: AppKit keeps each status item's place in the app's defaults under
///   "NSStatusItem Preferred Position <autosave name>" and forgets it when the item is removed
///   (turning the module off, quitting) or after some re-layouts. A copy here puts the chevron and
///   dividers back exactly where the user dragged them.
/// - `items`: the section each item was last seen in, keyed by `MenuBarLayout.itemKey`, so a
///   genuinely new item (one macOS just placed at the far left, into a hidden section) can be told
///   apart from one that was there all along.
struct OrderHints: Codable, Equatable, Sendable {
    struct ItemHint: Codable, Equatable, Sendable {
        var section: MenuBarSection
        var lastSeen: Date
    }

    var controlPositions: [String: Double] = [:]
    var items: [String: ItemHint] = [:]

    /// Entries not seen for this long are dropped.
    static let maxAge: TimeInterval = 60 * 24 * 3600
    static let maxItems = 300

    /// How stale `lastSeen` may get before a sighting is written down again (so frequent scans
    /// don't rewrite the file).
    static let refreshInterval: TimeInterval = 12 * 3600

    /// Records where items are now. Returns the keys never seen before.
    @discardableResult
    mutating func record(_ entries: [(key: String, section: MenuBarSection)], now: Date) -> [String] {
        var fresh: [String] = []
        for e in entries {
            if let known = items[e.key] {
                if known.section == e.section && now.timeIntervalSince(known.lastSeen) < Self.refreshInterval { continue }
            } else {
                fresh.append(e.key)
            }
            items[e.key] = ItemHint(section: e.section, lastSeen: now)
        }
        prune(now: now)
        return fresh
    }

    /// Keys whose section differs from the one last recorded (macOS or the user moved them).
    func moved(_ entries: [(key: String, section: MenuBarSection)]) -> [String] {
        entries.compactMap { e in
            guard let known = items[e.key], known.section != e.section else { return nil }
            return e.key
        }
    }

    /// Drops stale entries and keeps at most `maxItems`, newest first.
    mutating func prune(now: Date) {
        items = items.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.maxAge }
        if items.count > Self.maxItems {
            let keep = items.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(Self.maxItems)
            items = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// Reads and writes AppKit's per-status-item defaults in a `UserDefaults` domain (the app's own
/// in practice; tests pass a scratch suite).
struct StatusItemDefaults {
    let defaults: UserDefaults

    static func positionKey(_ autosaveName: String) -> String { "NSStatusItem Preferred Position \(autosaveName)" }
    static func visibleKey(_ autosaveName: String) -> String { "NSStatusItem Visible \(autosaveName)" }

    func position(_ autosaveName: String) -> Double? {
        (defaults.object(forKey: Self.positionKey(autosaveName)) as? NSNumber)?.doubleValue
    }

    func setPosition(_ value: Double?, for autosaveName: String) {
        if let value { defaults.set(value, forKey: Self.positionKey(autosaveName)) }
        else { defaults.removeObject(forKey: Self.positionKey(autosaveName)) }
    }

    /// Current positions of the named items (only those AppKit has stored).
    func capture(_ names: [String]) -> [String: Double] {
        var result: [String: Double] = [:]
        for n in names { if let p = position(n) { result[n] = p } }
        return result
    }

    /// Writes cached positions for names AppKit has none for, so items are re-created where the user
    /// left them. Positions AppKit already has are newer and win.
    func restore(_ cached: [String: Double], names: [String]) {
        for n in names where position(n) == nil {
            if let p = cached[n] { setPosition(p, for: n) }
        }
    }

    /// Clears a stale "not visible" flag so a re-created item shows up.
    func markVisible(_ autosaveName: String) {
        if defaults.object(forKey: Self.visibleKey(autosaveName)) != nil {
            defaults.removeObject(forKey: Self.visibleKey(autosaveName))
        }
    }
}
