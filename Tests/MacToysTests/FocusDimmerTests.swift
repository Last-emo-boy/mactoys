import CoreGraphics
import Foundation
import Testing
@testable import FocusDimmer
@testable import MacToysCore

private let screen = DimDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
private let side = DimDisplay(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

private func window(_ id: CGWindowID, _ pid: pid_t, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> DimWindow {
    DimWindow(id: id, pid: pid, frame: CGRect(x: x, y: y, width: w, height: h))
}

private func area(_ rects: [CGRect]) -> CGFloat { rects.reduce(0) { $0 + $1.width * $1.height } }

private func disjoint(_ rects: [CGRect]) -> Bool {
    for i in rects.indices {
        for j in rects.indices where j > i {
            let hit = rects[i].intersection(rects[j])
            if !hit.isNull, hit.width > 0, hit.height > 0 { return false }
        }
    }
    return true
}

@Suite struct FocusDimmerRegionTests {
    @Test func subtractingAnOverlapLeavesDisjointBands() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(DimPlanner.subtract(r, CGRect(x: 200, y: 0, width: 10, height: 10)) == [r])
        #expect(DimPlanner.subtract(r, CGRect(x: -10, y: -10, width: 200, height: 200)).isEmpty)
        let ring = DimPlanner.subtract(r, CGRect(x: 30, y: 40, width: 20, height: 10))
        #expect(ring.count == 4)
        #expect(area(ring) == CGFloat(100 * 100 - 20 * 10))
        #expect(disjoint(ring))
        // A cut across the right edge leaves the top band, bottom band and the left slice.
        let notch = DimPlanner.subtract(r, CGRect(x: 60, y: 20, width: 100, height: 30))
        #expect(notch == [CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 50, width: 100, height: 50),
                          CGRect(x: 0, y: 20, width: 60, height: 30)])
    }

    @Test func holesSkipDimmedWindowsLyingAbove() {
        // Below the overlay: a dimmed window over the left part of a bright one.
        let stack = [window(2, 20, 0, 0, 300, 300), window(3, 10, 200, 100, 400, 300)]
        let holes = DimPlanner.holes(bright: [3], stack: stack, clip: screen.frame)
        #expect(area(holes.map(\.rect)) == CGFloat(400 * 300 - 100 * 200))
        #expect(!holes.contains { $0.rect.intersects(CGRect(x: 200, y: 100, width: 100, height: 200)) })
        #expect(disjoint(holes.map(\.rect)))
    }

    @Test func overlappingBrightWindowsGiveDisjointHoles() {
        let stack = [window(1, 10, 0, 0, 400, 300), window(2, 10, 200, 100, 400, 300)]
        let holes = DimPlanner.holes(bright: [1, 2], stack: stack, clip: screen.frame)
        #expect(disjoint(holes.map(\.rect)))
        #expect(area(holes.map(\.rect)) == CGFloat(400 * 300 * 2 - 200 * 200))
    }

    @Test func holesAreClippedToTheDisplay() {
        let stack = [window(1, 10, 1300, 800, 400, 300)]
        let holes = DimPlanner.holes(bright: [1], stack: stack, clip: screen.frame)
        #expect(holes.map(\.rect) == [CGRect(x: 1300, y: 800, width: 140, height: 100)])
    }

    @Test func holePiecesRoundOnlyTheWindowsOwnCorners() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(DimHole(rect: frame, window: frame).corners == .all)
        // The top band of a window whose middle is covered keeps its two top corners.
        let top = DimHole(rect: CGRect(x: 0, y: 0, width: 400, height: 50), window: frame)
        #expect(top.corners == [.topLeft, .topRight])
        let middle = DimHole(rect: CGRect(x: 0, y: 50, width: 100, height: 100), window: frame)
        #expect(middle.corners.isEmpty)
    }
}

@Suite struct FocusDimmerPlanTests {
    private let options = DimOptions()

    private func plan(_ decision: DimDecision) -> DimPlan? {
        if case .dim(let p) = decision { return p }
        return nil
    }

