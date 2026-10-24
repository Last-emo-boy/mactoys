import Testing
@testable import QuickAccent

@Suite struct QuickAccentTests {
    private func set(_ id: String) -> AccentSet {
        guard let s = AccentSet.named(id) else { fatalError("missing set \(id)") }
        return s
    }

    @Test func everyPowerToysSetIsPresent() {
        #expect(AccentSet.all.count == 47)
        for id in ["CA", "HR", "CZ", "DK", "NL", "EST", "FI", "FR", "GA", "GD", "DE", "EL", "HE", "HU", "IS", "IPA", "IT",
                   "KU", "LT", "MK", "MT", "MI", "NO", "PI", "PL", "PT", "RO", "SR", "SK", "SL", "SP", "SV", "TK", "VI",
                   "CY", "CUR", "SPECIAL"] {
            #expect(AccentSet.named(id) != nil, "\(id)")
        }
        #expect(set("FR").characters[.e] == ["é", "è", "ê", "ë", "€"])
        #expect(set("PI").characters[.digit1] == ["\u{0304}", "ˉ"])
    }

    @Test func mergingKeepsLanguagesBeforeSpecialSetsAndDropsDuplicates() {
        let chars = AccentLogic.characters(for: .e, in: [set("CUR"), set("FR"), set("DE")])
        #expect(chars == ["é", "è", "ê", "ë", "€"])
        let withCzech = AccentLogic.characters(for: .e, in: [set("FR"), set("CZ")])
        #expect(withCzech == ["é", "è", "ê", "ë", "€", "ě"])
        #expect(AccentLogic.characters(for: .q, in: [set("FR")]).isEmpty)
    }

    @Test func uppercaseVariants() {
        #expect(AccentLogic.uppercased(["é", "ß", "€", "ς", "σ", "ŉ"]) == ["É", "ẞ", "€", "Σ", "ŉ"])
    }

    @Test func frequencyOrderingIsStable() {
        let sorted = AccentLogic.sortedByUsage(["é", "è", "ê", "ë"], counts: ["ê": 5, "ë": 5, "è": 1])
        #expect(sorted == ["ê", "ë", "è", "é"])
        #expect(AccentLogic.sortedByUsage(["a", "b"], counts: [:]) == ["a", "b"])
    }

    @Test func cyclingWrapsBothWays() {
        #expect(AccentLogic.step(0, count: 3, forward: true) == 1)
        #expect(AccentLogic.step(2, count: 3, forward: true) == 0)
        #expect(AccentLogic.step(0, count: 3, forward: false) == 2)
        #expect(AccentLogic.visibleRange(count: 5, selected: 4, capacity: 13) == 0..<5)
        #expect(AccentLogic.visibleRange(count: 30, selected: 0, capacity: 13) == 0..<13)
        #expect(AccentLogic.visibleRange(count: 30, selected: 15, capacity: 13) == 9..<22)
        #expect(AccentLogic.visibleRange(count: 30, selected: 29, capacity: 13) == 17..<30)
    }

    @Test func unicodeDescriptions() {
        let info = AccentLogic.unicodeInfo("é")
        #expect(info.code == "U+00E9")
        #expect(info.name == "Latin small letter e with acute")
        #expect(AccentLogic.unicodeInfo("°C").code == "U+00B0 U+0043")
        #expect(AccentLogic.display("\u{0301}") == "◌\u{0301}")
        #expect(AccentLogic.display("é") == "é")
    }

    @Test func keysFromCharacters() {
        #expect(AccentKey(character: "e") == .e)
        #expect(AccentKey(character: "E") == .e)
        #expect(AccentKey(character: "5") == .digit5)
        #expect(AccentKey(character: ",") == .comma)
        #expect(AccentKey(character: "=") == .plus)
        #expect(AccentKey(character: "é") == nil)
        #expect(AccentKey.digit5.label == "5")
    }

    // MARK: Engine

    @Test func spaceCyclesAndReleaseCommits() {
        var engine = AccentEngine()
        #expect(engine.keyDown(.e, candidates: 5, shift: false, at: 0) == (.pass, []))
        // The toolbar opens once the activation key has been held for the input delay.
        #expect(engine.trigger(.space, shift: false, at: 0.2) == (.consume, [.schedule(0.3)]))
        #expect(engine.selection == 0)
        #expect(engine.timerFired(at: 0.4) == [])
        #expect(engine.timerFired(at: 0.5) == [.show])
        #expect(engine.trigger(.space, shift: false, at: 0.6) == (.consume, [.select(1)]))
        #expect(engine.trigger(.space, shift: true, at: 0.7) == (.consume, [.select(0)]))
        #expect(engine.trigger(.left, shift: false, at: 0.8) == (.consume, [.select(4)]))
        #expect(engine.keyUp(.e, at: 1) == (.pass, [.hide, .commit(4)]))
        #expect(!engine.isArmed)
    }

    @Test func cyclingBeforeTheToolbarOpensKeepsTheSelection() {
        var engine = AccentEngine()
        _ = engine.keyDown(.a, candidates: 3, shift: false, at: 0)
        #expect(engine.trigger(.right, shift: false, at: 0.1) == (.consume, [.schedule(0.3)]))
        #expect(engine.trigger(.right, shift: false, at: 0.2) == (.consume, []))
        #expect(engine.selection == 1)
        #expect(engine.timerFired(at: 0.4) == [.show])
        #expect(engine.isVisible)
    }

