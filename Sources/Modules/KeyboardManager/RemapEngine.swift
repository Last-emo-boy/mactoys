import Carbon.HIToolbox
import CoreGraphics
import MacToysCore

/// A key press or release as the engine sees it. Modifier keys arrive as down/up too
/// (the driver decodes `flagsChanged`); media keys arrive as `.media` keys.
struct EngineEvent {
    enum Phase { case down, up, autorepeat }

    var key: Key
    var phase: Phase
    /// Monotonic seconds.
    var time: TimeInterval
    /// Bundle identifier of the frontmost app.
    var app: String?
}

/// Something the driver posts or performs after handling an event.
enum EngineEffect: Equatable {
    /// Post a key event: a key down/up, a modifier change (`flagsChanged`) or a media key.
    case key(Key, down: Bool, flags: CGEventFlags, isRepeat: Bool)
    /// Flip the Caps Lock state.
    case toggleCapsLock
    /// Type text, launch a program or open a URL.
    case perform(RemapAction)
}

/// Replaces the modifier bits of an event that passes through.
struct FlagRewrite: Equatable {
    var clear: UInt64
    var set: UInt64

    func apply(to flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: (flags.rawValue & ~clear) | set)
    }
}

/// What to do with the event that was handled.
struct EngineResult: Equatable {
    enum Disposition: Equatable {
        case pass
        case consume
        /// Deliver the event with this virtual key code instead.
        case rewrite(Int)
    }

    var disposition: Disposition
    var flags: FlagRewrite?
    var effects: [EngineEffect] = []
    /// A chord prefix was swallowed; the driver calls `chordTimedOut(startedAt:)` after the timeout.
    var startedChord = false

    static let pass = EngineResult(disposition: .pass, flags: nil)
}

/// The Keyboard Manager state machine. Pure: it decides, the driver posts.
///
/// Two layers, as in PowerToys: key remaps first (a remapped key is "a different key" from then
/// on), then shortcut remaps on the resulting key with the logical modifier state. Every key whose
/// press was transformed is remembered, so its auto-repeat and release are paired with the same
/// output even if the frontmost app or the held modifiers change in between. Modifiers the engine
/// holds down synthetically are reference-counted and released by `releaseAll()`.
struct RemapEngine {
    var table: RemapTable
    /// Longest press that counts as a tap for tap-alone remaps, in seconds.
    var tapTimeout: TimeInterval
    /// Caps Lock arrives as `RemapPlan.capsLockProxy`; unmapped presses toggle Caps Lock.
    var usesCapsLockProxy: Bool

    /// Physical modifier keys currently held (virtual key codes).
    private(set) var physical: Set<Int> = []
    private var active: [Key: Active] = [:]
    private var synthetic: [Int: Int] = [:]
    private var taps: [Key: TapState] = [:]
    private var pendingChord: PendingChord?

    enum Active: Equatable {
        /// A non-modifier key delivered with another key code.
        case rewrite(Int)
        /// The output key was posted; repeats and the release mirror it.
        case send(Key, flags: CGEventFlags)
        /// Holds a synthetic modifier key down.
        case modifier(Int)
        /// Repeats and the release are swallowed.
        case swallow
        /// A modifier key passing through as itself while its tap-alone action is pending.
        case tapPassThrough
        /// A tap-alone key held as a synthetic modifier (nil: as nothing, Caps Lock only).
        case tapHold(Int?)
    }

    struct TapState: Equatable {
        var start: TimeInterval
        var interrupted: Bool
        var remap: Remap
    }

    struct PendingChord: Equatable {
        var first: Key
        /// Modifiers held when the chord started; the second key may be pressed with or without them.
        var modifiers: Modifiers
        var flags: CGEventFlags
        var started: TimeInterval
    }

    init(table: RemapTable, tapTimeout: TimeInterval = 0.4, usesCapsLockProxy: Bool = false) {
        self.table = table
        self.tapTimeout = tapTimeout
        self.usesCapsLockProxy = usesCapsLockProxy
    }

    /// True while any key's output is held or a synthetic modifier is down.
    var hasActiveKeys: Bool { !active.isEmpty || !synthetic.isEmpty }
    var activeKeys: [Key] { Array(active.keys) }
    var isChordPending: Bool { pendingChord != nil }

    // MARK: - Input

    mutating func handle(_ e: EngineEvent) -> EngineResult {
        e.key.isModifier ? handleModifier(e) : handleKey(e)
    }

    /// A mouse button went down: it interrupts pending taps and needs the logical modifiers.
    mutating func mouseDown() -> FlagRewrite? {
        interruptTaps(except: nil)
        return flagRewrite()
    }

    /// Flags for events the engine doesn't otherwise handle (mouse buttons, scrolling).
    func currentFlagRewrite() -> FlagRewrite? { flagRewrite() }

