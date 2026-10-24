import CoreGraphics
import Foundation
import Testing
@testable import AlwaysOnTop
@testable import MacToysCore

@Suite struct AlwaysOnTopTests {
    @Test func presentationFollowsWindowState() {
        #expect(PinPresentation.resolve(visible: false, fullScreen: false, frontmost: false, hasFrame: true) == .hidden)
        #expect(PinPresentation.resolve(visible: true, fullScreen: true, frontmost: false, hasFrame: true) == .hidden)
        #expect(PinPresentation.resolve(visible: true, fullScreen: false, frontmost: true, hasFrame: true) == .border)
        #expect(PinPresentation.resolve(visible: true, fullScreen: false, frontmost: false, hasFrame: true) == .mirror)
        // Without a captured frame the mirror would be empty: keep the real window usable.
        #expect(PinPresentation.resolve(visible: true, fullScreen: false, frontmost: false, hasFrame: false) == .border)
    }

    @Test func panelSurroundsWindowWithBorder() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(PinGeometry.panelFrame(window: window, border: 4) == CGRect(x: 96, y: 196, width: 808, height: 608))
        #expect(PinGeometry.panelFrame(window: window, border: 0) == window)
    }

    @Test func ringRadiiHugTheWindowCorner() {
        let rounded = PinGeometry.radii(rounded: true, border: 5)
        #expect(rounded.inner == PinGeometry.windowCornerRadius)
        #expect(rounded.outer == PinGeometry.windowCornerRadius + 5)
        let square = PinGeometry.radii(rounded: false, border: 5)
        #expect(square.inner == 0 && square.outer == 0)
    }

    @Test func exclusionsAreFlippedIntoPanelSpace() {
        // Panel at y 100…500 (top-left space); the other window covers its top-left 100×50 corner.
        let panel = CGRect(x: 0, y: 100, width: 400, height: 400)
        let other = CGRect(x: -50, y: 80, width: 150, height: 70)
        let cut = PinGeometry.exclusions(panel: panel, others: [other])
        // Bottom-left view space: the overlap sits at the top, so its y is height − 50.
        #expect(cut == [CGRect(x: 0, y: 350, width: 100, height: 50)])
        #expect(PinGeometry.exclusions(panel: panel, others: [CGRect(x: 600, y: 0, width: 10, height: 10)]).isEmpty)
    }

    @Test func thicknessIsClamped() {
        #expect(PinGeometry.clampedThickness(0) == 1)
        #expect(PinGeometry.clampedThickness(6) == 6)
        #expect(PinGeometry.clampedThickness(400) == 24)
    }

    @Test func settingsRoundTripAndDefaults() throws {
        let defaults = AlwaysOnTopSettings()
        #expect(defaults.activation == Shortcut(0x11, [.control, .command]))
        #expect(defaults.activation?.modifiers.symbols == ["⌃", "⌘"])
        var s = defaults
        s.colorMode = .custom
        s.customColor = RGBA(hex: "#34C759")!
        s.excludedApps = ["Zoom", "com.example.game"]
        s.activation = nil
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AlwaysOnTopSettings.self, from: data) == s)
    }

    @Test func storedSettingsKeepNewDefaults() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        struct Old: Codable { var thickness = 9.0; var playSound = false }
        store.save(Old(), id: "alwaysontop")
        let loaded = store.load("alwaysontop", default: AlwaysOnTopSettings())
        #expect(loaded.thickness == 9)
        #expect(loaded.playSound == false)
        #expect(loaded.showBorder == true)
        #expect(loaded.raiseTrigger == .hover)
    }
}
