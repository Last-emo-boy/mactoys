import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import KeyboardManager
@testable import MacToysCore

private let xcode = "com.apple.dt.Xcode"
private let safari = "com.apple.Safari"
private let kA = Key.keyboard(kVK_ANSI_A)
private let kB = Key.keyboard(kVK_ANSI_B)
private let kK = Key.keyboard(kVK_ANSI_K)
private let kX = Key.keyboard(kVK_ANSI_X)
private let kLeftCtrl = Key.keyboard(kVK_Control)
private let kLeftShift = Key.keyboard(kVK_Shift)
private let kLeftOption = Key.keyboard(kVK_Option)
private let kRightCmd = Key.keyboard(kVK_RightCommand)

private func down(_ k: Key, _ t: TimeInterval = 0, app: String? = nil) -> EngineEvent {
    EngineEvent(key: k, phase: .down, time: t, app: app)
}

private func up(_ k: Key, _ t: TimeInterval = 0, app: String? = nil) -> EngineEvent {
    EngineEvent(key: k, phase: .up, time: t, app: app)
}

private func engine(_ remaps: [Remap], timeout: TimeInterval = 0.4) -> RemapEngine {
    let plan = RemapPlan.make(remaps, useSystemMapping: false)
    return RemapEngine(table: RemapTable(plan.tapRemaps), tapTimeout: timeout, usesCapsLockProxy: plan.usesCapsLockProxy)
}

/// The key effects only (down/up, key, generic modifiers), for compact assertions.
private func keys(_ effects: [EngineEffect]) -> [String] {
    effects.map {
        switch $0 {
        case .key(let k, let d, let f, let r):
            let mods = Modifiers(f).symbols.joined()
            return "\(mods)\(k.name)\(d ? "↓" : "↑")\(r ? "r" : "")"
        case .toggleCapsLock: return "capslock"
        case .perform(let a): return "perform:\(a.kind.rawValue)"
        }
    }
}

@Suite struct KeyboardManagerResolutionTests {
    @Test func appSpecificRemapWinsOverGlobal() {
        let global = Remap.shortcut(KeyCombo([.option], kK), to: .send(kA))
        let scoped = Remap.shortcut(KeyCombo([.option], kK), to: .send(kB), apps: [xcode])
        let table = RemapTable([global, scoped])
        #expect(table.shortcut(for: kK, modifiers: [.option], app: xcode)?.id == scoped.id)
        #expect(table.shortcut(for: kK, modifiers: [.option], app: safari)?.id == global.id)
        #expect(table.shortcut(for: kK, modifiers: [.option], app: nil)?.id == global.id)
        // Bundle ids match case-insensitively.
        #expect(table.shortcut(for: kK, modifiers: [.option], app: "COM.APPLE.DT.XCODE")?.id == scoped.id)
    }

    @Test func keyRemapScoping() {
        let global = Remap.key(kA, to: .send(kB))
        let scoped = Remap.key(kA, to: .disable, apps: [xcode])
        let table = RemapTable([scoped, global])
        #expect(table.keyRemap(for: kA, app: xcode)?.id == scoped.id)
        #expect(table.keyRemap(for: kA, app: safari)?.id == global.id)
        #expect(table.keyRemap(for: kB, app: safari) == nil)
    }

    @Test func extraModifiersMatchUnlessExact() {
        let loose = Remap.shortcut(KeyCombo([.option], kK), to: .send(kA))
        let exact = Remap.shortcut(KeyCombo([.option], kX), to: .send(kA), exactMatch: true)
        let table = RemapTable([loose, exact])
        #expect(table.shortcut(for: kK, modifiers: [.option, .shift], app: nil)?.id == loose.id)
        #expect(table.shortcut(for: kK, modifiers: [.shift], app: nil) == nil)
        #expect(table.shortcut(for: kX, modifiers: [.option], app: nil)?.id == exact.id)
        #expect(table.shortcut(for: kX, modifiers: [.option, .shift], app: nil) == nil)
    }

    @Test func mostSpecificShortcutWins() {
        let short = Remap.shortcut(KeyCombo([.option], kK), to: .send(kA))
        let long = Remap.shortcut(KeyCombo([.option, .shift], kK), to: .send(kB))
        let table = RemapTable([short, long])
        #expect(table.shortcut(for: kK, modifiers: [.option, .shift], app: nil)?.id == long.id)
        #expect(table.shortcut(for: kK, modifiers: [.option, .shift, .command], app: nil)?.id == long.id)
        #expect(table.shortcut(for: kK, modifiers: [.option], app: nil)?.id == short.id)
    }