    @Test func overlaySitsBelowTheActiveWindow() {
        let windows = [window(1, 10, 100, 100, 600, 400), window(2, 20, 300, 200, 600, 400), window(3, 30, 50, 50, 300, 300)]
        let p = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10), displays: [screen], options: options))
        #expect(p?.placement == .below(1))
        #expect(p?.bright == [1])
        #expect(p?.holes[1] == [])
    }

    @Test func appModeKeepsTheAppsOtherWindowsBrightThroughHoles() {
        // Front to back: the active window, another app's window, then the app's second window.
        let windows = [window(1, 10, 0, 0, 500, 400), window(2, 20, 400, 300, 400, 300), window(3, 10, 600, 100, 500, 400)]
        let o = DimOptions(highlight: .frontApp)
        let p = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10), displays: [screen], options: o))
        #expect(p?.placement == .below(1))
        #expect(Set(p?.bright ?? []) == [1, 3])
        let holes = p?.holes[1]?.map(\.rect) ?? []
        // Window 3 minus the 200 × 200 corner under window 2, which stays dimmed.
        #expect(area(holes) == CGFloat(500 * 400 - 200 * 200))
        #expect(!holes.contains { $0.intersects(CGRect(x: 600, y: 300, width: 200, height: 200)) })
        // Front-window mode leaves window 3 dimmed.
        let single = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10), displays: [screen], options: options))
        #expect(single?.holes[1] == [])
    }

    @Test func accessibilityFocusWins() {
        let windows = [window(1, 10, 0, 0, 500, 400), window(2, 10, 400, 300, 400, 300), window(3, 20, 600, 100, 500, 400)]
        let p = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10, focus: .window(2)),
                                       displays: [screen], options: options))
        #expect(p?.placement == .below(2))
    }

    @Test func withoutAccessibilityASheetKeepsItsWindowBright() {
        // The app's topmost window lies inside the one right below it: a sheet on its document.
        let windows = [window(9, 10, 200, 80, 300, 200), window(1, 10, 100, 50, 600, 500), window(2, 20, 500, 300, 600, 400)]
        let p = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10, focus: .unknown),
                                       displays: [screen], options: options))
        #expect(p?.placement == .below(1))
        // With Accessibility the focused window is known, so no guessing.
        let known = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 10, focus: .window(1)),
                                           displays: [screen], options: options))
        #expect(known?.placement == .below(1))
    }

    @Test func clickingTheDesktopRevealsEverything() {
        let windows = [window(1, 10, 0, 0, 500, 400), window(2, 77, 400, 300, 400, 300)]
        // Finder active with its window still behind another app's: the desktop was clicked.
        let finder = DimFrontApp(pid: 77, isFinder: true)
        #expect(DimPlanner.decide(windows: windows, front: finder, displays: [screen], options: options) == .reveal)
        var focusNone = finder
        focusNone.focus = .none
        #expect(DimPlanner.decide(windows: windows, front: focusNone, displays: [screen], options: options) == .reveal)
        #expect(DimPlanner.decide(windows: [windows[0]], front: finder, displays: [screen], options: options) == .reveal)
        // A Finder window in front is an ordinary active window.
        let raised = [windows[1], windows[0]]
        #expect(plan(DimPlanner.decide(windows: raised, front: finder, displays: [screen], options: options))?.placement == .below(2))
    }

    @Test func anAppWithoutWindowsDimsEverythingButAPanelAppChangesNothing() {
        let windows = [window(1, 10, 0, 0, 500, 400), window(2, 20, 400, 300, 400, 300)]
        let p = plan(DimPlanner.decide(windows: windows, front: DimFrontApp(pid: 30), displays: [screen], options: options))
        #expect(p?.placement == .front)
        #expect(p?.holes[1] == [])
        let agent = DimFrontApp(pid: 30, isRegular: false)
        #expect(DimPlanner.decide(windows: windows, front: agent, displays: [screen], options: options) == .keep)
        #expect(DimPlanner.decide(windows: windows, front: nil, displays: [screen], options: options) == .keep)
    }

    @Test func excludedAppsAreNeverDimmedAround() {
        let windows = [window(1, 10, 0, 0, 500, 400), window(2, 20, 400, 300, 400, 300)]
        let front = DimFrontApp(pid: 10, isExcluded: true)
        #expect(DimPlanner.decide(windows: windows, front: front, displays: [screen], options: options) == .reveal)
    }

    @Test func aLoneWindowLeavesTheDesktopAlone() {
        let lone = [window(1, 10, 100, 100, 500, 400)]
        #expect(DimPlanner.decide(windows: lone, front: DimFrontApp(pid: 10), displays: [screen], options: options) == .reveal)
        let always = DimOptions(onlyWithOtherWindows: false)
        #expect(plan(DimPlanner.decide(windows: lone, front: DimFrontApp(pid: 10), displays: [screen], options: always)) != nil)
        // A window hidden entirely behind the active one doesn't count as visible.
        let covered = [window(1, 10, 0, 0, 800, 600), window(2, 20, 100, 100, 300, 200)]
        #expect(DimPlanner.decide(windows: covered, front: DimFrontApp(pid: 10), displays: [screen], options: options) == .reveal)
        // In app mode the app's own second window is not something to dim either.
        let sameApp = [window(1, 10, 0, 0, 400, 300), window(2, 10, 500, 400, 400, 300)]
        #expect(DimPlanner.decide(windows: sameApp, front: DimFrontApp(pid: 10), displays: [screen],
                                  options: DimOptions(highlight: .frontApp)) == .reveal)
    }

    @Test func otherDisplaysFollowTheSetting() {
        let windows = [window(1, 10, 100, 100, 600, 400), window(2, 20, 1600, 100, 800, 600),
                       window(3, 30, 1700, 300, 800, 600), window(4, 40, 300, 300, 600, 400)]
        let front = DimFrontApp(pid: 10)
        let dimmed = plan(DimPlanner.decide(windows: windows, front: front, displays: [screen, side],
                                            options: DimOptions(otherDisplays: .dim)))
        #expect(dimmed?.holes[1] == [] && dimmed?.holes[2] == [])
        let left = plan(DimPlanner.decide(windows: windows, front: front, displays: [screen, side],
                                          options: DimOptions(otherDisplays: .leave)))
        #expect(left?.holes[1] == [] && left?.holes[2] == nil)
        let each = plan(DimPlanner.decide(windows: windows, front: front, displays: [screen, side],
                                          options: DimOptions(otherDisplays: .highlightFront)))
        #expect(each?.holes[1] == [])
        #expect(each?.holes[2]?.map(\.rect) == [CGRect(x: 1600, y: 100, width: 800, height: 600)])
        #expect(each?.bright == [1, 2])
    }
}

