import AppKit
import Foundation
import Testing
@testable import MacToysCore
@testable import PrivacyScreen

@Suite struct PrivacyScreenBackoffTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func delaysDoubleAndCap() {
        #expect(UnlockBackoff.delay(afterFailures: 0) == 0)
        #expect(UnlockBackoff.delay(afterFailures: 1) == 1)
        #expect(UnlockBackoff.delay(afterFailures: 2) == 2)
        #expect(UnlockBackoff.delay(afterFailures: 3) == 4)
        #expect(UnlockBackoff.delay(afterFailures: 4) == 8)
        #expect(UnlockBackoff.delay(afterFailures: 9) == 256)
        #expect(UnlockBackoff.delay(afterFailures: 10) == UnlockBackoff.cap)
        #expect(UnlockBackoff.delay(afterFailures: 1000) == UnlockBackoff.cap)
    }

    @Test func eachWrongPasswordWaitsLonger() {
        var b = UnlockBackoff()
        #expect(b.canTryPassword(at: t0))
        b.recordFailure(.password, at: t0)
        #expect(!b.canTryPassword(at: t0.addingTimeInterval(0.5)))
        #expect(b.canTryPassword(at: t0.addingTimeInterval(1)))
        b.recordFailure(.password, at: t0.addingTimeInterval(1))
        #expect(b.remainingWait(at: t0.addingTimeInterval(1)) == 2)
        b.recordFailure(.password, at: t0.addingTimeInterval(3))
        #expect(b.nextAttempt == t0.addingTimeInterval(7))
        #expect(b.remainingWait(at: t0.addingTimeInterval(5)) == 2)
        #expect(b.remainingWait(at: t0.addingTimeInterval(60)) == 0)
    }

    @Test func touchIDFailuresAreListedButNotPenalized() {
        var b = UnlockBackoff()
        b.recordFailure(.touchID, at: t0)
        b.recordFailure(.touchID, at: t0.addingTimeInterval(1))
        #expect(b.canTryPassword(at: t0.addingTimeInterval(1)))
        #expect(b.penalized == 0)
        b.recordFailure(.password, at: t0.addingTimeInterval(2))
        #expect(b.attempts.map(\.method) == [.touchID, .touchID, .password])
        #expect(b.attempts.map(\.date) == [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(2)])
        #expect(b.remainingWait(at: t0.addingTimeInterval(2)) == 1)
    }

    @Test func resetForgetsEverything() {
        var b = UnlockBackoff()
        b.recordFailure(.password, at: t0)
        b.reset()
        #expect(b.attempts.isEmpty)
        #expect(b.nextAttempt == nil)
        #expect(b.canTryPassword(at: t0))
    }
}

@Suite struct PrivacyScreenAwayTimerTests {
    func timers(blur: TimeInterval? = 60, lock: TimeInterval? = 300, pause: Bool = true) -> AwayTimers {
        var t = AwayTimers()
        t.blurAfter = blur
        t.lockAfter = lock
        t.pauseWhileDisplayKeptAwake = pause
        return t
    }

