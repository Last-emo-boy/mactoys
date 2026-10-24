import CoreGraphics
import Foundation
import Testing
@testable import CropAndLock
@testable import MacToysCore

@Suite struct CropAndLockTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func selectionIsNormalizedWhicheverWayYouDrag() {
        let a = CropGeometry.selection(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50), in: bounds)
        #expect(a == CGRect(x: 100, y: 50, width: 200, height: 150))
        let b = CropGeometry.selection(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 200), in: bounds)
        #expect(a == b)
    }

    @Test func selectionIsClampedToTheWindow() {
        let r = CropGeometry.selection(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 1200, y: -40), in: bounds)
        #expect(r == CGRect(x: 700, y: 0, width: 100, height: 500))
    }

    @Test func tinySelectionsAreRejected() {
        #expect(!CropGeometry.isUsable(CGRect(x: 0, y: 0, width: 5, height: 300)))
        #expect(CropGeometry.isUsable(CGRect(x: 0, y: 0, width: 12, height: 12)))
    }

    @Test func pixelRectScalesWithTheCapture() {
        // A 2× capture of an 800×600 window.
        let px = CropGeometry.pixelRect(crop: CGRect(x: 100, y: 50, width: 200, height: 150),
                                        windowSize: CGSize(width: 800, height: 600),
                                        imageSize: CGSize(width: 1600, height: 1200))
        #expect(px == CGRect(x: 200, y: 100, width: 400, height: 300))
    }

    @Test func pixelRectStaysInsideTheImage() {
        let px = CropGeometry.pixelRect(crop: CGRect(x: 700, y: 500, width: 200, height: 200),
                                        windowSize: CGSize(width: 800, height: 600),
                                        imageSize: CGSize(width: 800, height: 600))
        #expect(px == CGRect(x: 700, y: 500, width: 100, height: 100))
        #expect(CropGeometry.pixelRect(crop: .zero, windowSize: .zero, imageSize: CGSize(width: 10, height: 10)).isNull)
    }

    @Test func interactiveCropPlacesTheSourceUnderTheCrop() {
        let crop = CGRect(x: 120, y: 80, width: 300, height: 200)
        let window = CGRect(x: 400, y: 300, width: 900, height: 700)
        let global = CropGeometry.globalRect(crop: crop, windowFrame: window)
        #expect(global == CGRect(x: 520, y: 380, width: 300, height: 200))
        // The crop window moved to (1000, 100): the source must follow so its area lands there.
        let origin = CropGeometry.sourceOrigin(crop: crop, contentOrigin: CGPoint(x: 1000, y: 100))
        #expect(origin == CGPoint(x: 880, y: 20))
        #expect(CropGeometry.globalRect(crop: crop, windowFrame: CGRect(origin: origin, size: window.size)).origin
                == CGPoint(x: 1000, y: 100))
    }

    @Test func keepMovesAndShrinksIntoTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let moved = CropGeometry.keep(CGRect(x: 1300, y: 10, width: 300, height: 200), inside: visible)
        #expect(moved == CGRect(x: 1140, y: 25, width: 300, height: 200))
        let shrunk = CropGeometry.keep(CGRect(x: 0, y: 0, width: 2880, height: 1000), inside: visible)
        #expect(shrunk.width == 1440)
        #expect(abs(shrunk.width / shrunk.height - 2.88) < 0.01)
        #expect(visible.contains(shrunk))
    }

    @Test func minimumSizeKeepsAspectRatio() {
        #expect(CropGeometry.minimumContentSize(for: CGSize(width: 400, height: 100)) == CGSize(width: 160, height: 40))
        #expect(CropGeometry.minimumContentSize(for: CGSize(width: 20, height: 30)) == CGSize(width: 20, height: 30))
    }

    @Test func defaultShortcutsMatchTheBrief() {
        let s = CropAndLockSettings()
        let mods: Modifiers = [.control, .option, .shift]
        #expect(s.thumbnail == Shortcut(0x11, mods))     // T
        #expect(s.interactive == Shortcut(0x0F, mods))   // R
        #expect(s.screenshot == Shortcut(0x01, mods))    // S
    }

    @Test func settingsRoundTrip() throws {
        var s = CropAndLockSettings()
        s.forwardClicks = false
        s.frameRate = 60
        s.screenshot = nil
        let back = try JSONDecoder().decode(CropAndLockSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
