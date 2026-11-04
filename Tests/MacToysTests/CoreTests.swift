import AppKit
import Foundation
import Testing
@testable import MacToysCore

@Suite struct CoreTests {
    @Test func rgbaHexRoundTrip() {
        #expect(RGBA(hex: "#0A84FF")?.hex == "#0A84FF")
        #expect(RGBA(hex: "#FF000080")?.alpha ?? 0 > 0.49)
        #expect(RGBA(hex: "fff")?.hex == "#FFFFFF")
        #expect(RGBA(hex: "nope") == nil)
    }

    @Test func settingsMergeKeepsNewDefaults() throws {
        struct V1: Codable { var a = 1 }
        struct V2: Codable, Equatable { var a = 1; var b = "new" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        store.save(V1(a: 5), id: "x")
        let loaded = store.load("x", default: V2())
        #expect(loaded == V2(a: 5, b: "new"))
    }

    @Test func clearedOptionalStaysCleared() throws {
        struct S: Codable, Equatable { var shortcut: Shortcut? = Shortcut(8, [.control, .option]); var n = 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        store.save(S(shortcut: nil, n: 2), id: "s", defaults: S())
        #expect(store.load("s", default: S()) == S(shortcut: nil, n: 2))
    }

    @Test func appCommandURLRoundTrip() {
        let c = AppCommand(module: "powerrename", action: "open", parameters: ["q": "a b"],
                           files: [URL(fileURLWithPath: "/tmp/a b.txt")])
        let back = AppCommand(url: c.url)
        #expect(back?.module == "powerrename")
        #expect(back?.action == "open")
        #expect(back?.parameters["q"] == "a b")
        #expect(back?.files.first?.path == "/tmp/a b.txt")
    }

    @Test func liveCaptureOwnWindowExclusion() {
        // Live Zoom: its panel (999) and overlays over it stay out; the menu bar panel and Settings are captured.
        let overZoom = LiveCapture.OwnWindows.atOrAbove(NSWindow.Level(rawValue: 999))
        #expect(overZoom.excludes(layer: 999))
        #expect(overZoom.excludes(layer: 1001))
        #expect(!overZoom.excludes(layer: Int(CGWindowLevelForKey(.popUpMenuWindow))))
        #expect(!overZoom.excludes(layer: 0))
        #expect(LiveCapture.OwnWindows.all.excludes(layer: 0))
    }

    @Test func flyoutShowsChosenOrDefaultActions() {
        let available = ["a", "b", "c", "d", "e"]
        // Defaults keep their order, skip what's unavailable and are topped up to the limit.
        let d = QuickAccessLayout.split(available: available, chosen: nil, defaults: ["d", "x", "b"], limit: 3)
        #expect(d.shown == ["d", "b", "a"])
        #expect(d.more == ["c", "e"])
        // A user's list is used as chosen, even when empty.
        #expect(QuickAccessLayout.split(available: available, chosen: ["e", "zz"], defaults: [], limit: 3).shown == ["e"])
        #expect(QuickAccessLayout.split(available: available, chosen: [], defaults: ["a"], limit: 3).shown.isEmpty)
        #expect(QuickAccessLayout.toggling("c", on: true, shown: ["a"]) == ["a", "c"])
        #expect(QuickAccessLayout.toggling("a", on: false, shown: ["a", "c"]) == ["c"])
    }

    @Test func shortcutDisplay() {
        let s = Shortcut(8, [.control, .option])
        #expect(s.modifiers.symbols == ["⌃", "⌥"])
        #expect(s.matches(keyCode: 8, flags: [.maskControl, .maskAlternate]))
        #expect(!s.matches(keyCode: 8, flags: [.maskControl]))
    }
}
