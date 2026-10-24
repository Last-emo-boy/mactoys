import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import MouseUtilities

@Suite struct CursorWrapMathTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func singleDisplayWrapsBothWays() {
        let d = [laptop]
        #expect(CursorWrapMath.wrap(CGPoint(x: 1511, y: 400), delta: CGVector(dx: 5, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 1, y: 400))
        #expect(CursorWrapMath.wrap(CGPoint(x: 0, y: 400), delta: CGVector(dx: -5, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 1510, y: 400))
        #expect(CursorWrapMath.wrap(CGPoint(x: 700, y: 981), delta: CGVector(dx: 0, dy: 3), displays: d, mode: .both)
                == CGPoint(x: 700, y: 1))
        #expect(CursorWrapMath.wrap(CGPoint(x: 700, y: 0), delta: CGVector(dx: 0, dy: -3), displays: d, mode: .both)
                == CGPoint(x: 700, y: 980))
    }

    @Test func noWrapAwayFromEdgesOrWhenMovingInward() {
        let d = [laptop]
        #expect(CursorWrapMath.wrap(CGPoint(x: 800, y: 400), delta: CGVector(dx: 5, dy: 5), displays: d, mode: .both) == nil)
        #expect(CursorWrapMath.wrap(CGPoint(x: 1511, y: 400), delta: CGVector(dx: -5, dy: 0), displays: d, mode: .both) == nil)
    }

    @Test func modesRestrictTheAxis() {
        let d = [laptop]
        #expect(CursorWrapMath.wrap(CGPoint(x: 1511, y: 400), delta: CGVector(dx: 5, dy: 0), displays: d, mode: .vertical) == nil)
        #expect(CursorWrapMath.wrap(CGPoint(x: 700, y: 981), delta: CGVector(dx: 0, dy: 3), displays: d, mode: .horizontal) == nil)
        // Corner: both axes wrap together.
        #expect(CursorWrapMath.wrap(CGPoint(x: 1511, y: 981), delta: CGVector(dx: 2, dy: 2), displays: d, mode: .both)
                == CGPoint(x: 1, y: 1))
    }

    @Test func sideBySideDisplaysOnlyWrapAtTheOuterEdges() {
        let right = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let d = [laptop, right]
        // Inner edge: the system moves the pointer onto the other display; no wrap.
        #expect(CursorWrapMath.wrap(CGPoint(x: 1511, y: 400), delta: CGVector(dx: 5, dy: 0), displays: d, mode: .both) == nil)
        // Right edge of the right display → left edge of the laptop.
        #expect(CursorWrapMath.wrap(CGPoint(x: 4071, y: 400), delta: CGVector(dx: 5, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 1, y: 400))
        // Below the laptop's height only the big display covers y: it wraps onto itself.
        #expect(CursorWrapMath.wrap(CGPoint(x: 4071, y: 1200), delta: CGVector(dx: 5, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 1513, y: 1200))
        // Left edge of the laptop → right edge of the big display.
        #expect(CursorWrapMath.wrap(CGPoint(x: 0, y: 900), delta: CGVector(dx: -4, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 4070, y: 900))
        // Bottom of the laptop is an outer edge (nothing below it): wrap to the top of the same column.
        #expect(CursorWrapMath.wrap(CGPoint(x: 700, y: 981), delta: CGVector(dx: 0, dy: 3), displays: d, mode: .both)
                == CGPoint(x: 700, y: 1))
    }

    @Test func stackedAndOffsetDisplays() {
        // An external display above the laptop, shifted right, with negative coordinates.
        let above = CGRect(x: 300, y: -1080, width: 1920, height: 1080)
        let d = [laptop, above]
        // Top edge of the external display, above the laptop: wrap to the laptop's bottom.
        #expect(CursorWrapMath.wrap(CGPoint(x: 800, y: -1080), delta: CGVector(dx: 0, dy: -5), displays: d, mode: .both)
                == CGPoint(x: 800, y: 980))
        // Bottom of the laptop goes back to the top of the external display.
        #expect(CursorWrapMath.wrap(CGPoint(x: 800, y: 981), delta: CGVector(dx: 0, dy: 5), displays: d, mode: .both)
                == CGPoint(x: 800, y: -1079))
        // Laptop's top edge left of the external display is an outer edge (x 100 isn't covered above).
        #expect(CursorWrapMath.wrap(CGPoint(x: 100, y: 0), delta: CGVector(dx: 0, dy: -5), displays: d, mode: .both)
                == CGPoint(x: 100, y: 980))
        // Under the external display the laptop's top edge is an inner edge.
        #expect(CursorWrapMath.wrap(CGPoint(x: 800, y: 0), delta: CGVector(dx: 0, dy: -5), displays: d, mode: .both) == nil)
        // Right edge of the external display (x 2219): only it covers y −500, so it wraps onto itself.
        #expect(CursorWrapMath.wrap(CGPoint(x: 2219, y: -500), delta: CGVector(dx: 3, dy: 0), displays: d, mode: .both)
                == CGPoint(x: 301, y: -500))
    }

    @Test func pointerOutsideAllDisplaysUsesTheNearest() {
        #expect(CursorWrapMath.wrap(CGPoint(x: 1512, y: 400), delta: CGVector(dx: 5, dy: 0), displays: [laptop], mode: .both)
                == CGPoint(x: 1, y: 400))
        #expect(CursorWrapMath.wrap(.zero, delta: .zero, displays: [], mode: .both) == nil)
    }
}