@Suite struct FocusDimmerIntensityTests {
    @Test func endpointsAndClamping() {
        #expect(DimIntensity.alpha(0) == 0)
        #expect(abs(DimIntensity.alpha(1) - DimIntensity.maxAlpha) < 1e-9)
        #expect(DimIntensity.alpha(-1) == 0)
        #expect(abs(DimIntensity.alpha(3) - DimIntensity.maxAlpha) < 1e-9)
    }

    @Test func stepsAreEvenInPerceivedLightness() {
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { DimIntensity.lightness(1 - DimIntensity.alpha($0)) }
        let deltas = zip(steps, steps.dropFirst()).map { $0 - $1 }
        #expect(deltas.allSatisfy { $0 > 0 })
        #expect((deltas.max() ?? 0) - (deltas.min() ?? 0) < 1e-6)
        // Opacity still climbs monotonically, front-loaded so low settings are already visible.
        let alphas = stride(from: 0.0, through: 1.0, by: 0.05).map(DimIntensity.alpha)
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 < $1 })
        #expect(DimIntensity.alpha(0.5) > DimIntensity.maxAlpha / 2)
    }

    @Test func lightnessAndLuminanceAreInverse() {
        for y in [0.001, 0.008, 0.05, 0.18, 0.5, 1.0] {
            #expect(abs(DimIntensity.luminance(DimIntensity.lightness(y)) - y) < 1e-9)
        }
        #expect(abs(DimIntensity.lightness(0.18) - 49.5) < 0.1)
    }
}

@Suite struct FocusDimmerSettingsTests {
    @Test func defaults() {
        let s = FocusDimmerSettings()
        #expect(s.toggle?.modifiers == [.control, .option, .shift])
        #expect(s.toggle?.keyCode == 0x04)   // kVK_ANSI_H
        #expect(s.intensity(dark: false) == 40 && s.intensity(dark: true) == 55)
        #expect(s.effectiveFade == 0.3)
        var off = s
        off.animate = false
        #expect(off.effectiveFade == 0)
    }

    @Test func settingsRoundTrip() throws {
        var s = FocusDimmerSettings()
        s.highlight = .frontApp
        s.otherDisplays = .highlightFront
        s.color = RGBA(hex: "#1B2A4A")!
        s.toggle = nil
        s.excludedApps = ["Keynote"]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(FocusDimmerSettings.self, from: data) == s)
    }

    @Test func overlayOrderingIsReadFromTheWindowList() {
        var snapshot = WindowSnapshot(overlays: [90, 91])
        snapshot.order = [5, 90, 91, 6, 7]
        snapshot.windows = [window(5, 1, 0, 0, 100, 100), window(6, 2, 0, 0, 100, 100), window(7, 3, 0, 0, 100, 100)]
        #expect(snapshot.isDirectlyBelow(90, 5))
        #expect(snapshot.isDirectlyBelow(91, 5))
        #expect(!snapshot.isDirectlyBelow(90, 6))
        #expect(!snapshot.isAboveAllWindows(90))
        snapshot.order = [90, 5, 6]
        #expect(snapshot.isAboveAllWindows(90))
        #expect(snapshot.windows(above: .below(6)) == [5, 6])
        #expect(snapshot.windows(above: .front).isEmpty)
    }
}