    @Test func fastTypingIsAFalseStart() {
        // "e" then Space while "e" is still down, released quickly: the space is typed again.
        var engine = AccentEngine()
        _ = engine.keyDown(.e, candidates: 5, shift: false, at: 0)
        #expect(engine.trigger(.space, shift: false, at: 0.05).0 == .consume)
        #expect(engine.keyUp(.e, at: 0.1) == (.pass, [.retype([.space])]))
        #expect(engine.timerFired(at: 0.3) == [])
    }

    @Test func anotherKeyDuringTheDelayReplaysInOrder() {
        var engine = AccentEngine()
        _ = engine.keyDown(.e, candidates: 5, shift: false, at: 0)
        _ = engine.trigger(.space, shift: false, at: 0.05)
        #expect(engine.otherKey() == (.replay, [.retype([.space])]))
        #expect(!engine.isArmed)
    }

    @Test func shiftHeldForUppercaseDoesNotReverse() {
        var engine = AccentEngine()
        _ = engine.keyDown(.e, candidates: 4, shift: true, at: 0)
        _ = engine.trigger(.space, shift: true, at: 0.1)
        #expect(engine.timerFired(at: 0.4) == [.show])
        #expect(engine.trigger(.space, shift: true, at: 0.5) == (.consume, [.select(1)]))
    }

    @Test func activationKeyFiltering() {
        var config = AccentEngine.Config()
        config.activation = .arrows
        var engine = AccentEngine(config: config)
        _ = engine.keyDown(.o, candidates: 3, shift: false, at: 0)
        // Space isn't the activation key here: it's ordinary typing.
        #expect(engine.trigger(.space, shift: false, at: 0.5) == (.pass, []))
        #expect(!engine.isArmed)

        config.activation = .space
        config.startFromLeft = true
        engine = AccentEngine(config: config)
        _ = engine.keyDown(.o, candidates: 3, shift: false, at: 0)
        #expect(engine.trigger(.left, shift: false, at: 0.5) == (.pass, []))
    }

    @Test func leftStartsFromTheEndUnlessStartFromLeft() {
        var engine = AccentEngine()
        _ = engine.keyDown(.u, candidates: 4, shift: false, at: 0)
        _ = engine.trigger(.left, shift: false, at: 0.4)
        #expect(engine.selection == 3)

        var config = AccentEngine.Config()
        config.startFromLeft = true
        engine = AccentEngine(config: config)
        _ = engine.keyDown(.u, candidates: 4, shift: false, at: 0)
        _ = engine.trigger(.left, shift: false, at: 0.4)
        #expect(engine.selection == 0)
    }

    @Test func pressAndHoldMode() {
        var config = AccentEngine.Config()
        config.activation = .hold
        var engine = AccentEngine(config: config)
        #expect(engine.keyDown(.n, candidates: 2, shift: false, at: 0) == (.pass, [.schedule(0.5)]))
        #expect(engine.swallowsRepeat(of: .n))
        #expect(engine.timerFired(at: 0.5) == [.show])
        #expect(engine.selection == nil)
        #expect(engine.trigger(.right, shift: false, at: 0.6) == (.consume, [.select(0)]))
        #expect(engine.keyUp(.n, at: 0.8) == (.pass, [.hide, .commit(0)]))

        // Released without choosing: the letter stays.
        _ = engine.keyDown(.n, candidates: 2, shift: false, at: 1)
        _ = engine.timerFired(at: 1.5)
        #expect(engine.keyUp(.n, at: 1.6) == (.pass, [.hide]))

        // A quick tap or another key never opens it.
        _ = engine.keyDown(.n, candidates: 2, shift: false, at: 2)
        #expect(engine.otherKey() == (.pass, []))
        #expect(engine.timerFired(at: 2.5) == [])
    }

    @Test func escapeAndModifiersCancel() {
        var engine = AccentEngine()
        _ = engine.keyDown(.c, candidates: 2, shift: false, at: 0)
        _ = engine.trigger(.space, shift: false, at: 0.1)
        _ = engine.timerFired(at: 0.4)
        #expect(engine.cancel() == (.consume, [.hide]))
        #expect(engine.keyUp(.c, at: 0.6) == (.pass, []))
    }

    @Test func keyRepeatKeepsWorkingUntilAnActivationKey() {
        var engine = AccentEngine()
        _ = engine.keyDown(.j, candidates: 0, shift: false, at: 0)
        #expect(!engine.swallowsRepeat(of: .j))
        _ = engine.keyDown(.a, candidates: 3, shift: false, at: 1)
        #expect(!engine.swallowsRepeat(of: .a))
        _ = engine.trigger(.space, shift: false, at: 1.1)
        #expect(engine.swallowsRepeat(of: .a))
        #expect(!engine.swallowsRepeat(of: .b))
    }

    @Test func keysWithoutCharactersStayIdle() {
        var engine = AccentEngine()
        _ = engine.keyDown(.q, candidates: 0, shift: false, at: 0)
        #expect(!engine.isArmed)
        #expect(engine.trigger(.space, shift: false, at: 0.5) == (.pass, []))
    }
}
