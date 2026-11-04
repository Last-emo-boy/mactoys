import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import WindowControls

@Suite struct WindowControlsTests {
    // A laptop (menu bar 33, no Dock), a 4K monitor to its right, and a portrait monitor beyond it.
    private let laptop = DisplayBox(key: "laptop", id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visible: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true)
    private let monitor = DisplayBox(key: "monitor", id: 2, name: "Studio", frame: CGRect(x: 1512, y: -100, width: 2560, height: 1440),
                                     visible: CGRect(x: 1512, y: -75, width: 2560, height: 1340), isMain: false)
    private let portrait = DisplayBox(key: "portrait", id: 3, name: "Pivot", frame: CGRect(x: 4072, y: -400, width: 1080, height: 1920),
                                      visible: CGRect(x: 4072, y: -400, width: 1080, height: 1920), isMain: false)
    private let spacing = Spacing(gap: 10, margin: 8)

    private var displays: [DisplayBox] { [laptop, monitor, portrait] }

    // MARK: Fractions and presets

    @Test func halvesAndThirdsKeepTheMarginAtEdgesAndOneGapBetween() {
        let v = laptop.visible
        let left = Placement.frame(for: UnitRect(x: 0, y: 0, width: 0.5, height: 1), in: v, spacing: spacing)
        let right = Placement.frame(for: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), in: v, spacing: spacing)
        #expect(left == CGRect(x: 8, y: 41, width: 743, height: 933))
        #expect(right == CGRect(x: 761, y: 41, width: 743, height: 933))
        #expect(right.minX - left.maxX == 10)
        #expect(right.maxX == v.maxX - 8)

        let third = 1.0 / 3
        let thirds = (0..<3).map { Placement.frame(for: UnitRect(x: Double($0) * third, y: 0, width: third, height: 1), in: v, spacing: spacing) }
        #expect(thirds[0].minX == 8)
        #expect(thirds[2].maxX == 1504)
        #expect(thirds[1].minX - thirds[0].maxX == 10)
        #expect(thirds[2].minX - thirds[1].maxX == 10)
        // Whole points only.
        for f in thirds { #expect(f.minX == f.minX.rounded() && f.width == f.width.rounded()) }
    }

    @Test func fillAndQuartersWithoutSpacingCoverTheVisibleFrameExactly() {
        let v = monitor.visible
        #expect(Placement.frame(for: .full, in: v, spacing: .none) == v)
        let quarters = [UnitRect(x: 0, y: 0, width: 0.5, height: 0.5), UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                        UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5), UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
            .map { Placement.frame(for: $0, in: v, spacing: .none) }
        #expect(quarters[0] == CGRect(x: 1512, y: -75, width: 1280, height: 670))
        #expect(quarters[3] == CGRect(x: 2792, y: 595, width: 1280, height: 670))
        #expect(quarters.map(\.area).reduce(0, +) == v.area)
    }

    @Test func portraitDisplaysPlaceAlongTheirOwnProportions() {
        let top = Placement.frame(for: UnitRect(x: 0, y: 0, width: 1, height: 0.5), in: portrait.visible, spacing: spacing)
        let bottom = Placement.frame(for: UnitRect(x: 0, y: 0.5, width: 1, height: 0.5), in: portrait.visible, spacing: spacing)
        #expect(top == CGRect(x: 4080, y: -392, width: 1064, height: 947))
        #expect(bottom.minY - top.maxY == 10)
        #expect(bottom.maxY == portrait.visible.maxY - 8)
    }

