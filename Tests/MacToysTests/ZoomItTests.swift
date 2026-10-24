import CoreGraphics
import Foundation
import Testing
@testable import ZoomIt
@testable import MacToysCore

@Suite struct ZoomItTests {
    let screen = CGSize(width: 1440, height: 900)

    private func close(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat = 1e-9) -> Bool { abs(a - b) <= t }

    // MARK: Zoom and pan

    @Test func levelOneShowsTheWholeScreen() {
        let r = ZoomMath.sourceRect(pointer: CGPoint(x: 300, y: 200), screen: screen, level: 1)
        #expect(r == CGRect(origin: .zero, size: screen))
    }

    @Test func pointerStaysOverTheSamePoint() {
        for level in [1.25, 2, 3.5, 8] {
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 720, y: 450), CGPoint(x: 1440, y: 900), CGPoint(x: 101, y: 777)] {
                let r = ZoomMath.sourceRect(pointer: p, screen: screen, level: level)
                #expect(close(r.width, screen.width / CGFloat(level)) && close(r.height, screen.height / CGFloat(level)))
                let shown = ZoomMath.sourcePoint(forDisplay: p, visible: r, screen: screen)
                #expect(close(shown.x, p.x, 1e-6) && close(shown.y, p.y, 1e-6))
                #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= screen.width + 1e-9 && r.maxY <= screen.height + 1e-9)
            }
        }
    }

    @Test func edgesAreReachable() {
        let topLeft = ZoomMath.sourceRect(pointer: .zero, screen: screen, level: 2)
        #expect(topLeft.origin == .zero)
        let bottomRight = ZoomMath.sourceRect(pointer: CGPoint(x: 1440, y: 900), screen: screen, level: 2)
        #expect(bottomRight.maxX == 1440 && bottomRight.maxY == 900)
        let outside = ZoomMath.sourceRect(pointer: CGPoint(x: -50, y: 5000), screen: screen, level: 4)
        #expect(outside.minX == 0 && outside.maxY == 900)
    }

    @Test func displayAndSourcePointsInvert() {
        let r = ZoomMath.sourceRect(pointer: CGPoint(x: 400, y: 300), screen: screen, level: 3)
        let d = CGPoint(x: 123, y: 456)
        let back = ZoomMath.displayPoint(forSource: ZoomMath.sourcePoint(forDisplay: d, visible: r, screen: screen),
                                         visible: r, screen: screen)
        #expect(close(back.x, d.x, 1e-6) && close(back.y, d.y, 1e-6))
    }

    @Test func layerFrameFillsTheContainerWithTheVisibleRect() {
        let r = CGRect(x: 360, y: 225, width: 720, height: 450)       // the middle at 2×
        let f = ZoomMath.layerFrame(showing: r, screen: screen)
        #expect(f == CGRect(x: -720, y: -450, width: 2880, height: 1800))
        // Top-left quarter: the image's top edge (y-up: maxY) sits on the container's top.
        let tl = ZoomMath.layerFrame(showing: CGRect(x: 0, y: 0, width: 720, height: 450), screen: screen)
        #expect(tl.minX == 0 && tl.maxY == 900)
    }

    @Test func levelSteppingAndClamping() {
        #expect(ZoomMath.step(2, zoomIn: true) == 2.5)
        #expect(ZoomMath.step(2.5, zoomIn: false) == 2)
        #expect(ZoomMath.step(1, zoomIn: false) == 1)
        #expect(ZoomMath.step(15, zoomIn: true) == 16)
        #expect(ZoomMath.clamp(0.2) == 1 && ZoomMath.clamp(99) == 16)
    }

    @Test func animationCurve() {
        #expect(ZoomMath.ease(0) == 0 && ZoomMath.ease(1) == 1 && ZoomMath.ease(0.5) == 0.5)
        #expect(ZoomMath.ease(-1) == 0 && ZoomMath.ease(2) == 1)
        #expect(abs(ZoomMath.interpolate(from: 1, to: 4, progress: 0.5) - 2) < 1e-9)
        #expect(ZoomMath.interpolate(from: 1, to: 4, progress: 1) == 4)
        var last = 1.0
        for i in 1...10 {
            let v = ZoomMath.interpolate(from: 1, to: 4, progress: Double(i) / 10)
            #expect(v >= last)
            last = v
        }
    }

    // MARK: Break timer

    @Test func timerFormatting() {
        #expect(BreakTimerFormat.clock(582) == "09:42")
        #expect(BreakTimerFormat.clock(0) == "00:00")
        #expect(BreakTimerFormat.clock(3600) == "1:00:00")
        #expect(BreakTimerFormat.clock(3905) == "1:05:05")
        #expect(BreakTimerFormat.clock(-5) == "00:00")
        #expect(BreakTimerFormat.display(remaining: 600, showElapsed: true) == ("10:00", false))
        #expect(BreakTimerFormat.display(remaining: 0.2, showElapsed: true) == ("00:01", false))
        #expect(BreakTimerFormat.display(remaining: 0, showElapsed: true) == ("+00:00", true))
        #expect(BreakTimerFormat.display(remaining: -72.6, showElapsed: true) == ("+01:12", true))
        #expect(BreakTimerFormat.display(remaining: -72.6, showElapsed: false) == ("00:00", true))
    }

    @Test func clockAdjustsWhileRunning() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var clock = BreakClock(start: t0, minutes: 10)
        #expect(clock.remaining(at: t0.addingTimeInterval(18)) == 582)
        clock.adjust(minutes: 1, at: t0.addingTimeInterval(18))
        #expect(clock.remaining(at: t0.addingTimeInterval(18)) == 642)
        clock.adjust(minutes: -20, at: t0.addingTimeInterval(18))
        #expect(clock.isExpired(at: t0.addingTimeInterval(18)))
        // After expiry, ↑ gives a fresh minute.
        clock.adjust(minutes: 1, at: t0.addingTimeInterval(100))
        #expect(clock.remaining(at: t0.addingTimeInterval(100)) == 60)
    }

    // MARK: DemoType

    @Test func segmentsSplitAtEnd() {
        let script = DemoTypeScript("first line\nsecond\n[end]\nnext\n[end]\n\n  \n")
        #expect(script.segments == [[.text("first line\nsecond")], [.text("next")]])
    }

    @Test func scriptWithoutEndIsOneSegment() {
        let script = DemoTypeScript("\nhello\r\nworld")
        #expect(script.segments == [[.text("hello\nworld")]])
    }

    @Test func controlsAreParsed() {
        let script = DemoTypeScript("ls[enter][pause:2]cd ..[up][down][left][right]")
        #expect(script.segments == [[.text("ls"), .key(.enter), .pause(2), .text("cd .."), .key(.up), .key(.down),
                                     .key(.left), .key(.right)]])
    }

    @Test func pasteBlocksTrimTheirNewlines() {
        let script = DemoTypeScript("a[paste]\nlet x = [1, 2]\n[/paste]b")
        #expect(script.segments == [[.text("a"), .paste("let x = [1, 2]"), .text("b")]])
    }

    @Test func unknownTagsAndBracketsAreLiteral() {
        let script = DemoTypeScript("arr[0] = [pause:x] [paste] [verylongcontrolname]")
        #expect(script.segments == [[.text("arr[0] = [pause:x] [paste] [verylongcontrolname]")]])
    }

    @Test func controlCharactersAreDropped() {
        let script = DemoTypeScript("a\u{7}b\tc\u{0}d")
        #expect(script.segments == [[.text("ab\tcd")]])
    }

    @Test func clipboardNeedsTheSafetyPrefix() {
        #expect(DemoTypeScript.fromClipboard("echo hi") == nil)
        #expect(DemoTypeScript.fromClipboard("[start]echo hi[end]")?.segments == [[.text("echo hi")]])
        #expect(DemoTypeScript.fromClipboard("[start]") == nil)
    }

    @Test func stepsAndTiming() {
        let steps = DemoTypeStep.steps(of: [.text("ab"), .key(.enter), .pause(1), .paste("x")])
        #expect(steps == [.character("a"), .character("b"), .key(.enter), .pause(1), .paste("x")])
        #expect(DemoTypeStep.delay(speed: 55, random: 0.5) == 0.055)
        #expect(DemoTypeStep.delay(speed: 100, random: 0) == 0.001)
        #expect(DemoTypeStep.delay(speed: 10, random: 1) == 0.2)
        #expect(DemoTypeStep.charactersPerPress(speed: 10) == 1)
        #expect(DemoTypeStep.charactersPerPress(speed: 55) == 2)
        #expect(DemoTypeStep.charactersPerPress(speed: 100) == 3)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndDefaults() throws {
        var s = ZoomItSettings()
        s.recordFormat = .gif
        s.timerPosition = .bottomRight
        let back = try JSONDecoder().decode(ZoomItSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let d = ZoomItSettings()
        #expect(d.zoomShortcut?.keys == ["⌃", "⌥", "1"])
        #expect(d.recordRegionShortcut?.keys == ["⌃", "⌥", "⇧", "5"])
        #expect(d.initialZoom == 2 && d.breakMinutes == 10 && d.typingSpeed == 55)
        #expect(PenColor.forKey("o") == .orange && PenColor.forKey("z") == nil)
    }
}