    /// Drops physical modifiers whose release was missed: a modifier is no longer down when its
    /// device bit is absent from a later event's flags.
    mutating func sanitize(flags: CGEventFlags, except code: Int, time: TimeInterval) -> [EngineEffect] {
        guard !physical.isEmpty else { return [] }
        var effects: [EngineEffect] = []
        for held in physical where held != code {
            guard let mask = KeyCatalog.modifierInfo[held]?.deviceMask, mask != 0,
                  flags.rawValue & mask == 0 else { continue }
            effects += handle(EngineEvent(key: .keyboard(held), phase: .up, time: time, app: nil)).effects
        }
        return effects
    }

    /// Releases everything the engine holds (used on stop, pause and settings changes).
    mutating func releaseAll() -> [EngineEffect] {
        var effects: [EngineEffect] = []
        for (_, a) in active {
            if case .send(let key, let flags) = a {
                let up = key.isModifier ? flags.subtracting(key.modifier?.cgFlags ?? []) : flags
                effects.append(.key(key, down: false, flags: up, isRepeat: false))
            }
        }
        active = [:]
        taps = [:]
        pendingChord = nil
        let held = synthetic.keys.sorted()
        synthetic = [:]
        for code in held {
            effects.append(.key(.keyboard(code), down: false, flags: KeyCatalog.flags(forHeld: logicalHeld()),
                                isRepeat: false))
        }
        return effects
    }

    /// The chord's second key never came: deliver the prefix as typed.
    mutating func chordTimedOut(startedAt: TimeInterval) -> [EngineEffect] {
        guard let p = pendingChord, p.started == startedAt else { return [] }
        pendingChord = nil
        return replay(p)
    }

    // MARK: - Modifier keys

    private mutating func handleModifier(_ e: EngineEvent) -> EngineResult {
        let code = e.key.code
        switch e.phase {
        case .autorepeat:
            return result(.pass)
        case .down:
            if physical.contains(code) { return active[e.key] == nil || active[e.key] == .tapPassThrough ? result(.pass) : result(.consume) }
            physical.insert(code)
            interruptTaps(except: e.key)
            guard let r = table.keyRemap(for: e.key, app: e.app) else { return result(.pass) }
            if r.tapAlone {
                taps[e.key] = TapState(start: e.time, interrupted: false, remap: r)
                if let hold = r.holdKey, hold.isModifier, hold != e.key {
                    active[e.key] = .tapHold(hold.code)
                    return result(.consume, [pressSynthetic(hold.code)])
                }
                active[e.key] = .tapPassThrough
                return result(.pass)
            }
            return beginAction(r.action, for: e.key, extra: [])
        case .up:
            physical.remove(code)
            return release(e)
        }
    }

    // MARK: - Other keys

    private mutating func handleKey(_ e: EngineEvent) -> EngineResult {
        if e.phase == .up { return release(e) }
        if let a = active[e.key] { return repeating(a) }
        guard e.phase == .down else { return result(.pass) }
        interruptTaps(except: e.key)

        // Layer 1: key remaps.
        var logical = e.key
        if let r = table.keyRemap(for: e.key, app: e.app) {
            if r.tapAlone {
                taps[e.key] = TapState(start: e.time, interrupted: false, remap: r)
                if let hold = r.holdKey, hold.isModifier {
                    active[e.key] = .tapHold(hold.code)
                    return result(.consume, flushChord() + [pressSynthetic(hold.code)])
                }
                active[e.key] = .tapHold(nil)
                return result(.consume, flushChord())
            }
            if r.action.isPlainKey, r.action.combo?.key == .capsLock {
                active[e.key] = .swallow
                return result(.consume, flushChord() + [.toggleCapsLock])
            }
            if r.action.isPlainKey, let out = r.action.combo?.key, !out.isModifier {
                logical = out
            } else {
                let prefix = flushChord()
                var res = beginAction(r.action, for: e.key, extra: [])
                res.effects = prefix + res.effects
                return res
            }
        } else if usesCapsLockProxy && e.key == RemapPlan.capsLockProxy {
            active[e.key] = .swallow
            return result(.consume, flushChord() + [.toggleCapsLock])
        }

        // Chord second key.
        let mods = logicalModifiers()
        var effects: [EngineEffect] = []
        if let p = pendingChord {
            pendingChord = nil
            if let r = table.chord(first: p.first, second: logical, modifiers: p.modifiers, app: e.app) {
                return fire(r, key: e.key, modifiers: mods, prefix: [])
            }
            effects = replay(p)
        }

        // Layer 2: shortcut remaps on the logical key.
        if table.startsChord(logical, modifiers: mods, app: e.app) {
            pendingChord = PendingChord(first: logical, modifiers: mods, flags: outputFlags([]), started: e.time)
            active[e.key] = .swallow
            var res = result(.consume, effects)
            res.startedChord = true
            return res
        }
        if let s = table.shortcut(for: logical, modifiers: mods, app: e.app) {
            return fire(s, key: e.key, modifiers: mods, prefix: effects)
        }

        // No shortcut: deliver the (possibly remapped) key.
        if effects.isEmpty && logical.kind == .keyboard && e.key.kind == .keyboard {
            if logical == e.key { return result(.pass) }
            active[e.key] = .rewrite(logical.code)
            return result(.rewrite(logical.code))
        }
        if logical == e.key && effects.isEmpty { return EngineResult(disposition: .pass, flags: nil) }
        // Order matters after a chord replay, and media ↔ keyboard can't be rewritten in place:
        // post the key ourselves.
        let flags = outputFlags([])
        active[e.key] = .send(logical, flags: flags)
        effects.append(.key(logical, down: true, flags: flags, isRepeat: false))
        return result(.consume, effects)
    }