    @Test func builtInControlsGiveTheirPresets() {
        let controls = Dictionary(uniqueKeysWithValues: BuiltInControls.all.map { ($0.builtIn ?? "", $0) })
        let ctx = PlanContext(displays: [laptop], spacing: .none)
        let window = CGRect(x: 300, y: 200, width: 600, height: 400)
        func plan(_ id: String) -> CGRect? { controls[id].flatMap { ControlPlanner.plan($0.steps, frame: window, context: ctx) } }
        #expect(plan("fill") == laptop.visible)
        #expect(plan("left-two-thirds") == CGRect(x: 0, y: 33, width: 1008, height: 949))
        #expect(plan("bottom-right") == CGRect(x: 756, y: 508, width: 756, height: 474))
        #expect(plan("center") == CGRect(x: 456, y: 308, width: 600, height: 400))
        #expect(plan("almost-fill") == CGRect(x: 76, y: 81, width: 1361, height: 854))
        #expect(plan("size-1280") == CGRect(x: 116, y: 108, width: 1280, height: 800))
        // Every built-in control has a name, a stable id and at least one step.
        #expect(Set(BuiltInControls.all.map(\.id)).count == BuiltInControls.all.count)
        for c in BuiltInControls.all {
            #expect(!c.steps.isEmpty)
            #expect(c.displayName != String(localized: "Untitled control", comment: "Window Controls: a custom control without a name"))
        }
        // Ids are derived, not random: shortcuts and the editor keep pointing at the same control.
        #expect(BuiltInControls.all.map(\.id) == BuiltInControls.all.map(\.id))
    }

    @Test func resizeAnchorsUnitsAndInPlace() {
        let v = laptop.visible
        let frame = CGRect(x: 1000, y: 600, width: 400, height: 300)
        let corner = Placement.resized(frame, width: .points(800), height: .fraction(0.5), anchor: .bottomRight, inPlace: false,
                                       in: v, spacing: spacing)
        #expect(corner == CGRect(x: 704, y: 507, width: 800, height: 467))
        // Points larger than the screen shrink to fit; "unchanged" keeps the side.
        let wide = Placement.resized(frame, width: .points(4000), height: .unchanged, anchor: .top, inPlace: false, in: v, spacing: .none)
        #expect(wide == CGRect(x: 0, y: 33, width: 1512, height: 300))
        // In place: around the window's center, pushed back inside the work area.
        let grown = Placement.resized(frame, width: .points(700), height: .points(500), anchor: .center, inPlace: true, in: v, spacing: .none)
        #expect(grown == CGRect(x: 812, y: 482, width: 700, height: 500))
        // Moving keeps the size.
        #expect(Placement.moved(frame, to: .topLeft, in: v, spacing: spacing) == CGRect(x: 8, y: 41, width: 400, height: 300))
    }

    // MARK: Grid

    @Test func gridCellsBecomeFrames() {
        let grid = GridSpec(columns: 6, rows: 4)
        let size = CGSize(width: 272, height: 170)
        #expect(grid.cell(at: CGPoint(x: 0, y: 0), in: size) == GridCell(column: 0, row: 0))
        #expect(grid.cell(at: CGPoint(x: 271, y: 169), in: size) == GridCell(column: 5, row: 3))
        #expect(grid.cell(at: CGPoint(x: 500, y: -20), in: size) == GridCell(column: 5, row: 0))   // outside snaps inside
        #expect(grid.cell(at: CGPoint(x: 136, y: 85), in: size) == GridCell(column: 3, row: 2))

        // Dragged from the bottom-right corner up to the middle: the right half, top three quarters.
        let u = grid.unitRect(from: GridCell(column: 5, row: 2), to: GridCell(column: 3, row: 0))
        #expect(u == UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.75))
        #expect(grid.span(from: GridCell(column: 5, row: 2), to: GridCell(column: 3, row: 0)) == (3, 3))
        let frame = Placement.frame(for: u, in: laptop.visible, spacing: spacing)
        #expect(frame == CGRect(x: 761, y: 41, width: 743, height: 695))

        let one = grid.unitRect(from: GridCell(column: 0, row: 0), to: GridCell(column: 0, row: 0))
        #expect(Placement.frame(for: one, in: laptop.visible, spacing: .none) == CGRect(x: 0, y: 33, width: 252, height: 237))
    }

    @Test func gridTurnsOnPortraitDisplays() {
        #expect(GridSpec.oriented(columns: 6, rows: 4, for: portrait.visible, swapOnPortrait: true) == GridSpec(columns: 4, rows: 6))
        #expect(GridSpec.oriented(columns: 6, rows: 4, for: portrait.visible, swapOnPortrait: false) == GridSpec(columns: 6, rows: 4))
        #expect(GridSpec.oriented(columns: 6, rows: 4, for: laptop.visible, swapOnPortrait: true) == GridSpec(columns: 6, rows: 4))
        // A grid already taller than wide stays as it is.
        #expect(GridSpec.oriented(columns: 3, rows: 5, for: portrait.visible, swapOnPortrait: true) == GridSpec(columns: 3, rows: 5))
        #expect(GridSpec(columns: 0, rows: 99) == GridSpec(columns: 1, rows: 24))
        let tall = GridSpec.oriented(columns: 6, rows: 4, for: portrait.visible, swapOnPortrait: true)
        let lowerHalf = tall.unitRect(from: GridCell(column: 0, row: 3), to: GridCell(column: 3, row: 5))
        #expect(Placement.frame(for: lowerHalf, in: portrait.visible, spacing: .none) == CGRect(x: 4072, y: 560, width: 1080, height: 960))
    }

