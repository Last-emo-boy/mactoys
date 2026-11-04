import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import KeystrokeOverlay
@testable import MacToysCore

/// Keyboard layouts come from Text Input Sources, which must be used from one thread.
@MainActor
private func translator(_ id: String) throws -> KeyTranslator {
    KeyTranslator(layout: try #require(KeyboardLayouts.named(id), "layout \(id) is installed with macOS"))
}

@MainActor
private func interpreter(_ mode: KeystrokeSettings.Mode, layout: String = "com.apple.keylayout.US",
                         specialKeys: Bool = false, mask: Bool = false) throws -> KeystrokeInterpreter {
    KeystrokeInterpreter(mode: mode, specialKeys: specialKeys, maskText: mask, typing: try translator(layout),
                         shortcuts: try translator("com.apple.keylayout.US"))
}

@Suite @MainActor struct KeystrokeFormattingTests {
    @Test func everyModifierInApplesOrder() throws {
        var i = try interpreter(.shortcuts)
        #expect(i.interpret(KeyPress(kVK_ANSI_S, [.command])) == .keys(["⌘", "S"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_S, [.command, .shift, .option, .control])) == .keys(["⌃", "⌥", "⇧", "⌘", "S"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_T, [.shift, .command])) == .keys(["⇧", "⌘", "T"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_RightBracket, [.shift, .command])) == .keys(["⇧", "⌘", "]"]))
        // fn/🌐 held on a letter is a real modifier: 🌐F enters full screen.
        #expect(i.interpret(KeyPress(kVK_ANSI_F, [.function])) == .keys(["fn", "F"]))
    }

    @Test func functionKeysArrowsAndNavigationDropTheImpliedFn() throws {
        var i = try interpreter(.allKeys)
        #expect(i.interpret(KeyPress(kVK_F5, [.function])) == .keys(["F5"]))
        #expect(i.interpret(KeyPress(kVK_F12, [.function, .command])) == .keys(["⌘", "F12"]))
        #expect(i.interpret(KeyPress(kVK_LeftArrow, [.function, .option])) == .keys(["⌥", "←"]))
        #expect(i.interpret(KeyPress(kVK_UpArrow, [.function, .command, .shift])) == .keys(["⇧", "⌘", "↑"]))
        #expect(i.interpret(KeyPress(kVK_PageDown, [.function])) == .keys(["⇟"]))
        #expect(i.interpret(KeyPress(kVK_ForwardDelete, [.function])) == .keys(["⌦"]))
        #expect(i.interpret(KeyPress(kVK_Escape)) == .keys(["esc"]))
        #expect(i.interpret(KeyPress(kVK_Return, [.command])) == .keys(["⌘", "↩"]))
        #expect(i.interpret(KeyPress(kVK_Tab, [.control, .shift])) == .keys(["⌃", "⇧", "⇥"]))
        #expect(i.interpret(KeyPress(kVK_Space, [.control])) == .keys(["⌃", "Space"]))
    }

    @Test func keypadKeys() throws {
        var i = try interpreter(.allKeys)
        #expect(i.interpret(KeyPress(kVK_ANSI_Keypad5)) == .keys(["5"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_KeypadPlus, [.command])) == .keys(["⌘", "+"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_KeypadEnter)) == .keys(["⌤"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_KeypadClear)) == .keys(["⌧"]))
        var text = try interpreter(.text)
        #expect(text.interpret(KeyPress(kVK_ANSI_Keypad7)) == .text("7"))
    }

    @Test func modifierKeysThemselvesAreNotKeys() throws {
        var i = try interpreter(.allKeys)
        #expect(i.interpret(KeyPress(kVK_Command, [.command])) == .ignore)
        #expect(i.interpret(KeyPress(kVK_RightShift, [.shift])) == .ignore)
    }

    @Test func deadKeysComposeLikeTheTextSystem() throws {
        var i = try interpreter(.text)
        // ⌥E waits for the next key on a U.S. layout.
        #expect(i.interpret(KeyPress(kVK_ANSI_E, [.option])) == .text(""))
        #expect(i.interpret(KeyPress(kVK_ANSI_E)) == .text("é"))
        #expect(i.interpret(KeyPress(kVK_ANSI_U, [.option])) == .text(""))
        #expect(i.interpret(KeyPress(kVK_ANSI_O)) == .text("ö"))
        // A key that can't take the accent gets it in front; Space types the accent alone.
        #expect(i.interpret(KeyPress(kVK_ANSI_E, [.option])) == .text(""))
        #expect(i.interpret(KeyPress(kVK_ANSI_X)) == .text("´x"))
        #expect(i.interpret(KeyPress(kVK_ANSI_E, [.option])) == .text(""))
        #expect(i.interpret(KeyPress(kVK_Space)) == .text("´"))
        // A shortcut in between drops the pending accent.
        #expect(i.interpret(KeyPress(kVK_ANSI_E, [.option])) == .text(""))
        #expect(i.interpret(KeyPress(kVK_ANSI_S, [.command])) == .keys(["⌘", "S"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_E)) == .text("e"))
        // In shortcuts mode ⌥E is a shortcut, shown by its key.
        var s = try interpreter(.shortcuts)
        #expect(s.interpret(KeyPress(kVK_ANSI_E, [.option])) == .keys(["⌥", "E"]))
    }

    @Test func germanLayout() throws {
        var text = try interpreter(.text, layout: "com.apple.keylayout.German")
        // QWERTZ: the key in the U.S. Z position types y.
        #expect(text.interpret(KeyPress(kVK_ANSI_Z)) == .text("y"))
        #expect(text.interpret(KeyPress(kVK_ANSI_Y)) == .text("z"))
        // ´ is a dead key next to ß.
        #expect(text.interpret(KeyPress(kVK_ANSI_Equal)) == .text(""))
        #expect(text.interpret(KeyPress(kVK_ANSI_E)) == .text("é"))
        var all = try interpreter(.allKeys, layout: "com.apple.keylayout.German")
        #expect(all.interpret(KeyPress(kVK_ANSI_LeftBracket)) == .keys(["Ü"]))
        #expect(all.interpret(KeyPress(kVK_ANSI_Minus)) == .keys(["ß"]))
    }

    @Test func frenchLayout() throws {
        var text = try interpreter(.text, layout: "com.apple.keylayout.French")
        #expect(text.interpret(KeyPress(kVK_ANSI_Q)) == .text("a"))
        #expect(text.interpret(KeyPress(kVK_ANSI_1)) == .text("&"))
        #expect(text.interpret(KeyPress(kVK_ANSI_1, [.shift])) == .text("1"))
        // ^ is a dead key.
        #expect(text.interpret(KeyPress(kVK_ANSI_LeftBracket)) == .text(""))
        #expect(text.interpret(KeyPress(kVK_ANSI_E)) == .text("ê"))
        var all = try interpreter(.allKeys, layout: "com.apple.keylayout.French")
        #expect(all.interpret(KeyPress(kVK_ANSI_Q)) == .keys(["A"]))
    }

    @Test func nonLatinTypingKeepsLatinShortcuts() throws {
        var text = try interpreter(.text, layout: "com.apple.keylayout.Russian")
        #expect(text.interpret(KeyPress(kVK_ANSI_A)) == .text("ф"))
        #expect(text.interpret(KeyPress(kVK_ANSI_A, [.shift])) == .text("Ф"))
        // Shortcuts are read from the ASCII-capable layout, as macOS matches them.
        #expect(text.interpret(KeyPress(kVK_ANSI_A, [.command])) == .keys(["⌘", "A"]))
        var all = try interpreter(.allKeys, layout: "com.apple.keylayout.Russian")
        #expect(all.interpret(KeyPress(kVK_ANSI_A)) == .keys(["Ф"]))
    }

    @Test func legendsCapitalizeWithoutChangingLength() {
        #expect(KeyNames.capital("a") == "A")
        #expect(KeyNames.capital("ß") == "ß")
        #expect(KeyNames.capital("ü") == "Ü")
        #expect(KeyNames.capital("[") == "[")
    }

    @Test func withoutALayoutUSLegendsAreUsed() {
        var i = KeystrokeInterpreter(mode: .shortcuts, typing: nil, shortcuts: nil)
        #expect(i.interpret(KeyPress(kVK_ANSI_S, [.command])) == .keys(["⌘", "S"]))
    }
}

@Suite @MainActor struct KeystrokeModeTests {
    @Test func shortcutsModeKeepsTypingPrivate() throws {
        var i = try interpreter(.shortcuts)
        #expect(i.interpret(KeyPress(kVK_ANSI_A)) == .ignore)
        #expect(i.interpret(KeyPress(kVK_ANSI_A, [.shift])) == .ignore)
        #expect(i.interpret(KeyPress(kVK_ANSI_1, [.shift])) == .ignore)
        #expect(i.interpret(KeyPress(kVK_Return)) == .ignore)
        #expect(i.interpret(KeyPress(kVK_LeftArrow, [.function])) == .ignore)
        #expect(i.interpret(KeyPress(kVK_ANSI_C, [.control])) == .keys(["⌃", "C"]))
        var special = try interpreter(.shortcuts, specialKeys: true)
        #expect(special.interpret(KeyPress(kVK_Return)) == .keys(["↩"]))
        #expect(special.interpret(KeyPress(kVK_LeftArrow, [.function])) == .keys(["←"]))
        #expect(special.interpret(KeyPress(kVK_F3, [.function])) == .keys(["F3"]))
        // Space and letters are typing, not special keys.
        #expect(special.interpret(KeyPress(kVK_Space)) == .ignore)
        #expect(special.interpret(KeyPress(kVK_ANSI_A)) == .ignore)
    }

    @Test func allKeysShowsEveryKey() throws {
        var i = try interpreter(.allKeys)
        #expect(i.interpret(KeyPress(kVK_ANSI_A)) == .keys(["A"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_A, [.shift])) == .keys(["⇧", "A"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_Slash)) == .keys(["/"]))
        #expect(i.interpret(KeyPress(kVK_Space)) == .keys(["Space"]))
    }

    @Test func typedTextMode() throws {
        var i = try interpreter(.text)
        #expect(i.interpret(KeyPress(kVK_ANSI_H, [.shift])) == .text("H"))
        #expect(i.interpret(KeyPress(kVK_ANSI_I)) == .text("i"))
        #expect(i.interpret(KeyPress(kVK_Space)) == .text(" "))
        #expect(i.interpret(KeyPress(kVK_ANSI_1, [.shift])) == .text("!"))
        #expect(i.interpret(KeyPress(kVK_ANSI_A, [.shift], capsLock: true)) == .text("A"))
        #expect(i.interpret(KeyPress(kVK_ANSI_A, capsLock: true)) == .text("A"))
        // ⌥ types characters…
        #expect(i.interpret(KeyPress(kVK_ANSI_2, [.option])) == .text("™"))
        // …but ⌥ with arrows and delete edits, shown as keys.
        #expect(i.interpret(KeyPress(kVK_LeftArrow, [.function, .option])) == .keys(["⌥", "←"]))
        #expect(i.interpret(KeyPress(kVK_Delete, [.option])) == .keys(["⌥", "⌫"]))
        #expect(i.interpret(KeyPress(kVK_Delete)) == .backspace)
        #expect(i.interpret(KeyPress(kVK_Return)) == .keys(["↩"]))
        #expect(i.interpret(KeyPress(kVK_ANSI_V, [.command])) == .keys(["⌘", "V"]))
    }

    @Test func maskingHidesLettersAndDigitsButNotShortcuts() throws {
        var text = try interpreter(.text, mask: true)
        #expect(text.interpret(KeyPress(kVK_ANSI_A)) == .text("•"))
        #expect(text.interpret(KeyPress(kVK_Space)) == .text(" "))
        #expect(text.interpret(KeyPress(kVK_ANSI_S, [.command])) == .keys(["⌘", "S"]))
        var all = try interpreter(.allKeys, mask: true)
        #expect(all.interpret(KeyPress(kVK_ANSI_7)) == .keys(["•"]))
        #expect(all.interpret(KeyPress(kVK_ANSI_Q, [.shift])) == .keys(["⇧", "•"]))
        #expect(all.interpret(KeyPress(kVK_Tab)) == .keys(["⇥"]))
        #expect(KeystrokeInterpreter.mask("Pin 4821 ok") == "••• •••• ••")
    }
}

@Suite struct KeystrokeFeedTests {
    @Test func repeatedPressesCollapse() {
        var feed = KeystrokeFeed()
        feed.add(keys: ["⌘", "Z"], name: "Undo")
        feed.add(keys: ["⌘", "Z"], name: "Undo")
        feed.add(keys: ["⌘", "Z"])
        #expect(feed.items.count == 1)
        #expect(feed.items[0].count == 3)
        #expect(feed.items[0].content == .keys(["⌘", "Z"], name: "Undo"))
        feed.add(keys: ["⇧", "⌘", "Z"], name: "Redo")
        feed.add(keys: ["⌘", "Z"], name: "Undo")
        #expect(feed.items.map(\.count) == [3, 1, 1])
    }

    @Test func typedTextRunsTogetherAndBackspaceEditsIt() {
        var feed = KeystrokeFeed()
        for c in "Helo" { feed.type(String(c)) }
        feed.backspace()
        feed.type("lo")
        #expect(feed.items.map(\.content) == [.text("Hello")])
        feed.add(keys: ["⌘", "B"], name: "Bold")
        feed.type("!")
        #expect(feed.items.count == 3)
        // Deleting everything typed removes the entry; another ⌫ shows as a key.
        feed.backspace()
        feed.backspace()
        #expect(feed.items.last?.content == .keys(["⌫"], name: nil))
    }

    @Test func longTextKeepsItsEnd() {
        var feed = KeystrokeFeed(maxItems: 4, maxText: 10)
        feed.type("The quick brown fox")
        #expect(feed.items[0].content == .text("…brown fox"))
        feed.type(" ran")
        #expect(feed.items[0].content == .text("…n fox ran"))
    }

    @Test func oldestEntriesDropOff() {
        var feed = KeystrokeFeed(maxItems: 3)
        for key in ["A", "B", "C", "D"] { feed.add(keys: ["⌘", key]) }
        #expect(feed.items.map(\.content) == [.keys(["⌘", "B"], name: nil), .keys(["⌘", "C"], name: nil), .keys(["⌘", "D"], name: nil)])
        #expect(Set(feed.items.map(\.id)).count == 3)
    }

    @Test func clicksUpgradeAndCount() {
        var feed = KeystrokeFeed()
        feed.click(.init(.left))
        feed.click(.init(.left, count: 2))
        #expect(feed.items.map(\.content) == [.click(.init(.left, count: 2))])
        feed.click(.init(.right))
        feed.click(.init(.right))
        #expect(feed.items.last?.count == 2)
        feed.click(.init(.left, modifiers: ["⌘"]))
        #expect(feed.items.count == 3)
    }

    @Test func namesArriveLater() {
        var feed = KeystrokeFeed()
        feed.add(keys: ["⌘", "K"])
        feed.setName("Insert Link", forKeys: ["⌘", "K"])
        #expect(feed.items[0].content == .keys(["⌘", "K"], name: "Insert Link"))
        feed.setName("Something Else", forKeys: ["⌘", "K"])
        #expect(feed.items[0].content == .keys(["⌘", "K"], name: "Insert Link"))
    }

    @Test func hiddenNoticeAppearsOnce() {
        var feed = KeystrokeFeed()
        feed.hidden()
        feed.hidden()
        #expect(feed.items.map(\.content) == [.hidden])
        feed.clear()
        #expect(feed.isEmpty)
    }
}

@Suite struct KeystrokePrivacyTests {
    @Test func secureInputHidesTyping() {
        #expect(KeystrokePrivacy.verdict(isKey: true, secureInput: true, secureField: false, excludedApp: false) == .hideTyping)
        #expect(KeystrokePrivacy.verdict(isKey: true, secureInput: false, secureField: true, excludedApp: false) == .hideTyping)
        #expect(KeystrokePrivacy.verdict(isKey: true, secureInput: false, secureField: false, excludedApp: false) == .show)
    }

    @Test func excludedAppsShowNothing() {
        #expect(KeystrokePrivacy.verdict(isKey: true, secureInput: true, secureField: true, excludedApp: true) == .ignore)
        #expect(KeystrokePrivacy.verdict(isKey: false, secureInput: false, secureField: false, excludedApp: true) == .ignore)
    }

    @Test func clicksAreNotSecret() {
        #expect(KeystrokePrivacy.verdict(isKey: false, secureInput: true, secureField: true, excludedApp: false) == .show)
    }

    @Test func modifiersAloneAreSpottedOnlyWithoutAKey() {
        var t = ModifierTapTracker()
        #expect(t.flagsChanged([.command]) == nil)
        #expect(t.flagsChanged([]) == [.command])
        #expect(t.flagsChanged([.command]) == nil)
        t.interrupt()
        #expect(t.flagsChanged([]) == nil)
        #expect(t.flagsChanged([.control]) == nil)
        #expect(t.flagsChanged([.control, .option]) == nil)
        #expect(t.flagsChanged([.option]) == nil)
        #expect(t.flagsChanged([]) == [.control, .option])
    }
}

@Suite struct KeystrokeMenuNameTests {
    private let index = MenuShortcutIndex(items: [
        MenuItemInfo("Save", char: "S"),
        MenuItemInfo("Save As…", char: "S", modifiers: 1),
        MenuItemInfo("Duplicate", char: "S", modifiers: 1 | 2, enabled: false),
        MenuItemInfo("Show Help", char: "?"),
        MenuItemInfo("Previous Tab", glyph: 0x64, modifiers: 2),
        MenuItemInfo("Show Next Tab", char: "\u{09}", modifiers: 4 | 8),
        MenuItemInfo("Enter Full Screen", char: "f", modifiers: 16 | 8),
        MenuItemInfo("Refresh", char: "\u{F708}", modifiers: 8),
        MenuItemInfo("About", char: nil),
        MenuItemInfo("Save Copy", char: "S", enabled: false),
    ])

    private func name(_ press: KeyPress, _ base: String?, _ shifted: String? = nil) -> String? {
        index.name(for: press, base: base, shifted: shifted)
    }

    @Test func charactersAndModifiers() {
        #expect(name(KeyPress(kVK_ANSI_S, [.command]), "s", "S") == "Save")
        #expect(name(KeyPress(kVK_ANSI_S, [.command, .shift]), "s", "S") == "Save As…")
        // A disabled item names a shortcut only when nothing enabled has it.
        #expect(name(KeyPress(kVK_ANSI_S, [.command, .shift, .option]), "s", "S") == "Duplicate")
        #expect(name(KeyPress(kVK_ANSI_S, [.control]), "s", "S") == nil)
    }

    @Test func shiftedCharactersMatchWithoutShift() {
        // ⌘? is typed as ⇧⌘/ on a U.S. keyboard.
        #expect(name(KeyPress(kVK_ANSI_Slash, [.command, .shift]), "/", "?") == "Show Help")
    }

    @Test func specialKeysGlyphsAndFunctionKeys() {
        #expect(name(KeyPress(kVK_LeftArrow, [.command, .option, .function]), nil) == "Previous Tab")
        #expect(name(KeyPress(kVK_Tab, [.control]), nil) == "Show Next Tab")
        #expect(name(KeyPress(kVK_F5, [.function]), nil) == "Refresh")
        #expect(name(KeyPress(kVK_ANSI_F, [.function]), "f", "F") == "Enter Full Screen")
    }

    @Test func itemsWithoutShortcutsAreSkipped() {
        #expect(MenuShortcutIndex.key(for: MenuItemInfo("About")) == nil)
        #expect(MenuShortcutIndex.key(for: MenuItemInfo("Glyph", glyph: 0x64)) == MenuKey([.command], "←"))
        #expect(index.count == 8)
    }
}

@Suite struct KeystrokeSettingsTests {
    @Test func defaults() {
        let s = KeystrokeSettings()
        #expect(s.toggle?.keyCode == UInt16(kVK_ANSI_J))
        #expect(s.toggle?.modifiers == [.control, .option, .shift])
        #expect(s.mode == .shortcuts && s.showNames && !s.mouseClicks)
        #expect(s.excludedApps.contains("Keychain Access"))
        #expect(KeystrokeSettings.Size.allCases.map(\.fontSize) == [15, 20, 28, 40])
    }

    @Test func settingsRoundTrip() throws {
        var s = KeystrokeSettings()
        s.mode = .text
        s.position = .custom
        s.customX = 0.25
        s.customY = 0.1
        s.theme = .light
        s.toggle = nil
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(KeystrokeSettings.self, from: data) == s)
    }

    @MainActor @Test func moduleListensThroughAccessibility() {
        let module = KeystrokeOverlayModule()
        #expect(module.info.id == "keystrokes")
        #expect(module.info.permissions == [.accessibility])
        #expect(!module.info.enabledByDefault)
    }
}
