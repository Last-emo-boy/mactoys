import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import WindowHopper

@Suite struct WindowHopperTests {
    @Test func stepWrapsBothWays() {
        #expect(HopperLogic.step(0, by: 1, count: 3) == 1)
        #expect(HopperLogic.step(2, by: 1, count: 3) == 0)
        #expect(HopperLogic.step(0, by: -1, count: 3) == 2)
        #expect(HopperLogic.step(1, by: -7, count: 3) == 0)
        #expect(HopperLogic.step(4, by: 1, count: 0) == 0)
    }

    @Test func firstSelectionSkipsTheCurrentWindow() {
        #expect(HopperLogic.initialSelection(forward: true, count: 4) == 1)
        #expect(HopperLogic.initialSelection(forward: false, count: 4) == 3)
        #expect(HopperLogic.initialSelection(forward: true, count: 1) == 0)
    }

    @Test func shiftOnlyReversesItDoesNotHoldTheSwitcher() {
        let next = Shortcut(0x32, [.option])
        let previous = Shortcut(0x32, [.option, .shift])
        #expect(HopperLogic.holdModifiers(for: next) == [.option])
        #expect(HopperLogic.holdModifiers(for: previous) == [.option])
        #expect(!HopperLogic.isReleased(hold: [.option], now: [.option, .shift]))
        #expect(HopperLogic.isReleased(hold: [.option], now: [.shift]))
        #expect(HopperLogic.isReleased(hold: [.control, .option], now: [.option]))
        // A switcher opened without held modifiers (from a URL) never closes on release.
        #expect(!HopperLogic.isReleased(hold: [], now: []))
    }

    @Test func windowsAreOrderedFrontToBackWithMinimizedLast() {
        struct W { let id: CGWindowID; let name: String }
        let windows = [W(id: 7, name: "minimized A"), W(id: 3, name: "back"), W(id: 9, name: "minimized B"),
                       W(id: 5, name: "front")]
        let ordered = HopperLogic.ordered(windows, id: { $0.id }, zOrder: [12, 5, 40, 3])
        #expect(ordered.map(\.name) == ["front", "back", "minimized A", "minimized B"])
    }

    @Test func layoutWrapsIntoRows() {
        let cols = HopperLogic.columns(count: 9, maxWidth: 1100)
        #expect(cols == 4)
        #expect(HopperLogic.rows(count: 9, columns: cols) == [[0, 1, 2, 3], [4, 5, 6, 7], [8]])
        #expect(HopperLogic.columns(count: 2, maxWidth: 3000) == 2)
        #expect(HopperLogic.columns(count: 5, maxWidth: 100) == 1)
        #expect(HopperLogic.rows(count: 0, columns: 3).isEmpty)
    }

    @Test func panelSizeFitsCards() {
        let size = HopperLogic.panelSize(count: 3, maxWidth: 1600)
        #expect(size.width == 660)        // 3 cards × 200 + 2 gaps × 14 + padding 32
        #expect(size.height == 218)       // padding 32 + header 22 + gap 14 + card 126 + title 24
        let two = HopperLogic.panelSize(count: 9, maxWidth: 1100)
        #expect(two.height == 546)        // 3 rows of 150 with 2 gaps
        #expect(two.width <= 990)
    }

    @Test func defaultsMatchPowerToys() {
        let s = WindowHopperSettings()
        // Key codes, not names: the grave key's name depends on the keyboard layout.
        #expect(s.next == Shortcut(0x32, [.option]))
        #expect(s.previous == Shortcut(0x32, [.option, .shift]))
        #expect(s.includeMinimized)
    }
}
