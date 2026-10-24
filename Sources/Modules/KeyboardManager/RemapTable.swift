import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Indexed remaps for O(1) lookup from the event tap. Build it from `RemapPlan.tapRemaps`
/// (which drops disabled and invalid remaps).
///
/// Resolution rules:
/// - Remaps limited to the frontmost app win over global ones.
/// - A shortcut matches when all its modifiers are held. Extra modifiers are allowed unless the
///   remap asks for an exact match; then the most specific remap (most modifiers) wins, and an
///   exact match beats a non-exact one with the same modifiers.
/// - fn is ignored unless the shortcut includes it (macOS adds it to arrow and function keys).
struct RemapTable {
    private var keyRemaps: [Key: [Remap]] = [:]
    private var shortcutRemaps: [Key: [Remap]] = [:]
    private var chordRemaps: [Key: [Remap]] = [:]

    init(_ remaps: [Remap]) {
        for r in remaps where r.isEnabled {
            switch r.kind {
            case .key: keyRemaps[r.trigger.key, default: []].append(r)
            case .shortcut:
                if r.chord != nil { chordRemaps[r.trigger.key, default: []].append(r) }
                else { shortcutRemaps[r.trigger.key, default: []].append(r) }
            }
        }
        for k in keyRemaps.keys { keyRemaps[k]?.sort(by: Self.precedes) }
        for k in shortcutRemaps.keys { shortcutRemaps[k]?.sort(by: Self.precedes) }
        for k in chordRemaps.keys { chordRemaps[k]?.sort(by: Self.precedes) }
    }

    var isEmpty: Bool { keyRemaps.isEmpty && shortcutRemaps.isEmpty && chordRemaps.isEmpty }

    /// Order of preference: app-specific first, then more modifiers, then exact matches.
    static func precedes(_ a: Remap, _ b: Remap) -> Bool {
        if a.isGlobal != b.isGlobal { return !a.isGlobal }
        let ac = a.trigger.modifiers.rawValue.nonzeroBitCount, bc = b.trigger.modifiers.rawValue.nonzeroBitCount
        if ac != bc { return ac > bc }
        if a.exactMatch != b.exactMatch { return a.exactMatch }
        return false
    }

    /// Whether held modifiers satisfy a shortcut trigger.
    static func modifiersMatch(_ remap: Remap, held: Modifiers) -> Bool {
        var held = held
        if !remap.trigger.modifiers.contains(.function) { held.remove(.function) }
        if remap.exactMatch { return held == remap.trigger.modifiers }
        return held.isSuperset(of: remap.trigger.modifiers)
    }

    func keyRemap(for key: Key, app: String?) -> Remap? {
        guard let list = keyRemaps[key] else { return nil }
        return list.first { $0.applies(to: app) }
    }

    func shortcut(for key: Key, modifiers: Modifiers, app: String?) -> Remap? {
        guard let list = shortcutRemaps[key] else { return nil }
        return list.first { $0.applies(to: app) && Self.modifiersMatch($0, held: modifiers) }
    }

    /// Whether `key` with `modifiers` starts a chord in this app.
    func startsChord(_ key: Key, modifiers: Modifiers, app: String?) -> Bool {
        guard let list = chordRemaps[key] else { return false }
        return list.contains { $0.applies(to: app) && Self.modifiersMatch($0, held: modifiers) }
    }

    func chord(first: Key, second: Key, modifiers: Modifiers, app: String?) -> Remap? {
        guard let list = chordRemaps[first] else { return nil }
        return list.first { $0.chord == second && $0.applies(to: app) && Self.modifiersMatch($0, held: modifiers) }
    }
}

/// How remaps are split between the system key mapping (`hidutil`) and the event tap.
struct RemapPlan: Equatable {
    /// Source → destination HID usages for `hidutil property --set UserKeyMapping`.
    var systemMappings: [SystemKeyMapping.Entry] = []
    /// Remaps the event tap handles, with Caps Lock triggers moved onto `capsLockProxy`.
    var tapRemaps: [Remap] = []
    /// Caps Lock is mapped to this key at the HID level so the tap sees real key-down/up events.
    var usesCapsLockProxy = false

    /// F20: present in macOS but on almost no keyboard.
    static let capsLockProxy = Key.keyboard(kVK_F20)

    /// Builds the plan. Global key → key remaps between keys that have HID usages go to the
    /// system mapping (when allowed), unless the same key has other remaps that need the tap.
    /// Caps Lock can't be held or tapped reliably through the tap (it toggles), so any Caps Lock
    /// remap left for the tap gets the proxy.
    static func make(_ remaps: [Remap], useSystemMapping: Bool) -> RemapPlan {
        let active = remaps.filter { $0.isEnabled && $0.validationError == nil }
        var keyTriggerCounts: [Key: Int] = [:]
        for r in active where r.kind == .key { keyTriggerCounts[r.trigger.key, default: 0] += 1 }

        var plan = RemapPlan()
        var systemSources = Set<UInt64>()
        for r in active {
            if useSystemMapping, r.kind == .key, r.isGlobal, !r.tapAlone, r.action.isPlainKey,
               keyTriggerCounts[r.trigger.key] == 1,
               let dst = r.action.combo?.key, let srcUsage = KeyCatalog.hidUsage(for: r.trigger.key),
               let dstUsage = KeyCatalog.hidUsage(for: dst), !systemSources.contains(srcUsage) {
                plan.systemMappings.append(SystemKeyMapping.Entry(src: srcUsage, dst: dstUsage))
                systemSources.insert(srcUsage)
                continue
            }
            var tapRemap = r
            if r.kind == .key && r.trigger.key == .capsLock {
                tapRemap.trigger.key = capsLockProxy
                plan.usesCapsLockProxy = true
            }
            plan.tapRemaps.append(tapRemap)
        }
        if plan.usesCapsLockProxy, let caps = KeyCatalog.hidUsage(for: .capsLock),
           let proxy = KeyCatalog.hidUsage(for: capsLockProxy) {
            plan.systemMappings.append(SystemKeyMapping.Entry(src: caps, dst: proxy))
        }
        return plan
    }
}

/// Keys that no physical key produces any more because they were remapped away.
enum OrphanCheck {
    /// For global key → key remaps: a source key that is remapped and is not the output of any
    /// other remap can no longer be typed. Modifiers and Caps Lock are left out (remapping them
    /// away is usually the point).
    static func orphans(in remaps: [Remap]) -> [Key] {
        let active = remaps.filter { $0.isEnabled && $0.kind == .key && $0.isGlobal && !$0.tapAlone }
        let sources = Set(active.map(\.trigger.key))
        let produced = Set(remaps.filter { $0.isEnabled && $0.action.isPlainKey }.compactMap { $0.action.combo?.key })
        return sources.subtracting(produced).filter { !$0.isModifier && $0 != .capsLock && $0.kind == .keyboard }.sorted()
    }
}