    @Test func fnIsIgnoredUnlessPartOfTheShortcut() {
        let left = Key.keyboard(kVK_LeftArrow)
        let exact = Remap.shortcut(KeyCombo([.option], left), to: .send(kA), exactMatch: true)
        let table = RemapTable([exact])
        // macOS sets fn on arrow keys by itself.
        #expect(table.shortcut(for: left, modifiers: [.option, .function], app: nil)?.id == exact.id)
        let withFn = Remap.shortcut(KeyCombo([.function], kA), to: .send(kB), exactMatch: true)
        #expect(RemapTable([withFn]).shortcut(for: kA, modifiers: [], app: nil) == nil)
        #expect(RemapTable([withFn]).shortcut(for: kA, modifiers: [.function], app: nil) != nil)
    }

    @Test func validation() {
        #expect(Remap.shortcut(KeyCombo([], kK), to: .send(kA)).validationError != nil)
        #expect(Remap.shortcut(KeyCombo([.command], kLeftShift), to: .send(kA)).validationError != nil)
        #expect(Remap.key(kA, to: .send(kA)).validationError != nil)
        #expect(Remap.key(kA, to: .type("")).validationError != nil)
        var tap = Remap.key(kA, to: .send(.escape))
        tap.tapAlone = true
        #expect(tap.validationError != nil)  // non-modifier needs a hold modifier
        tap.holdKey = kLeftCtrl
        #expect(tap.validationError == nil)
        var caps = Remap.key(.capsLock, to: .send(.escape))
        caps.tapAlone = true
        #expect(caps.validationError == nil)  // Caps Lock: held toggles Caps Lock
    }

    @Test func orphanedKeys() {
        #expect(OrphanCheck.orphans(in: [.key(kA, to: .send(kB))]) == [kA])
        #expect(OrphanCheck.orphans(in: [.key(kA, to: .send(kB)), .key(kB, to: .send(kA))]).isEmpty)
        #expect(OrphanCheck.orphans(in: [.key(.capsLock, to: .send(.escape))]).isEmpty)
        #expect(OrphanCheck.orphans(in: [.key(kA, to: .send(kB), apps: [xcode])]).isEmpty)
    }
}

// Key names come from the keyboard layout (TIS), which must be used from one thread.
@Suite @MainActor struct KeyboardManagerEngineTests {
    @Test func keyToKeyRewritesInPlaceAndPairsKeyUp() {
        var e = engine([.key(kA, to: .send(kB), apps: [xcode])])
        #expect(e.handle(down(kA, app: xcode)).disposition == .rewrite(kVK_ANSI_B))
        // Repeats keep the same output.
        #expect(e.handle(EngineEvent(key: kA, phase: .autorepeat, time: 0.5, app: xcode)).disposition == .rewrite(kVK_ANSI_B))
        // The app changed while the key was held: the release still pairs with B.
        #expect(e.handle(up(kA, 1, app: safari)).disposition == .rewrite(kVK_ANSI_B))
        // Outside Xcode A is A.
        #expect(e.handle(down(kA, 2, app: safari)).disposition == .pass)
        #expect(e.handle(up(kA, 2.1, app: xcode)).disposition == .pass)
    }

    @Test func shortcutRemapDropsTriggerModifiersAndCarriesExtras() {
        let r = Remap.shortcut(KeyCombo([.option], kK), to: .send(KeyCombo([.command], kK)))
        var e = engine([r])
        _ = e.handle(down(kLeftOption))
        _ = e.handle(down(kLeftShift))
        let res = e.handle(down(kK))
        #expect(res.disposition == .consume)
        #expect(keys(res.effects) == ["⇧⌘K↓"])
        let rep = e.handle(EngineEvent(key: kK, phase: .autorepeat, time: 0.3, app: nil))
        #expect(keys(rep.effects) == ["⇧⌘K↓r"])
        // Releasing a modifier first doesn't change what the key's release sends.
        _ = e.handle(up(kLeftShift))
        #expect(keys(e.handle(up(kK)).effects) == ["⇧⌘K↑"])
    }

