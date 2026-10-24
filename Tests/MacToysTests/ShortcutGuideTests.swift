import Testing
@testable import ShortcutGuide

@Suite struct ShortcutGuideTests {
    @Test func modifierMaskToGlyphs() {
        #expect(MenuGlyphs.modifiers(0) == ["⌘"])                       // kAXMenuItemModifierNone: ⌘ only
        #expect(MenuGlyphs.modifiers(1) == ["⇧", "⌘"])                  // shift
        #expect(MenuGlyphs.modifiers(2) == ["⌥", "⌘"])                  // option
        #expect(MenuGlyphs.modifiers(3) == ["⌥", "⇧", "⌘"])
        #expect(MenuGlyphs.modifiers(4) == ["⌃", "⌘"])                  // control
        #expect(MenuGlyphs.modifiers(7) == ["⌃", "⌥", "⇧", "⌘"])
        #expect(MenuGlyphs.modifiers(8) == [])                          // no command, no modifiers
        #expect(MenuGlyphs.modifiers(8 | 4) == ["⌃"])                   // control without ⌘
        #expect(MenuGlyphs.modifiers(8 | 4 | 2) == ["⌃", "⌥"])
        #expect(MenuGlyphs.modifiers(8 | 16) == ["fn"])                 // 🌐 key equivalents (Enter Full Screen)
        #expect(MenuGlyphs.modifiers(8 | 16 | 4) == ["fn", "⌃"])
    }

    @Test func glyphCodesForSpecialKeys() {
        #expect(MenuGlyphs.glyph(0x17) == "⌫")
        #expect(MenuGlyphs.glyph(0x0A) == "⌦")
        #expect(MenuGlyphs.glyph(0x0B) == "↩")
        #expect(MenuGlyphs.glyph(0x02) == "⇥")
        #expect(MenuGlyphs.glyph(0x1B) == "⎋")
        #expect(MenuGlyphs.glyph(0x09) == "Space")
        #expect(MenuGlyphs.glyph(0x64) == "←")
        #expect(MenuGlyphs.glyph(0x68) == "↑")
        #expect(MenuGlyphs.glyph(0x6A) == "↓")
        #expect(MenuGlyphs.glyph(0x62) == "⇞")
        #expect(MenuGlyphs.glyph(0x6F) == "F1")
        #expect(MenuGlyphs.glyph(0x7A) == "F12")
        #expect(MenuGlyphs.glyph(0x87) == "F13")
        #expect(MenuGlyphs.glyph(0x8F) == "F16")
        #expect(MenuGlyphs.glyph(0x92) == "F19")
        #expect(MenuGlyphs.glyph(0x8C) == "⏏")
        #expect(MenuGlyphs.glyph(0x01) == nil)
    }

    @Test func keyEquivalentCharacters() {
        #expect(MenuGlyphs.character("n") == "N")
        #expect(MenuGlyphs.character(",") == ",")
        #expect(MenuGlyphs.character("\u{F700}") == "↑")
        #expect(MenuGlyphs.character("\u{F703}") == "→")
        #expect(MenuGlyphs.character("\u{F704}") == "F1")
        #expect(MenuGlyphs.character("\u{F728}") == "⌦")
        #expect(MenuGlyphs.character("\u{8}") == "⌫")
        #expect(MenuGlyphs.character("\r") == "↩")
        #expect(MenuGlyphs.character(" ") == "Space")
        #expect(MenuGlyphs.character("\u{10}") == nil)
    }

    @Test func menuItemKeys() {
        #expect(MenuGlyphs.keys(char: "N", virtualKey: 45, glyph: nil, modifiers: 1) == ["⇧", "⌘", "N"])
        #expect(MenuGlyphs.keys(char: "f", virtualKey: nil, glyph: nil, modifiers: 24) == ["fn", "F"])
        // The glyph wins over the (unprintable) character.
        #expect(MenuGlyphs.keys(char: "\u{8}", virtualKey: 51, glyph: 0x17, modifiers: 0) == ["⌘", "⌫"])
        #expect(MenuGlyphs.keys(char: nil, virtualKey: 0, glyph: nil, modifiers: 0) == nil)
        #expect(MenuGlyphs.keys(char: nil, virtualKey: nil, glyph: 0, modifiers: nil) == nil)
        // Only a virtual key: function keys described by code.
        #expect(MenuGlyphs.keys(char: "\u{10}", virtualKey: 0x7A, glyph: nil, modifiers: 8) == ["F1"])
    }

    @Test func searchMatchesTitlesGroupsAndKeys() {
        let item = ShortcutItem("New Private Window", ["⇧", "⌘", "N"])
        #expect(ShortcutFilter.matches(item, group: "File", query: "private"))
        #expect(ShortcutFilter.matches(item, group: "File", query: "file new"))
        #expect(ShortcutFilter.matches(item, group: "File", query: "shift cmd"))
        #expect(ShortcutFilter.matches(item, group: "File", query: "n"))
        #expect(!ShortcutFilter.matches(item, group: "File", query: "option"))
        #expect(!ShortcutFilter.matches(item, group: "File", query: "tab"))
        let groups = [ShortcutGroup("File", [item, ShortcutItem("Print…", ["⌘", "P"])]), ShortcutGroup("Edit", [ShortcutItem("Undo", ["⌘", "Z"])])]
        #expect(ShortcutFilter.filter(groups, query: "print").map(\.title) == ["File"])
        #expect(ShortcutFilter.filter(groups, query: " ").count == 2)
    }

    @Test func columnsBalanceInReadingOrder() {
        func group(_ name: String, _ n: Int) -> ShortcutGroup {
            ShortcutGroup(name, (0..<n).map { ShortcutItem("\(name) \($0)", ["⌘", "\($0)"]) })
        }
        let groups = [group("File", 7), group("Edit", 4), group("View", 7), group("History", 4), group("Bookmarks", 3),
                      group("Window", 5), group("Develop", 2)]
        let columns = ColumnLayout.distribute(groups, columns: 3)
        #expect(columns.map { $0.map(\.title) } == [["File", "Edit"], ["View", "History"], ["Bookmarks", "Window", "Develop"]])
        #expect(ColumnLayout.distribute([group("Only", 3)], columns: 3).count == 1)
        #expect(ColumnLayout.distribute([], columns: 3) == [[]])
    }

    @Test func systemListHasNoDuplicatesWithinGroups() {
        for group in SystemShortcuts.groups {
            #expect(Set(group.items.map(\.id)).count == group.items.count, "\(group.title)")
            #expect(group.items.allSatisfy { !$0.keys.isEmpty })
        }
    }
}