    // MARK: Displays and chains

    @Test func displayTargets() {
        #expect(DisplayNavigator.index(showing: CGRect(x: 1600, y: 100, width: 500, height: 400), in: displays) == 1)
        #expect(DisplayNavigator.index(showing: CGRect(x: 1400, y: 100, width: 600, height: 400), in: displays) == 1)
        #expect(DisplayNavigator.target(.next, from: 0, in: displays) == 1)
        #expect(DisplayNavigator.target(.next, from: 2, in: displays) == 0)
        #expect(DisplayNavigator.target(.previous, from: 0, in: displays) == 2)
        #expect(DisplayNavigator.target(.right, from: 0, in: displays) == 1)
        #expect(DisplayNavigator.target(.left, from: 1, in: displays) == 0)
        #expect(DisplayNavigator.target(.left, from: 0, in: displays) == nil)
        #expect(DisplayNavigator.target(.up, from: 0, in: displays) == nil)
        #expect(DisplayNavigator.target(.main, from: 2, in: displays) == 0)
        #expect(DisplayNavigator.target(.main, from: 0, in: displays) == nil)
        #expect(DisplayNavigator.target(.next, from: 0, in: [laptop]) == nil)
        // A display stacked above the laptop.
        let above = DisplayBox(key: "above", id: 4, name: "Above", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                               visible: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isMain: false)
        #expect(DisplayNavigator.target(.up, from: 0, in: [laptop, monitor, above]) == 2)
        #expect(DisplayNavigator.target(.down, from: 2, in: [laptop, monitor, above]) == 0)
    }

    @Test func moveToDisplayKeepsHalvesAndFloatingSizes() {
        let half = Placement.frame(for: UnitRect(x: 0, y: 0, width: 0.5, height: 1), in: laptop.visible, spacing: .none)
        #expect(Placement.transfer(half, from: laptop, to: monitor, spacing: .none) == CGRect(x: 1512, y: -75, width: 1280, height: 1340))
        let floating = CGRect(x: 456, y: 290, width: 600, height: 400)   // centered, touching nothing
        let moved = Placement.transfer(floating, from: laptop, to: monitor, spacing: .none)
        #expect(moved.size == floating.size)
        #expect(abs(moved.midX - monitor.visible.midX) <= 1)
        // Too big for the target: shrunk to fit.
        let big = CGRect(x: 200, y: 100, width: 1100, height: 800)
        let onPortrait = Placement.transfer(big, from: laptop, to: portrait, spacing: .none)
        #expect(onPortrait.width == 1080)
        #expect(portrait.visible.contains(onPortrait))
    }

    @Test func chainsRunTogetherAndCycle() {
        let window = CGRect(x: 300, y: 200, width: 600, height: 400)
        let ctx = PlanContext(displays: displays, spacing: .none)
        // Next display, then its left half.
        let chain: [ControlStep] = [.display(.next), .place(UnitRect(x: 0, y: 0, width: 0.5, height: 1))]
        #expect(ControlPlanner.plan(chain, frame: window, context: ctx) == CGRect(x: 1512, y: -75, width: 1280, height: 1340))
        // A step that can't apply is skipped; nothing applicable gives nil.
        #expect(ControlPlanner.plan([.display(.left)], frame: window, context: ctx) == nil)
        #expect(ControlPlanner.plan([.display(.left), .move(.topLeft)], frame: window, context: ctx) == CGRect(x: 0, y: 33, width: 600, height: 400))

        // Cycling: the next step while the window is where the last one left it, else the first.
        let at = CGRect(x: 0, y: 33, width: 756, height: 949)
        #expect(ControlPlanner.nextCycleIndex(count: 3, last: nil, lastFrame: nil, current: at) == 0)
        #expect(ControlPlanner.nextCycleIndex(count: 3, last: 0, lastFrame: at, current: at) == 1)
        #expect(ControlPlanner.nextCycleIndex(count: 3, last: 2, lastFrame: at, current: at.offsetBy(dx: 2, dy: 0)) == 0)
        #expect(ControlPlanner.nextCycleIndex(count: 3, last: 1, lastFrame: at, current: at.offsetBy(dx: 40, dy: 0)) == 0)
    }