    @Test func layeredKeyThenShortcutRemap() {
        // A → B, then ⌘B → text: pressing ⌘A types the text (key remaps apply first).
        var e = engine([.key(kA, to: .send(kB)), .shortcut(KeyCombo([.command], kB), to: .type("hi"))])
        _ = e.handle(down(.keyboard(kVK_Command)))
        let res = e.handle(down(kA))
        #expect(keys(res.effects) == ["perform:text"])
        #expect(e.handle(up(kA)).disposition == .consume)
    }

    @Test func modifierRemappedAwayIsStrippedFromOtherKeys() {
        // Right ⌘ → F18 (app-specific, so it goes through the tap).
        var e = engine([.key(kRightCmd, to: .send(.keyboard(kVK_F18)), apps: [xcode])])
        let press = e.handle(down(kRightCmd, app: xcode))
        #expect(press.disposition == .consume)
        #expect(keys(press.effects) == ["F18↓"])
        let a = e.handle(down(kA, app: xcode))
        #expect(a.disposition == .pass)
        let flags = a.flags?.apply(to: [.maskCommand, CGEventFlags(rawValue: 0x10)]) ?? []
        #expect(!flags.contains(.maskCommand))
        #expect(flags.rawValue & 0x10 == 0)  // right-⌘ device bit gone too
        _ = e.handle(up(kA, app: xcode))
        #expect(keys(e.handle(up(kRightCmd, app: safari)).effects) == ["F18↑"])
        #expect(!e.hasActiveKeys)
    }

    @Test func tapAloneCapsLockTapSendsEscape() {
        var caps = Remap.key(.capsLock, to: .send(.escape))
        caps.tapAlone = true
        caps.holdKey = kLeftCtrl
        var e = engine([caps])
        let proxy = RemapPlan.capsLockProxy
        let press = e.handle(down(proxy, 0))
        #expect(press.disposition == .consume)
        #expect(keys(press.effects) == ["⌃Left ⌃↓"])
        let release = e.handle(up(proxy, 0.15))
        #expect(keys(release.effects) == ["Left ⌃↑", "esc↓", "esc↑"])
        #expect(!e.hasActiveKeys)
    }

    @Test func tapAloneHeldTooLongActsOnlyAsModifier() {
        var caps = Remap.key(.capsLock, to: .send(.escape))
        caps.tapAlone = true
        caps.holdKey = kLeftCtrl
        var e = engine([caps], timeout: 0.4)
        _ = e.handle(down(RemapPlan.capsLockProxy, 0))
        #expect(keys(e.handle(up(RemapPlan.capsLockProxy, 0.6)).effects) == ["Left ⌃↑"])
    }

    @Test func tapAloneInterruptedByAnotherKeyGivesTheModifier() {
        var caps = Remap.key(.capsLock, to: .send(.escape))
        caps.tapAlone = true
        caps.holdKey = kLeftCtrl
        var e = engine([caps])
        _ = e.handle(down(RemapPlan.capsLockProxy, 0))
        let a = e.handle(down(kA, 0.05))
        #expect(a.disposition == .pass)
        #expect(a.flags?.apply(to: []).contains(.maskControl) == true)
        _ = e.handle(up(kA, 0.08))
        #expect(keys(e.handle(up(RemapPlan.capsLockProxy, 0.1)).effects) == ["Left ⌃↑"])
    }

    @Test func tapAloneMouseClickInterrupts() {
        var shift = Remap.key(kLeftShift, to: .send(KeyCombo([.shift], .keyboard(kVK_ANSI_9))))
        shift.tapAlone = true
        var e = engine([shift])
        #expect(e.handle(down(kLeftShift, 0)).disposition == .pass)
        _ = e.mouseDown()
        let release = e.handle(up(kLeftShift, 0.1))
        #expect(release.disposition == .pass)
        #expect(release.effects.isEmpty)
    }

    @Test func tapAloneModifierPassesThroughAndTapsOutput() {
        // Left ⇧ tapped alone types "(" (⇧9); held it's a normal shift.
        var shift = Remap.key(kLeftShift, to: .send(KeyCombo([.shift], .keyboard(kVK_ANSI_9))))
        shift.tapAlone = true
        var e = engine([shift])
        #expect(e.handle(down(kLeftShift, 0)).disposition == .pass)
        let release = e.handle(up(kLeftShift, 0.12))
        #expect(release.disposition == .pass)
        #expect(keys(release.effects) == ["⇧9↓", "⇧9↑"])
        // Held with another key: no tap output, shift passes through.
        _ = e.handle(down(kLeftShift, 1))
        #expect(e.handle(down(kA, 1.05)).disposition == .pass)
        _ = e.handle(up(kA, 1.1))
        #expect(e.handle(up(kLeftShift, 1.15)).effects.isEmpty)
    }