@Suite struct ActivationDetectorTests {
    @Test func doubleTapFires() {
        var d = DoubleTapDetector()
        let r1 = d.watchedKey(down: true, time: 0, clean: true)
        #expect(!r1)
        let r2 = d.watchedKey(down: false, time: 0.08, clean: true)
        #expect(!r2)
        let r3 = d.watchedKey(down: true, time: 0.25, clean: true)
        #expect(!r3)
        let r4 = d.watchedKey(down: false, time: 0.32, clean: true)
        #expect(r4)
        // It resets after firing.
        let r5 = d.watchedKey(down: true, time: 0.4, clean: true)
        #expect(!r5)
        let r6 = d.watchedKey(down: false, time: 0.45, clean: true)
        #expect(!r6)
    }

    @Test func doubleTapRejectsSlowOrLongOrDirtyPresses() {
        var d = DoubleTapDetector()
        d.maxGap = 0.5
        // Too long between taps: the second press starts over.
        _ = d.watchedKey(down: true, time: 0, clean: true)
        _ = d.watchedKey(down: false, time: 0.05, clean: true)
        _ = d.watchedKey(down: true, time: 0.8, clean: true)
        let r7 = d.watchedKey(down: false, time: 0.85, clean: true)
        #expect(!r7)
        let r8 = d.watchedKey(down: true, time: 1.0, clean: true)
        #expect(!r8)
        let r9 = d.watchedKey(down: false, time: 1.05, clean: true)
        #expect(r9)
        // Held too long.
        _ = d.watchedKey(down: true, time: 2, clean: true)
        _ = d.watchedKey(down: false, time: 2.05, clean: true)
        _ = d.watchedKey(down: true, time: 2.2, clean: true)
        let r10 = d.watchedKey(down: false, time: 2.9, clean: true)
        #expect(!r10)
        // Another modifier held.
        _ = d.watchedKey(down: true, time: 4, clean: true)
        _ = d.watchedKey(down: false, time: 4.05, clean: true)
        _ = d.watchedKey(down: true, time: 4.2, clean: false)
        let r11 = d.watchedKey(down: false, time: 4.25, clean: true)
        #expect(!r11)
    }

    @Test func doubleTapInterruptedByAnotherKey() {
        var d = DoubleTapDetector()
        _ = d.watchedKey(down: true, time: 0, clean: true)
        _ = d.watchedKey(down: false, time: 0.05, clean: true)
        d.interrupt()
        _ = d.watchedKey(down: true, time: 0.2, clean: true)
        let r12 = d.watchedKey(down: false, time: 0.25, clean: true)
        #expect(!r12)
    }

    @Test func shakeDetectsBackAndForth() {
        var s = ShakeDetector()
        s.minimumDistance = 1000
        s.factor = 4
        s.interval = 1
        var fired = false
        // ±150 px swings, 60 events per second.
        for i in 0..<60 where !fired {
            let x = 500 + (i % 2 == 0 ? -150.0 : 150.0)
            fired = s.add(CGPoint(x: x, y: 300 + Double(i % 3)), at: Double(i) / 60)
        }
        #expect(fired)
    }

    @Test func longStraightMoveIsNotAShake() {
        var s = ShakeDetector()
        s.minimumDistance = 1000
        s.factor = 4
        var fired = false
        for i in 0..<120 { fired = fired || s.add(CGPoint(x: Double(i) * 30, y: 200), at: Double(i) / 120) }
        #expect(!fired)
    }

    @Test func slowShakingOutsideTheIntervalIsNotAShake() {
        var s = ShakeDetector()
        s.minimumDistance = 1000
        s.factor = 4
        s.interval = 0.5
        var fired = false
        // Swings every 0.25 s: only two samples fit in the window.
        for i in 0..<40 { fired = fired || s.add(CGPoint(x: i % 2 == 0 ? 0 : 400, y: 0), at: Double(i) * 0.25) }
        #expect(!fired)
    }

