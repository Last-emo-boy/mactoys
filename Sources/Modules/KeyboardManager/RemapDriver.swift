import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Connects `RemapEngine` to the shared event tap: decodes events, applies the engine's
/// decisions and posts its output. Installed only while there are remaps for the tap.
@MainActor
final class RemapDriver {
    static let tapID = "keyboardmanager"
    /// Ahead of other modules so they see remapped keys.
    static let priority = 100

    private var engine: RemapEngine?
    private var chordTimeout: TimeInterval = 1
    private var frontmostApp: String?
    private var activationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var chordTimer: Timer?
    /// Keys found released once by the watchdog; released for good on the second look.
    private var suspectedStuck: Set<Key> = []
    private let source = CGEventSource(stateID: .hidSystemState)

    var isInstalled: Bool { engine != nil }

    /// (Re)installs the tap for a plan. Anything held from the previous plan is released first.
    func install(_ plan: RemapPlan, tapTimeout: TimeInterval, chordTimeout: TimeInterval) {
        releaseAll()
        guard !plan.tapRemaps.isEmpty else { uninstall(); return }
        engine = RemapEngine(table: RemapTable(plan.tapRemaps), tapTimeout: tapTimeout,
                             usesCapsLockProxy: plan.usesCapsLockProxy)
        self.chordTimeout = chordTimeout
        if activationObserver == nil {
            frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.frontmostApp = app?.bundleIdentifier }
            }
        }
        InputTap.shared.add(Self.tapID, priority: Self.priority,
                            events: [.keyDown, .keyUp, .flagsChanged, InputTap.systemDefined,
                                     .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                     .leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    func uninstall() {
        releaseAll()
        InputTap.shared.remove(Self.tapID)
        engine = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        watchdog?.invalidate()
        watchdog = nil
        chordTimer?.invalidate()
        chordTimer = nil
        suspectedStuck = []
    }

    /// Lets go of every key and modifier the engine holds, so nothing stays stuck.
    func releaseAll() {
        guard var e = engine else { return }
        let effects = e.releaseAll()
        engine = e
        post(effects)
    }

    // MARK: - Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        guard engine != nil else { return .pass }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let phase: EngineEvent.Phase = type == .keyUp ? .up : (isRepeat ? .autorepeat : .down)
            return run(EngineEvent(key: .keyboard(code), phase: phase, time: now, app: frontmostApp), event)
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let info = KeyCatalog.modifierInfo[code] else { return applyFlags(event) }
            let down = info.deviceMask != 0 ? event.flags.rawValue & info.deviceMask != 0
                                            : event.flags.contains(.maskSecondaryFn)
            let missed = engine?.sanitize(flags: event.flags, except: code, time: now) ?? []
            post(missed)
            return run(EngineEvent(key: .keyboard(code), phase: down ? .down : .up, time: now, app: frontmostApp), event)
        case InputTap.systemDefined:
            guard let media = Self.mediaKey(event) else { return .pass }
            let phase: EngineEvent.Phase = media.down ? (media.isRepeat ? .autorepeat : .down) : .up
            return run(EngineEvent(key: .media(media.code), phase: phase, time: now, app: frontmostApp), event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let rewrite = engine?.mouseDown() { event.flags = rewrite.apply(to: event.flags) }
            return .pass
        default:
            return applyFlags(event)
        }
    }

    private func applyFlags(_ event: CGEvent) -> TapDecision {
        if let rewrite = engine?.currentFlagRewrite() { event.flags = rewrite.apply(to: event.flags) }
        return .pass
    }

    private func run(_ input: EngineEvent, _ event: CGEvent) -> TapDecision {
        guard var e = engine else { return .pass }
        let r = e.handle(input)
        engine = e
        let decision: TapDecision
        switch r.disposition {
        case .pass:
            if let f = r.flags { event.flags = f.apply(to: event.flags) }
            decision = .pass
        case .rewrite(let code):
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            if let f = r.flags { event.flags = f.apply(to: event.flags) }
            decision = .pass
        case .consume:
            decision = .consume
        }
        if !r.effects.isEmpty { post(r.effects) }
        if r.startedChord { scheduleChordTimeout(startedAt: input.time) }
        if e.hasActiveKeys && watchdog == nil { startWatchdog() }
        return decision
    }

    // MARK: - Output

    private func post(_ effects: [EngineEffect]) {
        for effect in effects {
            switch effect {
            case .key(let key, let down, let flags, let isRepeat):
                postKey(key, down: down, flags: flags, isRepeat: isRepeat)
            case .toggleCapsLock:
                CapsLock.toggle()
            case .perform(let action):
                // Never block the tap: launching and typing happen after the event is delivered.
                DispatchQueue.main.async { ActionRunner.perform(action) }
            }
        }
    }

    private func postKey(_ key: Key, down: Bool, flags: CGEventFlags, isRepeat: Bool) {
        switch key.kind {
        case .media:
            Self.postMedia(key.code, down: down, isRepeat: isRepeat)
        case .keyboard:
            if key == .capsLock {
                if down && !isRepeat { CapsLock.toggle() }
                return
            }
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.code), keyDown: down) else { return }
            var f = flags
            if KeyCodes.isFunctionKey(UInt16(key.code)) { f.insert(.maskSecondaryFn) }
            if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(key.code) { f.insert(.maskNumericPad) }
            // Keep the bits CGEvent sets itself (non-coalesced etc.), replace the modifier bits.
            let keep = e.flags.rawValue & ~(KeyCatalog.managedFlagMask | CGEventFlags.maskSecondaryFn.rawValue)
            e.flags = CGEventFlags(rawValue: keep | f.rawValue)
            if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            KeySynth.post(e)
        }
    }

    /// Posts an `NSSystemDefined` media key event (subtype 8, `NX_KEYTYPE_*` code in data1).
    static func postMedia(_ code: Int, down: Bool, isRepeat: Bool) {
        let state = down ? 0xA : 0xB
        let data1 = (code << 16) | (state << 8) | (isRepeat ? 1 : 0)
        guard let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                          modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                          context: nil, subtype: 8, data1: data1, data2: -1),
              let cg = ns.cgEvent else { return }
        KeySynth.post(cg)
    }

    /// Decodes an auxiliary control button (media key) event.
    static func mediaKey(_ event: CGEvent) -> (code: Int, down: Bool, isRepeat: Bool)? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
        let data1 = ns.data1
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return ((data1 & 0xFFFF_0000) >> 16, state == 0xA, data1 & 0x1 != 0)
    }

    // MARK: - Timers

    private func scheduleChordTimeout(startedAt: TimeInterval) {
        chordTimer?.invalidate()
        chordTimer = Timer.scheduledTimer(withTimeInterval: chordTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var e = self.engine else { return }
                let effects = e.chordTimedOut(startedAt: startedAt)
                self.engine = e
                self.post(effects)
            }
        }
    }

    /// Releases outputs whose physical key is no longer down (a missed key-up after the tap was
    /// disabled by a timeout, secure input, or sleep), so no key or modifier stays stuck.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStuckKeys() }
        }
    }

    private func checkStuckKeys() {
        guard var e = engine, e.hasActiveKeys else {
            watchdog?.invalidate()
            watchdog = nil
            suspectedStuck = []
            return
        }
        var effects: [EngineEffect] = []
        let now = ProcessInfo.processInfo.systemUptime
        for key in e.activeKeys where key.kind == .keyboard {
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.code)) {
                suspectedStuck.remove(key)
            } else if suspectedStuck.remove(key) != nil {
                effects += e.handle(EngineEvent(key: key, phase: .up, time: now, app: frontmostApp)).effects
            } else {
                suspectedStuck.insert(key)
            }
        }
        engine = e
        post(effects)
    }
}