    @Test func capsLockWithoutHoldModifierTogglesWhenHeld() {
        var caps = Remap.key(.capsLock, to: .send(.escape))
        caps.tapAlone = true
        var e = engine([caps])
        _ = e.handle(down(RemapPlan.capsLockProxy, 0))
        #expect(keys(e.handle(up(RemapPlan.capsLockProxy, 0.1)).effects) == ["esc↓", "esc↑"])
        _ = e.handle(down(RemapPlan.capsLockProxy, 1))
        #expect(keys(e.handle(up(RemapPlan.capsLockProxy, 1.8)).effects) == ["capslock"])
    }

    @Test func capsLockProxyOutsideScopeStillTogglesCapsLock() {
        var e = engine([.key(.capsLock, to: .send(.escape), apps: [xcode])])
        #expect(keys(e.handle(down(RemapPlan.capsLockProxy, app: safari)).effects) == ["capslock"])
        #expect(e.handle(up(RemapPlan.capsLockProxy, app: safari)).disposition == .consume)
        #expect(e.handle(down(RemapPlan.capsLockProxy, app: xcode)).disposition == .rewrite(kVK_Escape))
    }

    @Test func keyToModifierAndReleaseAllLeavesNothingStuck() {
        // F18 → Left ⌃ and F19 → Left ⌃: the synthetic ⌃ is reference-counted.
        let f18 = Key.keyboard(kVK_F18), f19 = Key.keyboard(kVK_F19)
        var e = engine([.key(f18, to: .send(kLeftCtrl)), .key(f19, to: .send(kLeftCtrl))])
        #expect(keys(e.handle(down(f18)).effects) == ["⌃Left ⌃↓"])
        _ = e.handle(down(f19))
        #expect(e.handle(up(f18)).effects.isEmpty)  // still held through F19
        #expect(e.logicalModifiers() == [.control])
        let released = e.releaseAll()
        #expect(keys(released) == ["Left ⌃↑"])
        #expect(!e.hasActiveKeys)
        #expect(e.logicalModifiers().isEmpty)
        // A late key-up after releaseAll is passed through without posting anything.
        #expect(e.handle(up(f19)) == EngineResult.pass)
    }

    @Test func sanitizeReleasesMissedModifierUp() {
        var e = engine([.key(kRightCmd, to: .send(kLeftOption), apps: [])])
        _ = e.handle(down(kRightCmd))
        #expect(e.logicalModifiers() == [.option])
        // A later event without the right-⌘ device bit: its release was missed.
        let effects = e.sanitize(flags: [], except: kVK_Shift, time: 1)
        #expect(keys(effects) == ["Left ⌥↑"])
        #expect(!e.hasActiveKeys)
    }

    @Test func chordCompletes() {
        let v = Key.keyboard(kVK_ANSI_V), u = Key.keyboard(kVK_ANSI_U)
        var chord = Remap.shortcut(KeyCombo([.control, .shift], v), to: .send(.media(0)))
        chord.chord = u
        var e = engine([chord])
        _ = e.handle(down(kLeftCtrl))
        _ = e.handle(down(kLeftShift))
        let first = e.handle(down(v, 0))
        #expect(first.disposition == .consume)
        #expect(first.startedChord)
        #expect(e.handle(up(v, 0.1)).disposition == .consume)
        let second = e.handle(down(u, 0.3))
        #expect(keys(second.effects) == ["Volume Up↓"])
        #expect(keys(e.handle(up(u, 0.35)).effects) == ["Volume Up↑"])
    }

    @Test func chordMismatchAndTimeoutReplayPrefix() {
        let v = Key.keyboard(kVK_ANSI_V), u = Key.keyboard(kVK_ANSI_U)
        var chord = Remap.shortcut(KeyCombo([.control, .shift], v), to: .type("x"))
        chord.chord = u
        var e = engine([chord])
        _ = e.handle(down(kLeftCtrl))
        _ = e.handle(down(kLeftShift))
        _ = e.handle(down(v, 0))
        _ = e.handle(up(v, 0.1))
        let other = e.handle(down(kX, 0.2))
        #expect(other.disposition == .consume)
        #expect(keys(other.effects) == ["⌃⇧V↓", "⌃⇧V↑", "⌃⇧X↓"])
        #expect(keys(e.handle(up(kX, 0.25)).effects) == ["⌃⇧X↑"])
        // Timeout.
        _ = e.handle(down(v, 1))
        #expect(e.isChordPending)
        #expect(e.chordTimedOut(startedAt: 0.5).isEmpty)  // stale timer
        #expect(keys(e.chordTimedOut(startedAt: 1)) == ["⌃⇧V↓", "⌃⇧V↑"])
        #expect(!e.isChordPending)
    }