    @Test func smallJitterIsNotAShake() {
        var s = ShakeDetector()
        var fired = false
        for i in 0..<240 { fired = fired || s.add(CGPoint(x: 100 + Double(i % 2) * 3, y: 100), at: Double(i) / 240) }
        #expect(!fired)
    }
}

@Suite struct ButtonLockMachineTests {
    func machine() -> ButtonLockMachine {
        ButtonLockMachine(lockable: [.right, .left], holdDuration: 1.2, dragThreshold: 5)
    }

    @Test func holdStillLocksAndNextClickReleases() {
        var m = machine()
        let r13 = m.down(.right, at: 0, point: CGPoint(x: 100, y: 100))
        #expect(r13 == .pass)
        let r14 = m.moved(to: CGPoint(x: 102, y: 101))
        #expect(r14 == .pass)  // within the threshold
        let (d, locked) = m.up(.right, at: 1.3)
        #expect(d == .swallow && locked)
        #expect(m.lockedButton == .right)
        // Moves while locked become right-drags.
        let r15 = m.moved(to: CGPoint(x: 300, y: 300))
        #expect(r15 == .becomeDrag(.right))
        // The next press (any button) becomes the release of the locked button…
        let r16 = m.down(.left, at: 3, point: CGPoint(x: 300, y: 300))
        #expect(r16 == .becomeUp(.right))
        // …drags of that physical button are plain moves…
        let r17 = m.moved(to: CGPoint(x: 305, y: 300))
        #expect(r17 == .becomeMove)
        // …and its release is swallowed.
        let r18 = m.up(.left, at: 3.1)
        #expect(r18.0 == .swallow)
        #expect(m.state == .idle)
        let r19 = m.moved(to: .zero)
        #expect(r19 == .pass)
    }

    @Test func shortPressIsAClick() {
        var m = machine()
        _ = m.down(.right, at: 0, point: .zero)
        let (d, locked) = m.up(.right, at: 0.3)
        #expect(d == .pass && !locked)
        #expect(m.state == .idle)
    }

    @Test func movingBeyondTheThresholdIsANormalDrag() {
        var m = machine()
        _ = m.down(.left, at: 0, point: .zero)
        let r20 = m.moved(to: CGPoint(x: 10, y: 0))
        #expect(r20 == .pass)
        let r21 = m.up(.left, at: 2)
        #expect(r21.0 == .pass)
        #expect(m.lockedButton == nil)
    }

    @Test func zeroThresholdCancelsOnAnyMovement() {
        var m = ButtonLockMachine(lockable: [.left], holdDuration: 0.2, dragThreshold: 0)
        _ = m.down(.left, at: 0, point: .zero)
        _ = m.moved(to: CGPoint(x: 0.5, y: 0))
        let r22 = m.up(.left, at: 1)
        #expect(r22.0 == .pass)
    }

    @Test func buttonsThatArentLockableAndChordsPass() {
        var m = machine()
        let r23 = m.down(.middle, at: 0, point: .zero)
        #expect(r23 == .pass)
        let r24 = m.up(.middle, at: 2)
        #expect(r24.0 == .pass)
        _ = m.down(.right, at: 0, point: .zero)
        _ = m.down(.left, at: 0.1, point: .zero)  // chord
        let r25 = m.up(.right, at: 2)
        #expect(r25.0 == .pass)
        #expect(m.lockedButton == nil)
    }

    @Test func releasingWithTheSameButton() {
        var m = machine()
        _ = m.down(.left, at: 0, point: .zero)
        _ = m.up(.left, at: 1.5)
        let r26 = m.down(.left, at: 4, point: .zero)
        #expect(r26 == .becomeUp(.left))
        let r27 = m.up(.left, at: 4.1)
        #expect(r27.0 == .swallow)
        #expect(m.state == .idle)
    }
}

@Suite struct GlidingCursorTests {
    @Test func phasesThenClick() {
        var g = GlidingCursor()
        g.start(at: CGPoint(x: 100, y: 50), in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(g.phase == .xFast)
        g.tick(fast: 20, slow: 2)
        #expect(g.position.x == 120)
        let r28 = g.press()
        #expect(r28 == nil)
        #expect(g.phase == .xSlow)
        g.tick(fast: 20, slow: 2)
        #expect(g.position.x == 122)
        _ = g.press()
        #expect(g.phase == .yFast)
        g.tick(fast: 20, slow: 2)
        #expect(g.position == CGPoint(x: 122, y: 70))
        _ = g.press()
        g.tick(fast: 20, slow: 2)
        let r29 = g.press()
        #expect(r29 == CGPoint(x: 122, y: 72))
        #expect(!g.isActive)
    }

    @Test func sweepWrapsAtTheEdge() {
        var g = GlidingCursor()
        g.start(at: CGPoint(x: 995, y: 10), in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        g.tick(fast: 20, slow: 2)
        #expect(g.position.x == 15)
    }
}

@Suite struct MouseJumpLayoutTests {
    let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 262, width: 1280, height: 720)]