    @Test func blurThenLockOncePerIdlePeriod() {
        var t = timers()
        do { let r = t.update(idle: 30, displayKeptAwake: false, locked: false); #expect(r == nil) }
        do { let r = t.update(idle: 60, displayKeptAwake: false, locked: false); #expect(r == .blur) }
        do { let r = t.update(idle: 120, displayKeptAwake: false, locked: false); #expect(r == nil) }
        do { let r = t.update(idle: 300, displayKeptAwake: false, locked: false); #expect(r == .lock) }
        do { let r = t.update(idle: 400, displayKeptAwake: false, locked: false); #expect(r == nil) }
    }

    @Test func inputStartsANewPeriod() {
        var t = timers()
        _ = t.update(idle: 70, displayKeptAwake: false, locked: false)
        #expect(t.firedBlur)
        do { let r = t.update(idle: 2, displayKeptAwake: false, locked: false); #expect(r == nil) }
        #expect(!t.firedBlur)
        do { let r = t.update(idle: 61, displayKeptAwake: false, locked: false); #expect(r == .blur) }
    }

    @Test func lockSkipsTheBlurWhenItComesFirst() {
        var t = timers(blur: 600, lock: 120)
        do { let r = t.update(idle: 130, displayKeptAwake: false, locked: false); #expect(r == .lock) }
        do { let r = t.update(idle: 700, displayKeptAwake: false, locked: false); #expect(r == nil) }
    }

    @Test func pausesWhileAnotherAppKeepsTheDisplayOn() {
        var t = timers(blur: nil, lock: 300)
        do { let r = t.update(idle: 100, displayKeptAwake: false, locked: false); #expect(r == nil) }
        // A video starts: nothing fires however long it plays.
        do { let r = t.update(idle: 200, displayKeptAwake: true, locked: false); #expect(r == nil) }
        do { let r = t.update(idle: 2000, displayKeptAwake: true, locked: false); #expect(r == nil) }
        #expect(t.effectiveIdle == 200)
        // It ends: only idle time outside the video counts. The gap up to the first sample without
        // the assertion counts as paused too (the timers err on the side of waiting).
        do { let r = t.update(idle: 2050, displayKeptAwake: false, locked: false); #expect(r == nil) }
        #expect(t.effectiveIdle == 200)
        do { let r = t.update(idle: 2149, displayKeptAwake: false, locked: false); #expect(r == nil) }
        do { let r = t.update(idle: 2150, displayKeptAwake: false, locked: false); #expect(r == .lock) }
        // New input clears the paused time.
        do { let r = t.update(idle: 1, displayKeptAwake: false, locked: false); #expect(r == nil) }
        #expect(t.pausedTime == 0)
    }

    @Test func assertionsIgnoredWhenPauseIsOff() {
        var t = timers(blur: 60, lock: nil, pause: false)
        do { let r = t.update(idle: 61, displayKeptAwake: true, locked: false); #expect(r == .blur) }
    }

    @Test func nothingFiresWhileLocked() {
        var t = timers()
        do { let r = t.update(idle: 1000, displayKeptAwake: false, locked: true); #expect(r == nil) }
        #expect(!t.firedLock)
    }

    @Test func disabledTimers() {
        var t = timers(blur: nil, lock: nil)
        #expect(!t.isEnabled)
        do { let r = t.update(idle: 100_000, displayKeptAwake: false, locked: false); #expect(r == nil) }
    }

    @Test func otherProcessesDisplayAssertionsCount() {
        let own: Int32 = 500
        let video: [Int32: [[String: Any]]] = [
            own: [["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255]],
            376: [["AssertType": "InternalPreventDisplaySleep", "AssertLevel": 255]],
            31860: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],
        ]
        #expect(!PowerAssertions.keepsDisplayAwake(video, excluding: own))
        var call = video
        call[777] = [["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255]]
        #expect(PowerAssertions.keepsDisplayAwake(call, excluding: own))
        var off = video
        off[778] = [["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 0]]
        #expect(!PowerAssertions.keepsDisplayAwake(off, excluding: own))
        off[779] = [["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255]]
        #expect(PowerAssertions.keepsDisplayAwake(off, excluding: own))
    }
}

@Suite struct PrivacyScreenHotCornerTests {
    // Cocoa coordinates: y grows upward.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func cornersOfASingleDisplay() {
        let screens = [main]
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 981), screens: screens) == .topLeft)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1511, y: 982), screens: screens) == .topRight)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1, y: 0), screens: screens) == .bottomLeft)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1510, y: 2), screens: screens) == .bottomRight)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 700, y: 981), screens: screens) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 500), screens: screens) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 20, y: 960), screens: screens) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 5000, y: 5000), screens: screens) == nil)
    }

    @Test func cornersSharedWithAnotherDisplayDontCount() {
        // An external display to the right, top-aligned.
        let external = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
        let screens = [main, external]
        // The main display's right corners lead onto the external one.
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1511, y: 981), screens: screens) == nil)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1511, y: 1), screens: screens) == nil)
        // The far corners of both are real.
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 981), screens: screens) == .topLeft)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 4071, y: 981), screens: screens) == .topRight)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 4071, y: -458), screens: screens) == .bottomRight)
        // Top-aligned, the external display's top-left corner touches the main display: no corner.
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1513, y: 981), screens: screens) == nil)
        // Placed higher, it sticks out above the main display and becomes a real corner.
        let raised = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        #expect(HotCornerGeometry.corner(at: CGPoint(x: 1513, y: 1239), screens: [main, raised]) == .topLeft)
    }

    @Test func dwellFiresOnceUntilThePointerLeaves() {
        var t = HotCornerTracker(target: .topRight, dwell: 0.5)
        let t0 = Date(timeIntervalSince1970: 1000)
        do { let r = t.update(corner: .topRight, now: t0); #expect(r == .waiting(until: t0.addingTimeInterval(0.5))) }
        do { let r = t.update(corner: .topRight, now: t0.addingTimeInterval(0.3)); #expect(r == .waiting(until: t0.addingTimeInterval(0.5))) }
        do { let r = t.update(corner: .topRight, now: t0.addingTimeInterval(0.5)); #expect(r == .fire) }
        do { let r = t.update(corner: .topRight, now: t0.addingTimeInterval(3)); #expect(r == .idle) }
        do { let r = t.update(corner: nil, now: t0.addingTimeInterval(4)); #expect(r == .idle) }
        do { let r = t.update(corner: .topRight, now: t0.addingTimeInterval(5)); #expect(r == .waiting(until: t0.addingTimeInterval(5.5))) }
    }

    @Test func otherCornersAndOffDoNothing() {
        var t = HotCornerTracker(target: .bottomLeft, dwell: 0.2)
        let t0 = Date()
        do { let r = t.update(corner: .topLeft, now: t0); #expect(r == .idle) }
        do { let r = t.update(corner: .topLeft, now: t0.addingTimeInterval(5)); #expect(r == .idle) }
        var off = HotCornerTracker(target: .none, dwell: 0.2)
        do { let r = off.update(corner: ScreenCorner.none, now: t0.addingTimeInterval(9)); #expect(r == .idle) }
    }
}

@Suite struct PrivacyScreenRegionTests {
    @Test func subtractingLeavesFourBands() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        let parts = RegionGeometry.subtract(CGRect(x: 25, y: 25, width: 50, height: 50), from: r)
        #expect(parts.count == 4)
        #expect(RegionGeometry.area(parts) == CGFloat(100 * 100 - 50 * 50))
        for a in parts { for b in parts where a != b { #expect(a.intersection(b).area == 0) } }
        #expect(RegionGeometry.subtract(CGRect(x: 200, y: 200, width: 5, height: 5), from: r) == [r])
        #expect(RegionGeometry.subtract(CGRect(x: -10, y: -10, width: 200, height: 200), from: r).isEmpty)
    }

    @Test func visiblePartIsTheWindowMinusEverythingAbove() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let above = [CGRect(x: 300, y: 50, width: 400, height: 200),   // covers the top-right
                     CGRect(x: 0, y: 350, width: 150, height: 100)]    // covers a bottom-left corner
        let parts = RegionGeometry.visibleParts(of: window, above: above)
        let covered = CGRect(x: 300, y: 100, width: 200, height: 150).area + CGRect(x: 100, y: 350, width: 50, height: 50).area
        #expect(abs(RegionGeometry.area(parts) - (window.area - covered)) < 0.001)
        #expect(RegionGeometry.contains(parts, CGPoint(x: 150, y: 150)))
        #expect(!RegionGeometry.contains(parts, CGPoint(x: 400, y: 120)))
        #expect(!RegionGeometry.contains(parts, CGPoint(x: 120, y: 380)))
        #expect(RegionGeometry.visibleParts(of: window, above: [window.insetBy(dx: -1, dy: -1)]).isEmpty)
    }

    @Test func localCoordinatesFlipIntoTheWindow() {
        // Primary display 1000 high; a window at Cocoa (100, 200, 300, 400) spans AX y 400…800.
        let local = RegionGeometry.local(CGRect(x: 150, y: 450, width: 10, height: 20),
                                         in: CGRect(x: 100, y: 200, width: 300, height: 400), primaryHeight: 1000)
        #expect(local == CGRect(x: 50, y: 330, width: 10, height: 20))
    }

    func sample(_ id: CGWindowID, _ pid: pid_t, _ frame: CGRect, layer: Int = 0) -> WindowSample {
        WindowSample(id: id, pid: pid, layer: layer, frame: frame)
    }

    @Test func focusHoleIsTheFrontWindowAndWhatHangsOnIt() {
        let main = CGRect(x: 100, y: 100, width: 800, height: 600)
        let popover = CGRect(x: 600, y: 60, width: 220, height: 160)        // pokes out above the window
        let other = CGRect(x: 1000, y: 100, width: 400, height: 300)        // same app, far away
        let scene = WindowScene(windows: [
            sample(1, 9, CGRect(x: 0, y: 0, width: 1512, height: 32), layer: 24),  // menu bar
            sample(2, 7, CGRect(x: 50, y: 50, width: 200, height: 120), layer: 3), // front app's palette
            sample(3, 7, popover),
            sample(4, 7, main),
            sample(5, 7, other),
            sample(6, 8, CGRect(x: 0, y: 0, width: 500, height: 500)),
        ], frontPID: 7)
        let holes = scene.focusHoles(overlayLevel: 4)
        #expect(holes.contains(CGRect(x: 50, y: 50, width: 200, height: 120)))
        #expect(holes.contains(popover))
        #expect(holes.contains(main))
        #expect(!holes.contains(other))
        #expect(holes.count == 3)
    }

    @Test func focusHoleStopsAtAnotherAppsWindow() {
        let scene = WindowScene(windows: [
            sample(1, 7, CGRect(x: 0, y: 0, width: 400, height: 300)),
            sample(2, 8, CGRect(x: 50, y: 50, width: 400, height: 300)),
            sample(3, 7, CGRect(x: 20, y: 20, width: 400, height: 300)),
        ], frontPID: 7)
        #expect(scene.focusHoles(overlayLevel: 4) == [CGRect(x: 0, y: 0, width: 400, height: 300)])
        #expect(WindowScene(windows: scene.windows, frontPID: 99).focusHoles(overlayLevel: 4).isEmpty)
        #expect(WindowScene(windows: scene.windows, frontPID: nil).focusHoles(overlayLevel: 4).isEmpty)
    }

    @Test func privateAppsBlurOnlyTheirVisiblePart() {
        let front = CGRect(x: 300, y: 100, width: 600, height: 500)
        let messages = CGRect(x: 0, y: 200, width: 500, height: 400)
        let scene = WindowScene(windows: [
            sample(1, 1, CGRect(x: 0, y: 0, width: 1500, height: 32), layer: 24),
            sample(2, 10, front),
            sample(3, 20, messages),
            sample(4, 30, CGRect(x: 1000, y: 100, width: 300, height: 300)),
        ], frontPID: 10)
        let regions = scene.visibleRegions(overlayLevel: 4) { $0 == 20 || $0 == 10 }
        // The frontmost app is skipped even when it is private.
        #expect(regions.map(\.window.pid) == [20])
        let parts = regions[0].parts
        #expect(abs(RegionGeometry.area(parts) - (messages.area - CGRect(x: 300, y: 200, width: 200, height: 400).area)) < 0.001)
        #expect(!RegionGeometry.contains(parts, CGPoint(x: 400, y: 300)))
        #expect(RegionGeometry.contains(parts, CGPoint(x: 100, y: 300)))
        // App Lock covers the frontmost app too.
        let all = scene.visibleRegions(overlayLevel: 4, skipFrontmost: false) { $0 == 10 }
        #expect(all.map(\.window.pid) == [10])
        #expect(all[0].parts == [front])
    }

    @Test func windowsAboveTheOverlayAreIgnored() {
        let scene = WindowScene(windows: [
            sample(1, 1, CGRect(x: 0, y: 0, width: 1500, height: 900), layer: 25),  // a status-level panel
            sample(2, 20, CGRect(x: 0, y: 0, width: 500, height: 400)),
        ], frontPID: 99)
        let regions = scene.visibleRegions(overlayLevel: 4) { $0 == 20 }
        #expect(regions.first?.parts == [CGRect(x: 0, y: 0, width: 500, height: 400)])
    }
}

@Suite struct PrivacyScreenIslandTests {
    // A 14-inch MacBook Pro: 1512 × 982 points, a 32 pt notch 188 pt wide.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: 0, y: 950, width: 662, height: 32)
    let right = CGRect(x: 850, y: 950, width: 662, height: 32)

    @Test func hangsFromTheNotch() {
        let placed = IslandLayout.frame(content: CGSize(width: 404, height: 116), screen: screen, notchHeight: 32,
                                        leftOfNotch: left, rightOfNotch: right)
        #expect(placed.notch == 32)
        #expect(placed.frame.maxY == screen.maxY)
        #expect(placed.frame.height == 148)
        #expect(placed.frame.width == 404)
        #expect(placed.frame.midX == 756)
    }

    @Test func widerThanTheNotchAlways() {
        let placed = IslandLayout.frame(content: CGSize(width: 100, height: 60), screen: screen, notchHeight: 32,
                                        leftOfNotch: left, rightOfNotch: right)
        #expect(placed.frame.width == CGFloat(188 + 64))
    }

    @Test func floatsTopCenterWithoutANotch() {
        let external = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
        let placed = IslandLayout.frame(content: CGSize(width: 404, height: 116), screen: external, notchHeight: 0,
                                        leftOfNotch: nil, rightOfNotch: nil, topMargin: 14)
        #expect(placed.notch == 0)
        #expect(placed.frame.midX == external.midX)
        #expect(placed.frame.maxY == external.maxY - 14)
        // Notch insets without the side areas also float.
        let odd = IslandLayout.frame(content: CGSize(width: 404, height: 116), screen: screen, notchHeight: 32,
                                     leftOfNotch: nil, rightOfNotch: nil, topMargin: 10)
        #expect(odd.notch == 0)
        #expect(odd.frame.maxY == screen.maxY - 10)
    }

    @Test func staysOnTinyScreens() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 200)
        let placed = IslandLayout.frame(content: CGSize(width: 404, height: 116), screen: small, notchHeight: 0,
                                        leftOfNotch: nil, rightOfNotch: nil)
        #expect(placed.frame.width == 300)
        #expect(small.contains(placed.frame))
    }
}

@Suite struct PrivacyScreenModeTests {
    @Test func lockSupersedesBlurAndHidesTheOtherModes() {
        var m = PrivacyModes()
        m.apply(.setFocus(true))
        m.apply(.setPrivateApps(true))
        #expect(m.showsFocusBlur)
        #expect(!m.showsPrivateApps)   // Focus Blur already covers private apps
        m.apply(.blur)
        #expect(m.showsScreenBlur && !m.showsFocusBlur)
        m.apply(.lock)
        #expect(m.locked && !m.screenBlurred)
        #expect(!m.showsScreenBlur && !m.showsFocusBlur && !m.showsPrivateApps)
        // Blur can't start under the lock; modes are kept for afterwards.
        do { let r = m.apply(.blur); #expect(!r) }
        do { let r = m.apply(.toggleBlur); #expect(!r) }
        m.apply(.unlock)
        #expect(m.showsFocusBlur && m.focusBlur && m.privateApps)
        m.apply(.toggleFocus)
        #expect(m.showsPrivateApps)
    }

    @Test func togglesAndIdempotence() {
        var m = PrivacyModes()
        do { let r = m.apply(.toggleBlur); #expect(r) }
        #expect(m.screenBlurred)
        do { let r = m.apply(.blur); #expect(!r) }
        do { let r = m.apply(.clearBlur); #expect(r) }
        do { let r = m.apply(.clearBlur); #expect(!r) }
        do { let r = m.apply(.togglePrivateApps); #expect(r && m.privateApps) }
        do { let r = m.apply(.setPrivateApps(true)); #expect(!r) }
        do { let r = m.apply(.lock); #expect(r) }
        do { let r = m.apply(.lock); #expect(!r) }
    }

    @Test func urlActionsParse() {
        #expect(PrivacyURLAction(action: "lock") == .lock)
        #expect(PrivacyURLAction(action: "BLUR") == .blur)
        #expect(PrivacyURLAction(action: "focus") == .focus)
        #expect(PrivacyURLAction(action: "private") == .privateApps)
        #expect(PrivacyURLAction(action: "applock") == .appLock)
        #expect(PrivacyURLAction(action: "open") == .settings)
        for bad in ["unlock", "off", "clear", "toggle", "disable", "stop", "", "lock/../unlock"] {
            #expect(PrivacyURLAction(action: bad) == nil)
        }
    }

    @Test func noURLActionEverLowersProtection() {
        let actions = ["lock", "blur", "focus", "private", "privateapps", "applock", "app-lock", "open", "settings", "show",
                       "unlock", "off", "toggle", "clear", "disable"]
        for bits in 0..<16 {
            let start = PrivacyModes(locked: bits & 1 != 0, screenBlurred: bits & 2 != 0 && bits & 1 == 0,
                                     focusBlur: bits & 4 != 0, privateApps: bits & 8 != 0)
            for name in actions {
                var m = start
                if let request = PrivacyURLAction(action: name)?.request { m.apply(request) }
                #expect(!(start.locked && !m.locked), "\(name) unlocked")
                #expect(!(start.screenBlurred && !m.screenBlurred) || m.locked, "\(name) cleared the blur")
                #expect(!(start.focusBlur && !m.focusBlur), "\(name) turned Focus Blur off")
                #expect(!(start.privateApps && !m.privateApps), "\(name) turned Private Apps off")
            }
        }
    }

    @Test func urlRequestsOnlyEverEngage() {
        for action in PrivacyURLAction.allCases {
            switch action.request {
            case .lock?, .blur?, .setFocus(true)?, .setPrivateApps(true)?, nil: break
            default: Issue.record("\(action) makes a request that is not an engage: \(String(describing: action.request))")
            }
        }
    }
}

@Suite struct PrivacyScreenPresentationTests {
    @Test func lockOptionsTakeTheKeyboard() {
        let o = PresentationLease.lockOptions
        for required: NSApplication.PresentationOptions in [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                                            .disableForceQuit, .disableSessionTermination,
                                                            .disableAppleMenu, .disableHideApplication] {
            #expect(o.contains(required))
        }
        // AppKit rejects the disable options unless the Dock and menu bar are hidden, not auto-hidden.
        #expect(!o.contains(.autoHideDock) && !o.contains(.autoHideMenuBar))
    }

    @Test func restoresExactlyWhatWasThere() {
        var lease = PresentationLease()
        #expect(!lease.isEngaged)
        do { let r = lease.release(); #expect(r == nil) }
        let before: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
        do { let r = lease.engage(current: before); #expect(r == PresentationLease.lockOptions) }
        #expect(lease.isEngaged)
        // Re-engaging while locked (e.g. after re-activation) keeps the original.
        do { let r = lease.engage(current: PresentationLease.lockOptions); #expect(r == PresentationLease.lockOptions) }
        do { let r = lease.release(); #expect(r == before) }
        #expect(!lease.isEngaged)
        do { let r = lease.release(); #expect(r == nil) }
        _ = lease.engage(current: [])
        do { let r = lease.release(); #expect(r == []) }
    }
}

@Suite struct PrivacyScreenGuardTests {
    @Test func markerRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privacyguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lock-guard.json")
        #expect(GuardMarker.read(url) == nil)
        let marker = GuardMarker(pid: 4242, scope: .screen, since: Date(timeIntervalSince1970: 1_800_000_000))
        try marker.write(to: url)
        #expect(GuardMarker.read(url) == marker)
        try Data("not json".utf8).write(to: url)
        #expect(GuardMarker.read(url) == nil)
    }

    @Test func locksOnlyWhenTheMarkerNamesTheDeadApp() {
        let marker = GuardMarker(pid: 4242, scope: .apps, since: Date())
        #expect(GuardDecision.onAppExit(marker: marker, watchedPID: 4242) == .lockMac)
        #expect(GuardDecision.onAppExit(marker: nil, watchedPID: 4242) == .standDown)
        #expect(GuardDecision.onAppExit(marker: marker, watchedPID: 99) == .standDown)
    }

    @Test func argumentsRoundTrip() {
        let args = GuardArguments(pid: 812, marker: URL(fileURLWithPath: "/tmp/x/lock-guard.json"))
        #expect(GuardArguments.parse(args.arguments) == args)
        #expect(GuardArguments.parse(["--marker", "/m", "--pid", "5"]) == GuardArguments(pid: 5, marker: URL(fileURLWithPath: "/m")))
        for bad in [[], ["--pid", "5"], ["--pid", "x", "--marker", "/m"], ["--pid", "-3", "--marker", "/m"],
                    ["--pid", "5", "--marker", "relative"], ["--pid", "5", "--marker", "/m", "--extra"], ["--pid"]] {
            #expect(GuardArguments.parse(bad) == nil)
        }
    }

    @Test func badArgumentsExitWithUsage() async {
        let code = await MainActor.run { PrivacyGuard.run(["--pid"]) }
        #expect(code == 64)
    }

    @Test func guardShieldSitsBetweenAppsAndTheLock() {
        #expect(LockLevels.guardShield.rawValue < LockLevels.shield.rawValue)
        #expect(LockLevels.island.rawValue > LockLevels.shield.rawValue)
        #expect(LockLevels.guardShield.rawValue > NSWindow.Level.screenSaver.rawValue)
    }
}

@Suite struct PrivacyScreenSettingsTests {
    @Test func assignedDefaultShortcuts() {
        let s = PrivacyScreenSettings()
        #expect(s.lockShortcut?.description == "⌃⌥L")
        #expect(s.appLockShortcut?.description == "⌃⌥⌘L")
        #expect(s.blurShortcut?.description == "⌃⌥⇧B")
        #expect(s.focusShortcut?.description == "⌃⌥⇧F")
        #expect(s.privateAppsShortcut?.description == "⌃⌥⇧P")
    }

    @Test func timersAreOffByDefault() {
        let s = PrivacyScreenSettings()
        #expect(s.blurAfterIdleMinutes == 0 && s.lockAfterIdleMinutes == 0)
        #expect(s.hotCorner == .none)
        #expect(!s.privateAppsOn)
        #expect(PrivacyScreenSettings.handOffChoices.contains(s.handOffMinutes))
    }

    @Test func roundTripKeepsClearedShortcuts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privacyscreen-\(UUID().uuidString)")
        let store = SettingsStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = PrivacyScreenSettings()
        s.lockShortcut = nil
        s.lockStyle = .ambient
        s.privateApps = ["com.apple.MobileSMS"]
        s.hotCorner = .bottomLeft
        store.save(s, id: "privacyscreen", defaults: PrivacyScreenSettings())
        let loaded = store.load("privacyscreen", default: PrivacyScreenSettings())
        #expect(loaded == s)
        #expect(loaded.lockShortcut == nil)
    }

    @Test func blurStrengthGrowsMonotonically() {
        var previous = BlurRecipe.make(strength: 0)
        #expect(previous.layers == 1)
        for i in 1...20 {
            let r = BlurRecipe.make(strength: Double(i) / 20)
            #expect(r.layers >= previous.layers)
            #expect(r.wash >= previous.wash)
            previous = r
        }
        #expect(previous.layers == 3)
        #expect(BlurRecipe.make(strength: 7) == BlurRecipe.make(strength: 1))
        #expect(BlurRecipe.make(strength: -1) == BlurRecipe.make(strength: 0))
    }

    @Test func neverTitle() {
        #expect(PrivacyScreenSettings.minutesTitle(0, zero: "Never") == "Never")
        #expect(!PrivacyScreenSettings.minutesTitle(15, zero: "Never").isEmpty)
    }
}