    @Test func mediaKeyRemaps() {
        var e = engine([.key(.media(16), to: .send(.keyboard(kVK_F8))), .key(.keyboard(kVK_F5), to: .send(.media(16)))])
        #expect(keys(e.handle(down(.media(16))).effects) == ["F8↓"])
        #expect(keys(e.handle(up(.media(16))).effects) == ["F8↑"])
        #expect(keys(e.handle(down(.keyboard(kVK_F5))).effects) == ["Play/Pause↓"])
        #expect(keys(e.handle(up(.keyboard(kVK_F5))).effects) == ["Play/Pause↑"])
        #expect(e.handle(down(.media(0))).disposition == .pass)
    }

    @Test func actionsFireOnceOnPress() {
        var e = engine([.shortcut(KeyCombo([.control, .option], .keyboard(kVK_ANSI_N)),
                                  to: .launch(RunSpec(path: "/System/Applications/Notes.app")))])
        _ = e.handle(down(kLeftCtrl))
        _ = e.handle(down(kLeftOption))
        let n = Key.keyboard(kVK_ANSI_N)
        #expect(keys(e.handle(down(n)).effects) == ["perform:run"])
        #expect(e.handle(EngineEvent(key: n, phase: .autorepeat, time: 0.4, app: nil)).effects.isEmpty)
        #expect(e.handle(up(n)).effects.isEmpty)
    }
}

@Suite struct KeyboardManagerPlanTests {
    @Test func globalPlainKeyRemapsGoToTheSystemMapping() throws {
        let plan = RemapPlan.make([.key(.capsLock, to: .send(.escape)), .key(kRightCmd, to: .send(.keyboard(kVK_F18)))],
                                  useSystemMapping: true)
        #expect(plan.tapRemaps.isEmpty)
        #expect(!plan.usesCapsLockProxy)
        #expect(plan.systemMappings == [SystemKeyMapping.Entry(src: 0x7_0000_0039, dst: 0x7_0000_0029),
                                        SystemKeyMapping.Entry(src: 0x7_0000_00E7, dst: 0x7_0000_006D)])
    }

    @Test func remapsNeedingTheTapStayThere() {
        var tap = Remap.key(.capsLock, to: .send(.escape))
        tap.tapAlone = true
        tap.holdKey = kLeftCtrl
        let scoped = Remap.key(kA, to: .send(kB), apps: [xcode])
        let global = Remap.key(kA, to: .send(kX))  // same key also has an app remap
        let toShortcut = Remap.key(.keyboard(kVK_F13), to: .send(KeyCombo([.command], kK)))
        let plan = RemapPlan.make([tap, scoped, global, toShortcut], useSystemMapping: true)
        #expect(plan.tapRemaps.count == 4)
        #expect(plan.usesCapsLockProxy)
        #expect(plan.tapRemaps.first?.trigger.key == RemapPlan.capsLockProxy)
        #expect(plan.systemMappings == [SystemKeyMapping.Entry(src: 0x7_0000_0039, dst: 0x7_0000_006F)])
    }

    @Test func systemMappingCanBeTurnedOff() {
        let plan = RemapPlan.make([.key(kA, to: .send(kB))], useSystemMapping: false)
        #expect(plan.systemMappings.isEmpty)
        #expect(plan.tapRemaps.count == 1)
    }

    @Test func disabledAndInvalidRemapsAreDropped() {
        var off = Remap.key(kA, to: .send(kB))
        off.isEnabled = false
        let invalid = Remap.shortcut(KeyCombo([], kK), to: .send(kA))
        let plan = RemapPlan.make([off, invalid], useSystemMapping: true)
        #expect(plan.tapRemaps.isEmpty && plan.systemMappings.isEmpty)
    }

    @Test func hidUsagesRoundTrip() {
        for code in KeyCatalog.hidKeyboardUsage.keys {
            let key = Key.keyboard(code)
            #expect(KeyCatalog.hidUsage(for: key).flatMap(KeyCatalog.key(forHIDUsage:)) == key)
        }
        #expect(KeyCatalog.hidUsage(for: .keyboard(kVK_Function)) == 0xFF_0000_0003)
        #expect(KeyCatalog.hidUsage(for: .media(0)) == nil)
    }

    @Test func hidutilOutputParsing() {
        let output = """
        RegistryID  Key                   Value
        100001007   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771296;
                HIDKeyboardModifierMappingSrc = 30064771299;
            }
        )
        100001008   UserKeyMapping   (null)
        """
        #expect(SystemKeyMapping.parse(output) == [SystemKeyMapping.Entry(src: 30064771129, dst: 30064771113),
                                                   SystemKeyMapping.Entry(src: 30064771299, dst: 30064771296)])
        #expect(SystemKeyMapping.parse("RegistryID  Key  Value\n100001007   UserKeyMapping   (null)\n").isEmpty)
        #expect(SystemKeyMapping.json([SystemKeyMapping.Entry(src: 1, dst: 2)])
                == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":1,\"HIDKeyboardModifierMappingDst\":2}]}")
        #expect(SystemKeyMapping.json([]) == "{\"UserKeyMapping\":[]}")
    }
}