    // MARK: - Actions

    /// Starts a key remap's own action (key → shortcut, modifier, text, program, URL, disable).
    private mutating func beginAction(_ action: RemapAction, for key: Key, extra: Modifiers) -> EngineResult {
        switch action.kind {
        case .send:
            guard let out = action.combo else { return result(.pass) }
            if out.modifiers.isEmpty && out.key.isModifier {
                active[key] = .modifier(out.key.code)
                return result(.consume, [pressSynthetic(out.key.code)])
            }
            active[key] = .swallow  // counts as remapped away while computing the flags
            let flags = outputFlags(out.modifiers.union(extra))
            active[key] = .send(out.key, flags: flags)
            return result(.consume, [.key(out.key, down: true, flags: flags, isRepeat: false)])
        case .disable:
            active[key] = .swallow
            return result(.consume)
        case .text, .run, .openURL:
            active[key] = .swallow
            return result(.consume, [.perform(action)])
        }
    }

    /// Fires a shortcut remap. The trigger's modifiers are dropped from the output; other held
    /// modifiers carry over unless the remap requires an exact match.
    private mutating func fire(_ r: Remap, key: Key, modifiers: Modifiers, prefix: [EngineEffect]) -> EngineResult {
        var res: EngineResult
        if r.action.kind == .send, let out = r.action.combo {
            if out.modifiers.isEmpty && out.key.isModifier {
                active[key] = .modifier(out.key.code)
                res = result(.consume, [pressSynthetic(out.key.code)])
            } else {
                var extra = r.exactMatch ? [] : modifiers.subtracting(r.trigger.modifiers)
                extra.remove(.function)
                let flags = out.modifiers.union(extra).cgFlags
                active[key] = .send(out.key, flags: flags)
                res = result(.consume, [.key(out.key, down: true, flags: flags, isRepeat: false)])
            }
        } else {
            res = beginAction(r.action, for: key, extra: [])
        }
        res.effects = prefix + res.effects
        return res
    }

    /// Auto-repeat (or a duplicate press) of a key whose press was transformed.
    private func repeating(_ a: Active) -> EngineResult {
        switch a {
        case .rewrite(let code):
            return result(.rewrite(code))
        case .send(let key, let flags):
            if key.isModifier { return result(.consume) }
            return result(.consume, [.key(key, down: true, flags: flags, isRepeat: true)])
        case .modifier, .swallow, .tapPassThrough, .tapHold:
            return result(.consume)
        }
    }

    /// Release of any key: mirrors what its press did.
    private mutating func release(_ e: EngineEvent) -> EngineResult {
        guard let a = active.removeValue(forKey: e.key) else { return result(.pass) }
        switch a {
        case .rewrite(let code):
            return result(.rewrite(code))
        case .send(let key, let flags):
            if key.isModifier {
                return result(.consume, [.key(key, down: false, flags: flags.subtracting(key.modifier?.cgFlags ?? []),
                                              isRepeat: false)])
            }
            return result(.consume, [.key(key, down: false, flags: flags, isRepeat: false)])
        case .modifier(let code):
            return result(.consume, releaseSynthetic(code).map { [$0] } ?? [])
        case .swallow:
            return result(.consume)
        case .tapPassThrough:
            return result(.pass, tapEffects(for: e.key, at: e.time, holdsNothing: false))
        case .tapHold(let code):
            var effects: [EngineEffect] = []
            if let code, let up = releaseSynthetic(code) { effects.append(up) }
            effects += tapEffects(for: e.key, at: e.time, holdsNothing: code == nil)
            return result(.consume, effects)
        }
    }