    @Test func fitsInTheMaximumSize() {
        let l = JumpLayout(displays: displays, maxSize: CGSize(width: 600, height: 400),
                           metrics: .init(padding: 10, margin: 10, bezel: 4))
        #expect(l.size.width <= 600 + 1)
        #expect(l.size.height <= 400 + 1)
        #expect(abs(l.scale - 580.0 / 2792.0) < 0.0001)
        // The arrangement is kept: display 2 is to the right, bottom-aligned.
        #expect(l.slots[1].minX > l.slots[0].maxX)
        #expect(abs(l.slots[1].maxY - l.slots[0].maxY) < 1)
    }

    @Test func neverScalesUp() {
        let l = JumpLayout(displays: [CGRect(x: 0, y: 0, width: 300, height: 200)], maxSize: CGSize(width: 1600, height: 1200),
                           metrics: .init(padding: 0, margin: 0, bezel: 0))
        #expect(l.scale == 1)
        #expect(l.size == CGSize(width: 300, height: 200))
    }

    @Test func clickMapsBackToTheDisplay() throws {
        let l = JumpLayout(displays: displays, maxSize: CGSize(width: 600, height: 400),
                           metrics: .init(padding: 10, margin: 10, bezel: 4))
        let center1 = CGPoint(x: l.images[0].midX, y: l.images[0].midY)
        let g = try #require(l.globalPoint(for: center1))
        #expect(abs(g.x - 756) < 1 && abs(g.y - 491) < 1)
        let g2 = try #require(l.globalPoint(for: CGPoint(x: l.images[1].minX, y: l.images[1].minY)))
        #expect(abs(g2.x - 1512) < 1 && abs(g2.y - 262) < 1)
        // A click on the bezel lands on the screen's edge.
        let bezel = CGPoint(x: l.slots[1].maxX - 1, y: l.slots[1].maxY - 1)
        let g3 = try #require(l.globalPoint(for: bezel))
        #expect(g3 == CGPoint(x: 2791, y: 981))
        // Round trip.
        let p = try #require(l.previewPoint(for: CGPoint(x: 2000, y: 600)))
        let back = try #require(l.globalPoint(for: p))
        #expect(abs(back.x - 2000) < 0.5 && abs(back.y - 600) < 0.5)
        // Outside every display slot.
        #expect(l.globalPoint(for: CGPoint(x: 1, y: 1)) == nil)
    }
}

@Suite struct CrosshairGeometryTests {
    @Test func armsAroundTheCenter() {
        let arms = CrosshairGeometry.arms(center: CGPoint(x: 100, y: 100), bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                          radius: 20, thickness: 4, length: nil, orientation: .both)
        #expect(arms == [CGRect(x: 0, y: 98, width: 80, height: 4), CGRect(x: 120, y: 98, width: 280, height: 4),
                         CGRect(x: 98, y: 0, width: 4, height: 80), CGRect(x: 98, y: 120, width: 4, height: 180)])
    }

    @Test func fixedLengthAndOrientation() {
        let arms = CrosshairGeometry.arms(center: CGPoint(x: 100, y: 100), bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                          radius: 10, thickness: 2, length: 30, orientation: .horizontal)
        #expect(arms == [CGRect(x: 60, y: 99, width: 30, height: 2), CGRect(x: 110, y: 99, width: 30, height: 2)])
        // A center outside the bounds on one side drops the empty arm.
        let edge = CrosshairGeometry.arms(center: CGPoint(x: 5, y: 100), bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                          radius: 10, thickness: 2, length: nil, orientation: .horizontal)
        #expect(edge.count == 1)
    }
}

@Suite struct MouseSettingsTests {
    @Test @MainActor func defaultsAndRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = MouseUtilitiesSettings()
        #expect(s.highlighter.primaryColor.hex == "#BFFF00A6")
        #expect(s.buttonLock.holdDuration == 1200 && s.buttonLock.dragThreshold == 5 && s.buttonLock.right && !s.buttonLock.left)
        #expect(!s.autoHide.enabled && s.autoHide.hideWhileTyping && s.autoHide.idleDelay == 5)
        s.highlighter.shortcut = nil
        s.jump.style = .compact
        store.save(s, id: "m")
        let back = store.load("m", default: MouseUtilitiesSettings())
        #expect(back == s)
        #expect(back.highlighter.shortcut == nil)
    }
}
