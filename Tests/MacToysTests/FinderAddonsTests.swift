import Foundation
import Testing
@testable import FinderAddons
@testable import PreviewKit

@Suite struct FinderAddonsTests {
    @Test func pluginkitOutputParsing() {
        let id = "com.w33d.mactoys.quicklook"
        let enabled = "+    com.w33d.mactoys.quicklook(1.0.0)\tB1C2-uuid\t2026-10-24 21:10:00 +0000\t/Users/x/Applications/MacToys.app/Contents/PlugIns/MacToysQuickLook.appex\n"
        let s = ExtensionStatus.parse(enabled, identifier: id)
        #expect(s.state == .enabled)
        #expect(s.version == "1.0.0")
        #expect(s.paths == ["/Users/x/Applications/MacToys.app/Contents/PlugIns/MacToysQuickLook.appex"])

        let disabled = ExtensionStatus.parse("-    com.w33d.mactoys.quicklook(1.0.0)\tuuid\tdate\t/A.appex\n", identifier: id)
        #expect(disabled.state == .disabled)

        let defaultOn = ExtensionStatus.parse("     com.w33d.mactoys.quicklook(1.0.0)\tuuid\tdate\t/A.appex\n", identifier: id)
        #expect(defaultOn.state == .enabled)

        let two = ExtensionStatus.parse("-    \(id)(1.0.0)\tu\td\t/A.appex\n+    \(id)(1.0.0)\tu\td\t/B.appex\n", identifier: id)
        #expect(two.state == .enabled && two.paths.count == 2)

        #expect(ExtensionStatus.parse("", identifier: id).state == .notRegistered)
        #expect(ExtensionStatus.parse("+    com.other.thing(2)\tu\td\t/X.appex", identifier: id).state == .notRegistered)
    }

    @Test func moduleSwitchIsReadFromGeneralSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let general = dir.appendingPathComponent("general.json")
        #expect(FinderAddonsSettings.moduleEnabled(generalURL: general))          // no file: on
        try Data(#"{"enabled": {"finderaddons": false, "peek": true}}"#.utf8).write(to: general)
        #expect(!FinderAddonsSettings.moduleEnabled(generalURL: general))
        try Data(#"{"enabled": {"peek": false}}"#.utf8).write(to: general)
        #expect(FinderAddonsSettings.moduleEnabled(generalURL: general))
    }

    @Test func perTypeSwitches() {
        var s = FinderAddonsSettings()
        #expect(s.previewEnabled(.stl) && s.thumbnailEnabled(.stl))
        s.previewSTL = false
        s.thumbnailGCode = false
        #expect(!s.previewEnabled(.stl))
        #expect(!s.thumbnailEnabled(.gcode) && !s.thumbnailEnabled(.bgcode))
        #expect(!s.previewEnabled(.pdf))            // PDF previews stay with macOS
        #expect(!s.thumbnailEnabled(.code("swift")))
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var s = FinderAddonsSettings()
        s.codeTheme = .dark
        s.svgBackground = .checkerboardDark
        s.gcodeView = .top
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(FinderAddonsSettings.self, from: data) == s)
    }
}