@Suite struct KeyboardManagerPersistenceTests {
    @Test func profileFileRoundTrip() throws {
        let profile = RemapProfile(name: "Work", remaps: SampleRemaps.design)
        let data = try RemapProfileFile(profile: profile).encoded()
        let back = try RemapProfileFile.decode(data)
        #expect(back == profile)
    }

    @Test func importIsTolerantOfMissingFields() throws {
        let json = """
        {"name": "Hand written", "remaps": [
          {"kind": "key", "trigger": {"modifiers": 0, "key": {"kind": "keyboard", "code": 57}},
           "action": {"kind": "send", "combo": {"modifiers": 0, "key": {"kind": "keyboard", "code": 53}}}}
        ]}
        """
        let p = try RemapProfileFile.decode(Data(json.utf8))
        #expect(p.name == "Hand written")
        #expect(p.remaps.count == 1)
        #expect(p.remaps[0].isEnabled)
        #expect(p.remaps[0].apps.isEmpty)
        #expect(p.remaps[0].action.combo?.key == .escape)
        #expect(throws: (any Error).self) { try RemapProfileFile.decode(Data("{\"format\":\"other\",\"version\":1,\"profile\":{}}".utf8)) }
        #expect(throws: (any Error).self) { try RemapProfileFile.decode(Data("[1,2]".utf8)) }
    }

    @Test @MainActor func clearedShortcutStaysCleared() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = KeyboardManagerSettings()
        s.toggleShortcut = Shortcut(kVK_ANSI_K, [.control, .option])
        store.save(s, id: "km")
        var loaded = store.load("km", default: KeyboardManagerSettings())
        #expect(loaded.toggleShortcut == Shortcut(kVK_ANSI_K, [.control, .option]))
        loaded.toggleShortcut = nil
        store.save(loaded, id: "km")
        var withDefault = KeyboardManagerSettings()
        withDefault.toggleShortcut = Shortcut(kVK_ANSI_J, [.control])
        #expect(store.load("km", default: withDefault).toggleShortcut == nil)
    }

    @Test func activeProfileRemaps() {
        var s = KeyboardManagerSettings()
        let second = RemapProfile(name: "Games", remaps: [.key(kA, to: .disable)])
        s.profiles.append(second)
        #expect(s.remaps.isEmpty)
        s.activeProfileID = second.id
        #expect(s.remaps.count == 1)
        s.remaps = []
        #expect(s.profiles[1].remaps.isEmpty)
    }

    @Test func argumentsSplitLikeAShell() {
        #expect(ActionRunner.splitArguments("--new-window \"~/My Folder\" a\\ b 'c d' \"\"") ==
                ["--new-window", "~/My Folder", "a b", "c d", ""])
        #expect(ActionRunner.splitArguments("  ").isEmpty)
        #expect(ActionRunner.expand("$HOME/x ${USER}y $NOPE.z", environment: ["HOME": "/h", "USER": "u"]) == "/h/x uy .z")
        #expect(ActionRunner.resolveURL("https://example.com")?.scheme == "https")
        #expect(ActionRunner.resolveURL("/tmp/a b.txt")?.path == "/tmp/a b.txt")
        #expect(ActionRunner.resolveURL("") == nil)
    }
}