    @Test func fixedSizeWindowsAreCenteredWhereTheStepPutsThem() {
        let window = CGRect(x: 300, y: 200, width: 500, height: 300)
        var ctx = PlanContext(displays: [laptop], spacing: .none)
        ctx.resizable = false
        let r = ControlPlanner.plan([.place(UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))], frame: window, context: ctx)
        #expect(r == CGRect(x: 884, y: 358, width: 500, height: 300))
    }

    @Test func appsKeepingTheirOwnSizeStayAgainstTheSameEdges() {
        let area = laptop.visible
        let target = CGRect(x: 756, y: 33, width: 756, height: 949)                  // right half
        let r = Placement.realigned(actual: CGSize(width: 900, height: 949), target: target, area: area)
        #expect(r == CGRect(x: 612, y: 33, width: 900, height: 949))
        let center = Placement.realigned(actual: CGSize(width: 400, height: 300), target: CGRect(x: 400, y: 200, width: 600, height: 500), area: area)
        #expect(center == CGRect(x: 500, y: 300, width: 400, height: 300))
    }

    // MARK: Keyboard mode

    @Test func arrowsGiveHalvesAndQuarters() {
        #expect(KeyboardGeometry.half(.left, after: nil) == UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(KeyboardGeometry.half(.down, after: nil) == UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))
        #expect(KeyboardGeometry.half(.up, after: .left) == UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(KeyboardGeometry.half(.right, after: .down) == UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(KeyboardGeometry.half(.right, after: .left) == UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    @Test func arrowAtAHalfHopsToTheNextDisplay() {
        let all = [laptop, monitor]
        let leftHalf = Placement.frame(for: UnitRect(x: 0, y: 0, width: 0.5, height: 1), in: laptop.visible, spacing: spacing)
        let rightHalf = Placement.frame(for: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), in: laptop.visible, spacing: spacing)
        let window = CGRect(x: 200, y: 200, width: 500, height: 400)
        #expect(KeyboardGeometry.halfTarget(.right, previous: nil, frame: window, displays: all, spacing: spacing) == rightHalf)
        // Already the right half: on to the monitor's left half.
        let hop = KeyboardGeometry.halfTarget(.right, previous: nil, frame: rightHalf, displays: all, spacing: spacing)
        #expect(hop == Placement.frame(for: UnitRect(x: 0, y: 0, width: 0.5, height: 1), in: monitor.visible, spacing: spacing))
        // Nothing to the left of the laptop: stays the left half.
        #expect(KeyboardGeometry.halfTarget(.left, previous: nil, frame: leftHalf, displays: all, spacing: spacing) == leftHalf)
    }

    @Test func shiftArrowsGrowAndShrinkAgainstTheRightEdges() {
        let area = laptop.visible
        let floating = CGRect(x: 300, y: 200, width: 600, height: 400)
        #expect(KeyboardGeometry.resized(floating, arrow: .right, step: 50, area: area) == CGRect(x: 300, y: 200, width: 650, height: 400))
        #expect(KeyboardGeometry.resized(floating, arrow: .left, step: 50, area: area) == CGRect(x: 300, y: 200, width: 550, height: 400))
        #expect(KeyboardGeometry.resized(floating, arrow: .down, step: 50, area: area) == CGRect(x: 300, y: 200, width: 600, height: 450))
        #expect(KeyboardGeometry.resized(floating, arrow: .up, step: 50, area: area) == CGRect(x: 300, y: 200, width: 600, height: 350))
        // A right half stays against the right edge.
        let right = CGRect(x: 756, y: 33, width: 756, height: 949)
        #expect(KeyboardGeometry.resized(right, arrow: .left, step: 56, area: area) == CGRect(x: 812, y: 33, width: 700, height: 949))
        #expect(KeyboardGeometry.resized(right, arrow: .right, step: 56, area: area) == CGRect(x: 700, y: 33, width: 812, height: 949))
        // Full width shrinks around its center; it can't grow past the screen.
        let full = area
        #expect(KeyboardGeometry.resized(full, arrow: .left, step: 100, area: area) == CGRect(x: 50, y: 33, width: 1412, height: 949))
        #expect(KeyboardGeometry.resized(full, arrow: .right, step: 100, area: area) == full)
        // Not below the minimum size.
        let small = CGRect(x: 100, y: 100, width: 220, height: 130)
        #expect(KeyboardGeometry.resized(small, arrow: .left, step: 100, area: area).width == 200)
        #expect(KeyboardGeometry.resized(small, arrow: .up, step: 100, area: area).height == 120)
    }

    @Test func optionArrowsNudgeInsideTheScreen() {
        let area = laptop.visible
        let w = CGRect(x: 10, y: 100, width: 600, height: 400)
        #expect(KeyboardGeometry.nudged(w, arrow: .right, step: 20, area: area) == CGRect(x: 30, y: 100, width: 600, height: 400))
        #expect(KeyboardGeometry.nudged(w, arrow: .left, step: 20, area: area) == CGRect(x: 0, y: 100, width: 600, height: 400))
        #expect(KeyboardGeometry.nudged(w, arrow: .up, step: 1, area: area) == CGRect(x: 10, y: 99, width: 600, height: 400))
        #expect(KeyboardGeometry.nudged(CGRect(x: 10, y: 40, width: 600, height: 400), arrow: .up, step: 20, area: area).minY == 33)
    }

    @MainActor @Test func keysMapToActions() {
        #expect(KeyboardMode.action(keyCode: kVK_LeftArrow, modifiers: []) == .half(.left))
        #expect(KeyboardMode.action(keyCode: kVK_UpArrow, modifiers: [.shift]) == .resize(.up))
        #expect(KeyboardMode.action(keyCode: kVK_DownArrow, modifiers: [.option]) == .nudge(.down, fine: false))
        #expect(KeyboardMode.action(keyCode: kVK_RightArrow, modifiers: [.option, .shift]) == .nudge(.right, fine: true))
        #expect(KeyboardMode.action(keyCode: kVK_Space, modifiers: []) == .center)
        #expect(KeyboardMode.action(keyCode: kVK_Return, modifiers: []) == .fill)
        #expect(KeyboardMode.action(keyCode: kVK_ANSI_KeypadEnter, modifiers: []) == .fill)
        #expect(KeyboardMode.action(keyCode: kVK_Tab, modifiers: []) == .cycle(forward: true))
        #expect(KeyboardMode.action(keyCode: kVK_Tab, modifiers: [.shift]) == .cycle(forward: false))
        #expect(KeyboardMode.action(keyCode: kVK_Escape, modifiers: []) == .leave)
        #expect(KeyboardMode.action(keyCode: kVK_ANSI_3, modifiers: []) == .control(3))
        #expect(KeyboardMode.action(keyCode: kVK_ANSI_Keypad9, modifiers: []) == .control(9))
        #expect(KeyboardMode.action(keyCode: kVK_ANSI_D, modifiers: []) == .nextDisplay)
        #expect(KeyboardMode.action(keyCode: kVK_ANSI_Q, modifiers: []) == nil)
        #expect(KeyboardMode.Action.nudge(.left, fine: false).repeats)
        #expect(!KeyboardMode.Action.half(.left).repeats)
    }

    // MARK: Saved layouts

    private func layoutDisplay(_ d: DisplayBox) -> LayoutDisplay {
        LayoutDisplay(key: d.key, name: d.name, frame: d.frame, visible: d.visible, isMain: d.isMain)
    }

    @Test func arrangementKeysIgnoreOrderAndNoticeChanges() {
        let a = layoutDisplay(laptop), b = layoutDisplay(monitor)
        #expect(DisplayArrangement.key([a, b]) == DisplayArrangement.key([b, a]))
        #expect(DisplayArrangement.key([a, b]) == "laptop@0,0,1512x982|monitor@1512,-100,2560x1440")
        var moved = b
        moved.frame.origin.x = -2560
        #expect(DisplayArrangement.key([a, moved]) != DisplayArrangement.key([a, b]))
        var scaled = b
        scaled.frame.size = CGSize(width: 1920, height: 1080)
        #expect(DisplayArrangement.key([a, scaled]) != DisplayArrangement.key([a, b]))
        #expect(DisplayArrangement.key([a]) != DisplayArrangement.key([a, b]))
        // Twin monitors without serial numbers stay apart.
        #expect(DisplayArrangement.keys(stableIDs: ["610-1-0", "4268-7-0", "4268-7-0"], displayIDs: [1, 5, 6])
                == ["610-1-0", "4268-7-0-5", "4268-7-0-6"])
    }

    @Test func assembleNumbersEachAppsWindowsFrontToBack() {
        let found = [
            SavedLayout.Found(bundleID: "com.apple.Safari", appName: "Safari", title: "Docs", frame: CGRect(x: 1600, y: 0, width: 900, height: 700)),
            SavedLayout.Found(bundleID: "com.apple.Notes", appName: "Notes", title: "", frame: CGRect(x: 0, y: 33, width: 700, height: 900)),
            SavedLayout.Found(bundleID: "com.apple.Safari", appName: "Safari", title: "News", frame: CGRect(x: 20, y: 40, width: 800, height: 600)),
        ]
        let layout = SavedLayout.assemble(name: "Desk", windows: found, displays: [layoutDisplay(laptop), layoutDisplay(monitor)])
        #expect(layout.windows.map(\.index) == [0, 0, 1])
        #expect(layout.windows.map(\.displayKey) == ["monitor", "laptop", "laptop"])
        #expect(layout.appCount == 2)
        #expect(layout.arrangementKey == DisplayArrangement.key([layoutDisplay(monitor), layoutDisplay(laptop)]))
    }

    @Test func matchingPrefersTitlesThenPositionsAndSkipsMissingApps() {
        func saved(_ bundle: String, _ index: Int, _ title: String) -> SavedWindow {
            SavedWindow(bundleID: bundle, appName: bundle, index: index, title: title, frame: .zero, displayKey: "laptop")
        }
        let layout = [saved("safari", 0, "Docs"), saved("safari", 1, "News"), saved("notes", 0, ""), saved("mail", 0, "Inbox"),
                      saved("safari", 2, "Shop")]
        let live = [LiveWindow(bundleID: "safari", index: 0, title: "News"),
                    LiveWindow(bundleID: "notes", index: 0, title: "Groceries"),
                    LiveWindow(bundleID: "safari", index: 1, title: "Weather"),
                    LiveWindow(bundleID: "safari", index: 2, title: "Docs")]
        let m = LayoutMatcher.match(saved: layout, live: live)
        #expect(m[0] == 3)       // title "Docs"
        #expect(m[1] == 0)       // title "News"
        #expect(m[2] == 1)       // untitled: same position
        #expect(m[3] == nil)     // Mail isn't running
        #expect(m[4] == 2)       // left over
        // Each live window is used once.
        let used = m.compactMap { $0 }
        #expect(Set(used).count == used.count)
        // More saved windows than open ones: the extra ones are skipped.
        let fewer = LayoutMatcher.match(saved: [saved("notes", 0, ""), saved("notes", 1, "")],
                                        live: [LiveWindow(bundleID: "notes", index: 0, title: "")])
        #expect(fewer == [0, nil])
    }

    @Test func restoredFramesFollowTheirDisplays() {
        let a = layoutDisplay(laptop), b = layoutDisplay(monitor)
        let w = SavedWindow(bundleID: "x", appName: "X", index: 0, title: "", frame: CGRect(x: 1600, y: -60, width: 1280, height: 700),
                            displayKey: "monitor")
        let layout = SavedLayout(name: "Desk", displays: [a, b], windows: [w])
        // Same arrangement: exactly where it was.
        #expect(LayoutPlanner.target(for: w, in: layout, displays: [laptop, monitor]) == w.frame)
        // The monitor now sits on the left: moved along.
        var left = monitor
        left.frame.origin.x = -2560
        left.visible.origin.x = -2560
        #expect(LayoutPlanner.target(for: w, in: layout, displays: [laptop, left]) == CGRect(x: -2472, y: -60, width: 1280, height: 700))
        // The monitor is gone: scaled onto the main display.
        let onLaptop = LayoutPlanner.target(for: w, in: layout, displays: [laptop])
        #expect(onLaptop.map { laptop.visible.contains($0) } == true)
        #expect(onLaptop?.width == 756)
        #expect(LayoutPlanner.target(for: w, in: layout, displays: []) == nil)
    }

    // MARK: Settings

    @Test func settingsRoundTripThroughTheStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = WindowControlsSettings()
        s.keyboardShortcut = nil
        s.gridColumns = 8
        s.controls[1].shortcut = Shortcut(kVK_LeftArrow, [.control, .option, .command])
        s.controls.append(WindowControl(name: "Mine", steps: [.display(.main), .resize(.points(900), .fraction(1), inPlace: true)],
                                        chainMode: .cycle, inKeyboard: true))
        s.layouts = [SavedLayout(name: "Desk", displays: [layoutDisplay(laptop)], windows: [
            SavedWindow(bundleID: "com.apple.Notes", appName: "Notes", index: 0, title: "List", frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                        displayKey: "laptop")], created: Date(timeIntervalSince1970: 1_800_000_000), autoRestore: true)]
        store.save(s, id: "windowcontrols", defaults: WindowControlsSettings())
        let loaded = store.load("windowcontrols", default: WindowControlsSettings())
        #expect(loaded == s)
        #expect(loaded.keyboardShortcut == nil)   // a cleared shortcut stays cleared
        #expect(WindowControlsSettings().keyboardShortcut == Shortcut(kVK_ANSI_K, [.control, .option]))
    }

    @Test func olderFilesWithMissingKeysStillLoad() throws {
        let json = """
        {"name": "Old", "steps": [{"kind": "resize", "width": {"unit": "points", "value": 1024}}]}
        """
        let c = try JSONDecoder().decode(WindowControl.self, from: Data(json.utf8))
        #expect(c.name == "Old")
        #expect(c.inPalette)
        #expect(!c.inKeyboard)
        #expect(c.chainMode == .all)
        #expect(c.steps.first?.width == .points(1024))
        #expect(c.steps.first?.height == .fraction(0.7))
        #expect(c.steps.first?.anchor == .center)
        let layout = try JSONDecoder().decode(SavedLayout.self, from: Data(#"{"name": "L"}"#.utf8))
        #expect(layout.windows.isEmpty && !layout.autoRestore)
    }

    @Test func lookupsAndRestoringBuiltIns() {
        var s = WindowControlsSettings()
        #expect(s.control(named: "left-half")?.builtIn == "left-half")
        #expect(s.control(named: BuiltInControls.title("right-third") ?? "")?.builtIn == "right-third")
        #expect(s.keyboardControls.count <= 9)
        #expect(s.keyboardControls.allSatisfy { $0.inKeyboard })

        let mine = WindowControl(name: "Mine", steps: [.move(.topLeft)])
        let shortcut = Shortcut(kVK_ANSI_L, [.control, .option, .command])
        s.controls.removeAll { $0.builtIn == "fill" }
        s.controls[0].shortcut = shortcut
        s.controls[0].inPalette = false
        s.controls.append(mine)
        let restored = BuiltInControls.restored(in: s.controls)
        #expect(restored.prefix(BuiltInControls.all.count).map(\.id) == BuiltInControls.all.map(\.id))
        #expect(restored.last == mine)
        #expect(restored.first { $0.id == s.controls[0].id }?.shortcut == shortcut)   // keeps the user's shortcut
        #expect(restored.first { $0.id == s.controls[0].id }?.inPalette == true)      // other options reset

        let old = SavedLayout(name: "Desk", displays: [layoutDisplay(laptop)], windows: [], created: Date(timeIntervalSince1970: 0),
                              autoRestore: true)
        let new = SavedLayout(name: "desk 2", displays: [layoutDisplay(laptop)], windows: [], created: Date(timeIntervalSince1970: 100))
        s.layouts = [old, new]
        #expect(s.layout(named: "DESK")?.id == old.id)
        #expect(s.newestLayout(for: old.arrangementKey)?.id == new.id)
        #expect(s.newestLayout(for: old.arrangementKey, autoRestoreOnly: true)?.id == old.id)
        #expect(s.newestLayout(for: "elsewhere") == nil)
    }
}