    /// The tap-alone decision when a tap-alone key is released.
    private mutating func tapEffects(for key: Key, at time: TimeInterval, holdsNothing: Bool) -> [EngineEffect] {
        guard let t = taps.removeValue(forKey: key) else { return [] }
        let quick = time - t.start <= tapTimeout
        if !t.interrupted && quick { return actionEffects(t.remap.action) }
        // Caps Lock with no hold modifier: a long press keeps its normal job.
        if holdsNothing && !t.interrupted && usesCapsLockProxy && key == RemapPlan.capsLockProxy {
            return [.toggleCapsLock]
        }
        return []
    }

    /// A complete press-and-release of an action (for taps).
    private func actionEffects(_ action: RemapAction) -> [EngineEffect] {
        switch action.kind {
        case .send:
            guard let out = action.combo else { return [] }
            let base = KeyCatalog.flags(forHeld: logicalHeld())
            if out.modifiers.isEmpty && out.key.isModifier {
                let with = base.union(KeyCatalog.flags(forHeld: [out.key.code]))
                return [.key(out.key, down: true, flags: with, isRepeat: false),
                        .key(out.key, down: false, flags: base, isRepeat: false)]
            }
            let flags = base.union(out.modifiers.cgFlags)
            return [.key(out.key, down: true, flags: flags, isRepeat: false),
                    .key(out.key, down: false, flags: flags, isRepeat: false)]
        case .text, .run, .openURL:
            return [.perform(action)]
        case .disable:
            return []
        }
    }

    // MARK: - Chords

    private mutating func flushChord() -> [EngineEffect] {
        guard let p = pendingChord else { return [] }
        pendingChord = nil
        return replay(p)
    }

    private func replay(_ p: PendingChord) -> [EngineEffect] {
        [.key(p.first, down: true, flags: p.flags, isRepeat: false),
         .key(p.first, down: false, flags: p.flags, isRepeat: false)]
    }

    // MARK: - Modifier state

    private mutating func interruptTaps(except key: Key?) {
        guard !taps.isEmpty else { return }
        for k in taps.keys where k != key { taps[k]?.interrupted = true }
    }

    private mutating func pressSynthetic(_ code: Int) -> EngineEffect {
        synthetic[code, default: 0] += 1
        return .key(.keyboard(code), down: true, flags: KeyCatalog.flags(forHeld: logicalHeld()), isRepeat: false)
    }

    private mutating func releaseSynthetic(_ code: Int) -> EngineEffect? {
        guard let n = synthetic[code] else { return nil }
        if n > 1 { synthetic[code] = n - 1; return nil }
        synthetic[code] = nil
        return .key(.keyboard(code), down: false, flags: KeyCatalog.flags(forHeld: logicalHeld()), isRepeat: false)
    }

    /// A physical modifier whose press was consumed (remapped to something else).
    private func isRemappedAway(_ code: Int) -> Bool {
        guard let a = active[.keyboard(code)] else { return false }
        return a != .tapPassThrough
    }

    /// Modifier keys apps should consider held: physical ones not remapped away, plus synthetic ones.
    func logicalHeld() -> [Int] {
        var held: [Int] = []
        for code in physical where !isRemappedAway(code) { held.append(code) }
        for code in synthetic.keys where !held.contains(code) { held.append(code) }
        return held
    }

    func logicalModifiers() -> Modifiers {
        var m: Modifiers = []
        for code in physical where !isRemappedAway(code) {
            if let mod = KeyCatalog.modifierInfo[code]?.modifier { m.insert(mod) }
        }
        for code in synthetic.keys {
            if let mod = KeyCatalog.modifierInfo[code]?.modifier { m.insert(mod) }
        }
        return m
    }

    /// Flags for a posted output: the logical modifiers plus the output's own.
    private func outputFlags(_ extra: Modifiers) -> CGEventFlags {
        KeyCatalog.flags(forHeld: logicalHeld()).union(extra.cgFlags)
    }

    /// Needed only while a held modifier is remapped away or a synthetic one is down.
    private func flagRewrite() -> FlagRewrite? {
        if synthetic.isEmpty && active.isEmpty { return nil }
        var discrepancy = !synthetic.isEmpty
        var fnAway = false
        for code in physical where isRemappedAway(code) {
            discrepancy = true
            if code == kVK_Function { fnAway = true }
        }
        guard discrepancy else { return nil }
        var clear = KeyCatalog.managedFlagMask
        if fnAway { clear |= CGEventFlags.maskSecondaryFn.rawValue }
        return FlagRewrite(clear: clear, set: KeyCatalog.flags(forHeld: logicalHeld()).rawValue)
    }

    private func result(_ d: EngineResult.Disposition, _ effects: [EngineEffect] = []) -> EngineResult {
        EngineResult(disposition: d, flags: d == .consume ? nil : flagRewrite(), effects: effects)
    }
}
