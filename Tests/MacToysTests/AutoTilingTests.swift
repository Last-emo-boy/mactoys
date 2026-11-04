import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import AutoTiling
@testable import MacToysCore

/// Checks the invariants every layout must keep: frames inside the area, on whole points,
/// never overlapping, exactly `gap` apart, and together with the gaps covering the whole area.
private func layoutIssues(_ frames: [CGRect], area: CGRect, gap: CGFloat) -> [String] {
    var issues: [String] = []
    for (i, f) in frames.enumerated() {
        if f.width <= 0 || f.height <= 0 { issues.append("tile \(i) is empty: \(f)") }
        if !area.contains(f) { issues.append("tile \(i) \(f) leaves the area \(area)") }
        for v in [f.minX, f.minY, f.width, f.height] where v != v.rounded() {
            issues.append("tile \(i) \(f) is not on whole points")
        }
    }
    // Grown by half a gap, the tiles must cover the grown area exactly, without overlapping.
    let half = gap / 2
    let grown = frames.map { $0.insetBy(dx: -half, dy: -half) }
    for i in grown.indices {
        for j in grown.indices where j > i {
            let overlap = grown[i].intersection(grown[j])
            if !overlap.isNull && overlap.width > 0.001 && overlap.height > 0.001 {
                issues.append("tiles \(i) and \(j) are closer than the gap: \(frames[i]) \(frames[j])")
            }
        }
    }
    let covered = grown.reduce(0) { $0 + $1.width * $1.height }
    let target = area.insetBy(dx: -half, dy: -half)
    if abs(covered - target.width * target.height) > 0.5 {
        issues.append("tiles and gaps cover \(covered), the area is \(target.width * target.height)")
    }
    return issues
}

@Suite struct AutoTilingGeometryTests {
    static let landscape = CGRect(x: 0, y: 25, width: 1440, height: 875)       // 16:10 below the menu bar
    static let ultrawide = CGRect(x: 0, y: 25, width: 3440, height: 1415)      // 21:9
    static let superUltrawide = CGRect(x: 0, y: 25, width: 5120, height: 1415) // 32:9
    static let portrait = CGRect(x: 1440, y: -300, width: 1440, height: 2560)

    @Test func everyLayoutKeepsItsInvariants() {
        let displays: [(CGRect, DisplayShape)] = [(Self.landscape, .landscape), (Self.ultrawide, .ultrawide),
                                                  (Self.superUltrawide, .ultrawide), (Self.portrait, .portrait)]
        let reserves = [EdgeReserve(), EdgeReserve(top: 0, bottom: 44, left: 0, right: 0), EdgeReserve(top: 30, bottom: 0, left: 72, right: 17)]
        var checked = 0
        for (visible, shape) in displays {
            for reserve in reserves {
                for gap in [0, 1, 8, 13, 24] as [CGFloat] {
                    let area = TileGeometry.area(visibleFrame: visible, reserve: reserve, gap: gap)
                    for kind in TileLayoutKind.allCases {
                        for main in MainSize.allCases {
                            for count in 1...5 {
                                guard let tree = TileTree.make(kind, count: count, shape: shape, main: main.fraction) else {
                                    Issue.record("no tree for \(kind) × \(count)")
                                    continue
                                }
                                #expect(tree.count == count)
                                #expect(Set(tree.tiles) == Set(0..<count))
                                let frames = TileGeometry.frames(tree, in: area, gap: gap)
                                #expect(frames.count == count)
                                let issues = layoutIssues(frames, area: area, gap: gap)
                                #expect(issues.isEmpty, "\(kind) × \(count) on \(shape), main \(main), gap \(gap): \(issues)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 4 * 3 * 5 * 4 * 3 * 5)
    }

    @Test func areaKeepsGapsReserveAndWholePoints() {
        let a = TileGeometry.area(visibleFrame: CGRect(x: 0, y: 24.5, width: 1512, height: 920.5), reserve: nil, gap: 8)
        #expect(a == CGRect(x: 8, y: 33, width: 1496, height: 904))
        let r = TileGeometry.area(visibleFrame: Self.landscape, reserve: EdgeReserve(top: 0, bottom: 60, left: 40, right: 0), gap: 8)
        #expect(r == CGRect(x: 48, y: 33, width: 1384, height: 799))
        let none = TileGeometry.area(visibleFrame: Self.landscape, reserve: nil, gap: 0)
        #expect(none == Self.landscape)
    }

    @Test func reserveAppliesToItsDisplayOnly() {
        let everywhere = EdgeReserve(left: 40)
        #expect(everywhere.applies(to: "a") && everywhere.applies(to: "b"))
        let one = EdgeReserve(left: 40, display: "b")
        #expect(!one.applies(to: "a") && one.applies(to: "b"))
        #expect(EdgeReserve().isEmpty && !one.isEmpty)
    }

    @Test func gridOfThreeOnALaptop() throws {
        let area = TileGeometry.area(visibleFrame: Self.landscape, reserve: nil, gap: 8)
        #expect(area == CGRect(x: 8, y: 33, width: 1424, height: 859))
        let tree = try #require(TileTree.make(.grid, count: 3, shape: .landscape, main: 0.5))
        let f = TileGeometry.frames(tree, in: area, gap: 8)
        #expect(f == [CGRect(x: 8, y: 33, width: 708, height: 859),
                      CGRect(x: 724, y: 33, width: 708, height: 426),
                      CGRect(x: 724, y: 467, width: 708, height: 425)])
    }

    @Test func gridOfFourIsTwoByTwoWithTheMainColumnWider() throws {
        let area = CGRect(x: 0, y: 0, width: 1208, height: 808)
        let tree = try #require(TileTree.make(.grid, count: 4, shape: .landscape, main: 0.6))
        let f = TileGeometry.frames(tree, in: area, gap: 8)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 720, height: 400))
        #expect(f[1] == CGRect(x: 728, y: 0, width: 480, height: 400))
        #expect(f[2] == CGRect(x: 0, y: 408, width: 720, height: 400))
        #expect(f[3] == CGRect(x: 728, y: 408, width: 480, height: 400))
    }

    @Test func columnsAndRowsAreEven() throws {
        let area = CGRect(x: 0, y: 0, width: 1216, height: 800)
        let cols = TileGeometry.frames(try #require(TileTree.make(.columns, count: 3, shape: .landscape, main: 2.0 / 3)), in: area, gap: 8)
        #expect(cols.map(\.width) == [400, 400, 400])
        #expect(cols.map(\.minX) == [0, 408, 816])
        let rows = TileGeometry.frames(try #require(TileTree.make(.rows, count: 4, shape: .landscape, main: 0.5)), in: area, gap: 8)
        #expect(rows.map(\.height) == [194, 194, 194, 194])
        #expect(rows.allSatisfy { $0.width == 1216 })
    }

    @Test func sideKeepsTheMainShareAndStacksTheRest() throws {
        let area = CGRect(x: 0, y: 0, width: 1508, height: 916)
        let f = TileGeometry.frames(try #require(TileTree.make(.side, count: 4, shape: .landscape, main: 2.0 / 3)), in: area, gap: 8)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 1000, height: 916))
        #expect(f[1...].allSatisfy { $0.minX == 1008 && $0.width == 500 })
        #expect(f[1...].map(\.height) == [300, 300, 300])
    }

    @Test func ultrawideSideHasTwoLargeWindowsAndANarrowColumn() throws {
        let area = TileGeometry.area(visibleFrame: Self.ultrawide, reserve: nil, gap: 8)
        let f = TileGeometry.frames(try #require(TileTree.make(.side, count: 5, shape: .ultrawide, main: 0.5)), in: area, gap: 8)
        #expect(f[0].height == area.height && f[1].height == area.height)
        #expect(f[0].width == f[1].width)
        #expect(f[2...].allSatisfy { $0.width < f[0].width * 0.7 && $0.minX > f[1].maxX })
        #expect(f[2...].map(\.minX) == [f[2].minX, f[2].minX, f[2].minX])
        // Two windows on an ultrawide are two large halves.
        let two = TileGeometry.frames(try #require(TileTree.make(.side, count: 2, shape: .ultrawide, main: 0.5)), in: area, gap: 8)
        #expect(two[0].width == two[1].width)
    }

    @Test func portraitGridAndSidePutTheMainWindowOnTop() throws {
        let area = TileGeometry.area(visibleFrame: Self.portrait, reserve: nil, gap: 8)
        for kind in [TileLayoutKind.grid, .side] {
            for count in 2...4 {
                let f = TileGeometry.frames(try #require(TileTree.make(kind, count: count, shape: .portrait, main: 0.6)), in: area, gap: 8)
                #expect(f[0].minY == area.minY && f[0].minX == area.minX, "\(kind) \(count)")
                #expect(f[1].minY > f[0].minY, "\(kind) \(count)")
                if count < 4 || kind == .side {
                    #expect(f[0].width == area.width, "\(kind) \(count)")
                    #expect(f[1...].allSatisfy { $0.minY > f[0].minY }, "\(kind) \(count)")
                } else {
                    // Two by two: the top row is the taller one.
                    #expect(f[0].height > f[1].height && f[2].minY == f[0].minY, "\(kind) \(count)")
                }
            }
        }
        // Columns stay columns on a portrait display.
        let cols = TileGeometry.frames(try #require(TileTree.make(.columns, count: 2, shape: .portrait, main: 0.5)), in: area, gap: 8)
        #expect(cols[0].minY == cols[1].minY && cols[0].maxX < cols[1].minX)
    }

    @Test func displayShapes() {
        #expect(DisplayShape(size: CGSize(width: 1512, height: 982)) == .landscape)
        #expect(DisplayShape(size: CGSize(width: 1920, height: 1080)) == .landscape)
        #expect(DisplayShape(size: CGSize(width: 2560, height: 1080)) == .ultrawide)
        #expect(DisplayShape(size: CGSize(width: 3440, height: 1440)) == .ultrawide)
        #expect(DisplayShape(size: CGSize(width: 5120, height: 1440)) == .ultrawide)
        #expect(DisplayShape(size: CGSize(width: 2000, height: 1000)) == .landscape)
        #expect(DisplayShape(size: CGSize(width: 1080, height: 1920)) == .portrait)
        #expect(DisplayShape(size: .zero) == .landscape)
    }

    @Test func capacityAllowsAFifthWindowOnUltrawide() {
        #expect(DisplayShape.landscape.capacity(maxWindows: 4) == 4)
        #expect(DisplayShape.portrait.capacity(maxWindows: 4) == 4)
        #expect(DisplayShape.ultrawide.capacity(maxWindows: 4) == 5)
        #expect(DisplayShape.ultrawide.capacity(maxWindows: 3) == 3)
        #expect(DisplayShape.landscape.capacity(maxWindows: 0) == 1)
        #expect(DisplayShape.landscape.capacity(maxWindows: 9) == 4)
    }

    @Test func transposeSwapsAxes() {
        let t = TileTree.split(.horizontal, [.tile(0), .split(.vertical, [.tile(1), .tile(2)], [0.5, 0.5])], [0.6, 0.4])
        #expect(t.transposed == .split(.vertical, [.tile(0), .split(.horizontal, [.tile(1), .tile(2)], [0.5, 0.5])], [0.6, 0.4]))
        #expect(t.transposed.transposed == t)
    }

    @Test func overridesReplaceWeightsWhenTheShapeMatches() throws {
        let tree = try #require(TileTree.make(.side, count: 3, shape: .landscape, main: 0.5))
        let o = tree.applying([[]: [3, 1], [1]: [1, 3]])
        #expect(o == .split(.horizontal, [.tile(0), .split(.vertical, [.tile(1), .tile(2)], [0.25, 0.75])], [0.75, 0.25]))
        // A stale override (other child count) is ignored.
        let four = try #require(TileTree.make(.side, count: 4, shape: .landscape, main: 0.5))
        #expect(four.applying([[1]: [1, 3]]) == four)
        #expect(four.applying([[]: [0, 1]]) == four)
    }

    @Test func distributeRoundsToTheTotal() {
        #expect(TileGeometry.distribute(851, weights: [0.5, 0.5], minimums: [0, 0]) == [426, 425])
        #expect(TileGeometry.distribute(100, weights: [1, 1, 1], minimums: [0, 0, 0]) == [34, 33, 33])
        #expect(TileGeometry.distribute(1000, weights: [0.5, 0.5], minimums: [700, 0]) == [700, 300])
        #expect(TileGeometry.distribute(1000, weights: [0.2, 0.4, 0.4], minimums: [500, 0, 0]) == [500, 250, 250])
        let mixed = TileGeometry.distribute(997, weights: [0.3, 0.3, 0.4], minimums: [401, 0, 0])
        #expect(mixed.reduce(0, +) == 997 && mixed[0] >= 401)
    }
}

@Suite struct AutoTilingMinimumSizeTests {
    let area = CGRect(x: 8, y: 33, width: 1424, height: 859)

    @Test func splitLinesMoveToFitAMinimum() throws {
        let tree = try #require(TileTree.make(.side, count: 3, shape: .landscape, main: 0.5))
        let r = TileGeometry.solve(tree, in: area, gap: 8, minimums: [CGSize(width: 1000, height: 600)])
        guard case .placed(let f) = r else { Issue.record("expected frames, got \(r)"); return }
        #expect(f[0].width == 1000)
        #expect(f[1].minX == 1016 && f[1].width == 416)
        #expect(layoutIssues(f, area: area, gap: 8).isEmpty)
    }

    @Test func aMinimumInTheStackTakesRoomFromItsSiblings() throws {
        let tree = try #require(TileTree.make(.side, count: 4, shape: .landscape, main: 0.5))
        let r = TileGeometry.solve(tree, in: area, gap: 8, minimums: [.zero, .zero, CGSize(width: 300, height: 500)])
        guard case .placed(let f) = r else { Issue.record("expected frames, got \(r)"); return }
        #expect(f[2].height >= 500)
        #expect(abs(f[1].height - f[3].height) <= 1)
        #expect(layoutIssues(f, area: area, gap: 8).isEmpty)
    }

    @Test func aMinimumAcrossTheSplitMovesTheParentLine() throws {
        // Tile 2 sits in the stack column; its minimum width widens the whole column.
        let tree = try #require(TileTree.make(.grid, count: 3, shape: .landscape, main: 0.5))
        let r = TileGeometry.solve(tree, in: area, gap: 8, minimums: [.zero, .zero, CGSize(width: 900, height: 0)])
        guard case .placed(let f) = r else { Issue.record("expected frames, got \(r)"); return }
        #expect(f[2].width == 900 && f[1].width == 900)
        #expect(f[0].width == 516)
    }

    @Test func whenNothingFitsTheNeediestTileIsReported() throws {
        let cols = try #require(TileTree.make(.columns, count: 4, shape: .landscape, main: 0.5))
        let wide = CGSize(width: 400, height: 100)
        #expect(TileGeometry.solve(cols, in: area, gap: 8, minimums: [wide, wide, wide, wide]) == .tooSmall(tile: 3))
        #expect(TileGeometry.solve(cols, in: area, gap: 8, minimums: [wide, CGSize(width: 600, height: 0), wide, wide]) == .tooSmall(tile: 1))
        // Too tall for the display at all.
        let rows = try #require(TileTree.make(.rows, count: 2, shape: .landscape, main: 0.5))
        #expect(TileGeometry.solve(rows, in: area, gap: 8, minimums: [.zero, CGSize(width: 0, height: 900)]) == .tooSmall(tile: 1))
        // Too wide across the split.
        #expect(TileGeometry.solve(rows, in: area, gap: 8, minimums: [CGSize(width: 1500, height: 0)]) == .tooSmall(tile: 0))
    }

    @Test func plannerFloatsTheWindowThatWontFitAndTilesTheRest() {
        var board = TileBoard()
        let present: Set<UInt32> = [1, 2, 3, 4]
        for id in [1, 2, 3, 4] as [UInt32] { board.add(id, to: "d", capacity: 4, present: present, stackWhenFull: true) }
        var spec = TileSpec(kind: .columns, shape: .landscape, main: 0.5, area: area, gap: 8, capacity: 4, stackWhenFull: true)
        spec.minimumTile = CGSize(width: 200, height: 120)
        let mins: [UInt32: CGSize] = [3: CGSize(width: 1100, height: 200)]
        let plan = TilePlanner.plan(&board, display: "d", present: present, spec: spec) { mins[$0] ?? .zero }
        #expect(plan.floated == [3])
        #expect(plan.tiles == [[1], [2], [4]])
        #expect(board.floating[3] == TileBoard.Floating(reason: .tooBig, display: "d"))
        #expect(plan.frames.count == 3 && plan.frames[3] == nil)

        // When a window closes there is room again: it rejoins.
        board.remove(4)
        board.remove(2)
        let again = TilePlanner.plan(&board, display: "d", present: [1, 3], spec: spec) { mins[$0] ?? .zero }
        #expect(again.readmitted == [3])
        #expect(again.tiles == [[1], [3]])
        #expect((again.frames[3]?.width ?? 0) >= 1100)
    }

    @Test func plannerZoomsTheFocusModeWindow() {
        var board = TileBoard()
        for id in [1, 2] as [UInt32] { board.add(id, to: "d", capacity: 4, present: [1, 2], stackWhenFull: true) }
        var spec = TileSpec(kind: .side, shape: .landscape, main: 0.5, area: area, gap: 8, capacity: 4, stackWhenFull: true)
        spec.zoomed = 2
        let plan = TilePlanner.plan(&board, display: "d", present: [1, 2], spec: spec) { _ in .zero }
        #expect(plan.frames[2] == area)
        #expect(plan.frames[1] == plan.tileFrames[0])
    }

    @Test func centeredFloatStaysInTheArea() {
        let r = TilePlanner.centered(size: CGSize(width: 900, height: 700), in: area)
        #expect(r == CGRect(x: 270, y: 113, width: 900, height: 700))
        #expect(TilePlanner.centered(size: CGSize(width: 3000, height: 3000), in: area) == area)
    }
}

@Suite struct AutoTilingResizeTests {
    let area = CGRect(x: 0, y: 0, width: 1208, height: 808)

    @Test func draggingTheMainEdgeMovesTheSplit() throws {
        let tree = try #require(TileTree.make(.side, count: 3, shape: .landscape, main: 0.5))
        let r = try #require(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .right, to: 800))
        #expect(r.path == [])
        let f = TileGeometry.frames(tree.applying([r.path: r.weights]), in: area, gap: 8)
        #expect(f[0].maxX == 800)
        #expect(f[1].minX == 808 && f[2].minX == 808)
        #expect(f[1].maxX == 1208)
    }

    @Test func draggingAStackEdgeMovesOnlyItsNeighbors() throws {
        let tree = try #require(TileTree.make(.grid, count: 4, shape: .landscape, main: 0.5))
        // Tile 0's bottom edge belongs to the left column's vertical split.
        let r = try #require(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .bottom, to: 300))
        #expect(r.path == [0])
        let f = TileGeometry.frames(tree.applying([r.path: r.weights]), in: area, gap: 8)
        #expect(f[0].maxY == 300 && f[2].minY == 308)
        #expect(f[1].height == 400 && f[3].height == 400)
        // The left edge of tile 1 is the same line as tile 0's right edge.
        let l = try #require(TileGeometry.resize(tree, in: area, gap: 8, tile: 1, edge: .left, to: 708))
        let g = TileGeometry.frames(tree.applying([l.path: l.weights]), in: area, gap: 8)
        #expect(g[1].minX == 708 && g[0].maxX == 700)
    }

    @Test func outerEdgesDontResize() throws {
        let tree = try #require(TileTree.make(.columns, count: 2, shape: .landscape, main: 0.5))
        #expect(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .left, to: 40) == nil)
        #expect(TileGeometry.resize(tree, in: area, gap: 8, tile: 1, edge: .right, to: 1100) == nil)
        #expect(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .top, to: 40) == nil)
    }

    @Test func resizingKeepsBothSidesUsable() throws {
        let tree = try #require(TileTree.make(.columns, count: 2, shape: .landscape, main: 0.5))
        let r = try #require(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .right, to: 1190, minimumExtent: 200))
        let f = TileGeometry.frames(tree.applying([r.path: r.weights]), in: area, gap: 8)
        #expect(f[1].width == 200)
        let known = try #require(TileGeometry.resize(tree, in: area, gap: 8, tile: 0, edge: .right, to: 100, minimumExtent: 120,
                                                     minimums: [CGSize(width: 500, height: 0)]))
        let g = TileGeometry.frames(tree.applying([known.path: known.weights]), in: area, gap: 8)
        #expect(g[0].width == 500)
    }
}

@Suite struct AutoTilingNeighborTests {
    let area = CGRect(x: 0, y: 0, width: 1208, height: 808)

    @Test func gridNeighbors() throws {
        let f = TileGeometry.frames(try #require(TileTree.make(.grid, count: 4, shape: .landscape, main: 0.5)), in: area, gap: 8)
        #expect(TileGeometry.neighbor(of: 0, .right, in: f) == 1)
        #expect(TileGeometry.neighbor(of: 0, .down, in: f) == 2)
        #expect(TileGeometry.neighbor(of: 3, .left, in: f) == 2)
        #expect(TileGeometry.neighbor(of: 3, .up, in: f) == 1)
        #expect(TileGeometry.neighbor(of: 0, .left, in: f) == nil)
        #expect(TileGeometry.neighbor(of: 0, .up, in: f) == nil)
    }

    @Test func sideNeighbors() throws {
        let f = TileGeometry.frames(try #require(TileTree.make(.side, count: 4, shape: .landscape, main: 0.5)), in: area, gap: 8)
        #expect(TileGeometry.neighbor(of: 0, .right, in: f) == 2)   // the stack tile best centered on it
        #expect(TileGeometry.neighbor(of: 1, .left, in: f) == 0)
        #expect(TileGeometry.neighbor(of: 3, .left, in: f) == 0)
        #expect(TileGeometry.neighbor(of: 1, .down, in: f) == 2)
        #expect(TileGeometry.neighbor(of: 3, .down, in: f) == nil)
        #expect(TileGeometry.neighbor(of: 9, .down, in: f) == nil)
    }

    @Test func displayBeside() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                        CGRect(x: 0, y: 982, width: 1920, height: 1080)]
        #expect(TileGeometry.display(beside: displays[0], .right, in: displays) == 1)
        #expect(TileGeometry.display(beside: displays[1], .left, in: displays) == 0)
        #expect(TileGeometry.display(beside: displays[0], .down, in: displays) == 2)
        #expect(TileGeometry.display(beside: displays[0], .left, in: displays) == nil)
        #expect(TileGeometry.display(beside: displays[0], .up, in: displays) == nil)
    }
}

@Suite struct AutoTilingBoardTests {
    @Test func windowsFillTilesInOrder() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        #expect(b.add(1, to: "d", capacity: 4, present: present, stackWhenFull: true) == .tiled)
        #expect(b.add(2, to: "d", capacity: 4, present: present, stackWhenFull: true) == .tiled)
        #expect(b.add(3, to: "d", capacity: 4, present: present, stackWhenFull: true) == .tiled)
        #expect(b.visibleTiles(on: "d", present: present) == [[1], [2], [3]])
        #expect(b.location(of: 2)?.slot == 1)
        #expect(b.isTiled(3) && !b.isTiled(9))
    }

    @Test func fullDisplaysStackInTheActiveTile() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        b.add(1, to: "d", capacity: 2, present: present, stackWhenFull: true)
        b.add(2, to: "d", capacity: 2, present: present, stackWhenFull: true)
        #expect(b.add(3, to: "d", capacity: 2, present: present, stackWhenFull: true, active: 1) == .stacked)
        #expect(b.visibleTiles(on: "d", present: present) == [[3, 1], [2]])
        // Without an active window it goes to the last tile.
        #expect(b.add(4, to: "d", capacity: 2, present: present.union([4]), stackWhenFull: true) == .stacked)
        #expect(b.visibleTiles(on: "d", present: present.union([4])) == [[3, 1], [4, 2]])
    }

    @Test func fullDisplaysFloatExtrasWithoutStacking() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        b.add(1, to: "d", capacity: 2, present: present, stackWhenFull: false)
        b.add(2, to: "d", capacity: 2, present: present, stackWhenFull: false)
        #expect(b.add(3, to: "d", capacity: 2, present: present, stackWhenFull: false) == .floated)
        #expect(b.floating[3]?.reason == .overflow)
        // A tile frees up: the floating window rejoins.
        b.remove(1)
        b.rebalance("d", capacity: 2, present: [2, 3], stackWhenFull: false)
        #expect(b.visibleTiles(on: "d", present: [2, 3]) == [[2], [3]])
        #expect(b.floating[3] == nil)
    }

    @Test func closingAWindowUnstacksIntoTheFreedTile() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        b.add(1, to: "d", capacity: 2, present: present, stackWhenFull: true)
        b.add(2, to: "d", capacity: 2, present: present, stackWhenFull: true)
        b.add(3, to: "d", capacity: 2, present: present, stackWhenFull: true, active: 1)
        b.remove(2)
        #expect(b.visibleTiles(on: "d", present: [1, 3]) == [[3, 1]])
        b.rebalance("d", capacity: 2, present: [1, 3], stackWhenFull: true)
        #expect(b.visibleTiles(on: "d", present: [1, 3]) == [[3], [1]])
    }

    @Test func awayWindowsKeepTheirPlace() {
        var b = TileBoard()
        for id in [1, 2, 3] as [UInt32] { b.add(id, to: "d", capacity: 4, present: [1, 2, 3], stackWhenFull: true) }
        // Window 2 is minimized: the others re-flow, and a new window doesn't take its place.
        #expect(b.visibleTiles(on: "d", present: [1, 3]) == [[1], [3]])
        b.add(4, to: "d", capacity: 3, present: [1, 3, 4], stackWhenFull: true)
        #expect(b.visibleTiles(on: "d", present: [1, 3, 4]) == [[1], [3], [4]])
        // It comes back between 1 and 3.
        #expect(b.visibleTiles(on: "d", present: [1, 2, 3, 4]) == [[1], [2], [3], [4]])
    }

    @Test func shrinkingCapacityStacksOrFloatsTheExtraTiles() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3, 4]
        for id in [1, 2, 3, 4] as [UInt32] { b.add(id, to: "d", capacity: 4, present: present, stackWhenFull: true) }
        var stacked = b
        stacked.rebalance("d", capacity: 2, present: present, stackWhenFull: true)
        #expect(stacked.visibleTiles(on: "d", present: present) == [[1], [2, 3, 4]])
        b.rebalance("d", capacity: 2, present: present, stackWhenFull: false)
        #expect(b.visibleTiles(on: "d", present: present) == [[1], [2]])
        #expect(b.floating[3]?.reason == .overflow && b.floating[4]?.reason == .overflow)
    }

    @Test func swapAndMakeMain() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3, 4]
        for id in [1, 2, 3] as [UInt32] { b.add(id, to: "a", capacity: 3, present: present, stackWhenFull: true) }
        b.add(4, to: "b", capacity: 3, present: present, stackWhenFull: true)
        b.swap(1, 3)
        #expect(b.visibleTiles(on: "a", present: present) == [[3], [2], [1]])
        b.makeMain(1, present: present)
        #expect(b.visibleTiles(on: "a", present: present) == [[1], [2], [3]])
        // Across displays.
        b.swap(2, 4)
        #expect(b.visibleTiles(on: "a", present: present) == [[1], [4], [3]])
        #expect(b.visibleTiles(on: "b", present: present) == [[2]])
        b.swap(2, 2)
        b.swap(2, 99)
        #expect(b.visibleTiles(on: "b", present: present) == [[2]])
    }

    @Test func makeMainInsideTheMainStackBringsItForward() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        b.add(1, to: "d", capacity: 2, present: present, stackWhenFull: true)
        b.add(2, to: "d", capacity: 2, present: present, stackWhenFull: true)
        b.add(3, to: "d", capacity: 2, present: present, stackWhenFull: true, active: 1)   // [[3, 1], [2]]
        b.makeMain(1, present: present)
        #expect(b.visibleTiles(on: "d", present: present) == [[1, 3], [2]])
        b.makeMain(2, present: present)
        #expect(b.visibleTiles(on: "d", present: present) == [[2, 3], [1]])
    }

    @Test func cyclingAStackVisitsEveryWindow() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3, 4]
        b.add(1, to: "d", capacity: 1, present: present, stackWhenFull: true)
        b.add(2, to: "d", capacity: 1, present: present, stackWhenFull: true)
        b.add(3, to: "d", capacity: 1, present: present, stackWhenFull: true)    // [[3, 2, 1]]
        var seen: [UInt32] = []
        var current: UInt32 = 3
        for _ in 0..<3 {
            current = b.cycleStack(of: current, forward: true, present: present) ?? current
            seen.append(current)
        }
        #expect(seen == [2, 1, 3])
        #expect(b.cycleStack(of: 3, forward: false, present: present) == 1)
        #expect(b.visibleTiles(on: "d", present: present).first?.first == 1)
        // A lone window has nothing to cycle to.
        b.add(4, to: "e", capacity: 1, present: present, stackWhenFull: true)
        #expect(b.cycleStack(of: 4, forward: true, present: present) == nil)
    }

    @Test func focusBringsAStackedWindowToTheFront() {
        var b = TileBoard()
        for id in [1, 2, 3] as [UInt32] { b.add(id, to: "d", capacity: 1, present: [1, 2, 3], stackWhenFull: true) }
        b.bringToFront(1)
        #expect(b.visibleTiles(on: "d", present: [1, 2, 3]) == [[1, 3, 2]])
    }

    @Test func movingToAnotherDisplay() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3, 4, 5]
        b.add(1, to: "a", capacity: 2, present: present, stackWhenFull: true)
        b.add(2, to: "a", capacity: 2, present: present, stackWhenFull: true)
        b.add(3, to: "b", capacity: 2, present: present, stackWhenFull: true)
        // Room on b: a tile of its own, first.
        #expect(b.move(2, to: "b", at: .first, capacity: 2, present: present, stackWhenFull: true) == nil)
        #expect(b.visibleTiles(on: "b", present: present) == [[2], [3]])
        #expect(b.visibleTiles(on: "a", present: present) == [[1]])
        // b is full: stack on its last tile.
        b.move(1, to: "b", at: .last, capacity: 2, present: present, stackWhenFull: true)
        #expect(b.visibleTiles(on: "b", present: present) == [[2], [1, 3]])
        #expect(b.slots["a"] == nil)
        // Full without stacking: swap with that tile's window.
        b.add(4, to: "c", capacity: 2, present: present, stackWhenFull: true)
        #expect(b.move(4, to: "b", at: .first, capacity: 2, present: present, stackWhenFull: false) == 2)
        #expect(b.visibleTiles(on: "c", present: present) == [[2]])
        #expect(b.visibleTiles(on: "b", present: present) == [[4], [1, 3]])
        // Moving to its own display does nothing.
        #expect(b.move(4, to: "b", at: .last, capacity: 2, present: present, stackWhenFull: true) == nil)
    }

    @Test func floatingAndTilingAgain() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        for id in [1, 2, 3] as [UInt32] { b.add(id, to: "d", capacity: 4, present: present, stackWhenFull: true) }
        b.float(2, reason: .user)
        #expect(b.visibleTiles(on: "d", present: present) == [[1], [3]])
        #expect(b.floating[2] == TileBoard.Floating(reason: .user, display: "d"))
        // User-floated windows never rejoin on their own.
        b.rebalance("d", capacity: 4, present: present, stackWhenFull: true)
        #expect(b.floating[2] != nil)
        #expect(b.unfloat(2, capacity: 4, present: present, stackWhenFull: true) == .tiled)
        #expect(b.visibleTiles(on: "d", present: present) == [[1], [3], [2]])
        #expect(b.unfloat(2, capacity: 4, present: present, stackWhenFull: true) == nil)
    }

    @Test func mergingADisplayThatWentAway() {
        var b = TileBoard()
        let present: Set<UInt32> = [1, 2, 3]
        b.add(1, to: "a", capacity: 4, present: present, stackWhenFull: true)
        b.add(2, to: "b", capacity: 4, present: present, stackWhenFull: true)
        b.add(3, to: "b", capacity: 4, present: present, stackWhenFull: false)
        b.float(3, reason: .user)
        b.merge(display: "b", into: "a")
        #expect(b.visibleTiles(on: "a", present: present) == [[1], [2]])
        #expect(b.floating[3]?.display == "a")
        #expect(b.slots["b"] == nil)
    }

    @Test func removingEverywhere() {
        var b = TileBoard()
        for id in [1, 2, 3] as [UInt32] { b.add(id, to: "d", capacity: 4, present: [1, 2, 3], stackWhenFull: true) }
        b.float(3, reason: .user)
        b.removeAll { $0 != 1 }
        #expect(b.allWindows == [1])
        let removed = b.remove(7)
        #expect(!removed)
    }
}

@Suite struct AutoTilingRulesTests {
    private func traits(role: String? = "AXWindow", subrole: String? = "AXStandardWindow", resizable: Bool = true,
                        fullScreen: Bool = false, minimized: Bool = false, bundle: String? = "com.apple.Safari",
                        name: String = "Safari", own: Bool = false) -> WindowTraits {
        WindowTraits(role: role, subrole: subrole, isResizable: resizable, isFullScreen: fullScreen, isMinimized: minimized,
                     size: CGSize(width: 900, height: 700), bundleID: bundle, appName: name, isOwnApp: own)
    }

    @Test func onlyStandardResizableWindowsTile() {
        #expect(TileEligibility.evaluate(traits(), excludedApps: []) == .tile)
        for sub in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"] {
            #expect(TileEligibility.evaluate(traits(subrole: sub), excludedApps: []) == .never, "\(sub)")
        }
        #expect(TileEligibility.evaluate(traits(subrole: nil), excludedApps: []) == .never)
        #expect(TileEligibility.evaluate(traits(role: "AXSheet"), excludedApps: []) == .never)
        #expect(TileEligibility.evaluate(traits(role: "AXPopover"), excludedApps: []) == .never)
        #expect(TileEligibility.evaluate(traits(resizable: false), excludedApps: []) == .never)
        #expect(TileEligibility.evaluate(traits(own: true), excludedApps: []) == .never)
        var tiny = traits()
        tiny.size = CGSize(width: 20, height: 600)
        #expect(TileEligibility.evaluate(tiny, excludedApps: []) == .never)
    }

    @Test func fullScreenAndMinimizedWaitTheirTurn() {
        #expect(TileEligibility.evaluate(traits(fullScreen: true), excludedApps: []) == .notNow)
        #expect(TileEligibility.evaluate(traits(minimized: true), excludedApps: []) == .notNow)
    }

    @Test func optedOutApps() {
        #expect(TileEligibility.evaluate(traits(), excludedApps: ["com.apple.Safari"]) == .optedOut)
        #expect(TileEligibility.evaluate(traits(), excludedApps: ["safari"]) == .optedOut)
        #expect(TileEligibility.evaluate(traits(), excludedApps: ["Notes", " "]) == .tile)
        #expect(TileEligibility.evaluate(traits(bundle: nil, name: "Untitled Tool"), excludedApps: ["tool"]) == .optedOut)
        #expect(AppList.removing(["Safari", "com.apple.Safari", "Notes"], bundleID: "com.apple.Safari", name: "Safari") == ["Notes"])
    }

    @Test func cornerRadii() {
        #expect(WindowCorners.radius(hasToolbar: true) > WindowCorners.radius(hasToolbar: false))
        #expect(WindowCorners.radius(hasToolbar: false) == 16)
    }

    @Test func stageManagerPreference() {
        #expect(StageManagerState.isEnabled(true))
        #expect(StageManagerState.isEnabled(NSNumber(value: 1)))
        #expect(!StageManagerState.isEnabled(NSNumber(value: 0)))
        #expect(StageManagerState.isEnabled("1"))
        #expect(!StageManagerState.isEnabled(nil))
        #expect(!StageManagerState.isEnabled(Date()))
    }

    @Test func urlActions() {
        #expect(TilingCommand.parse(action: "pause", parameters: [:]) == .pause)
        #expect(TilingCommand.parse(action: "resume", parameters: [:]) == .resume)
        #expect(TilingCommand.parse(action: "toggle", parameters: [:]) == .togglePause)
        #expect(TilingCommand.parse(action: "retile", parameters: [:]) == .retile)
        #expect(TilingCommand.parse(action: "make-main", parameters: [:]) == .makeMain)
        #expect(TilingCommand.parse(action: "layout", parameters: ["kind": "side"]) == .layout(.side, display: nil))
        #expect(TilingCommand.parse(action: "layout", parameters: ["kind": "Grid", "display": "2"]) == .layout(.grid, display: 2))
        #expect(TilingCommand.parse(action: "layout", parameters: ["kind": "spiral"]) == nil)
        #expect(TilingCommand.parse(action: "layout", parameters: ["kind": "rows", "display": "0"]) == nil)
        #expect(TilingCommand.parse(action: "swap", parameters: ["dir": "left"]) == .swap(.left))
        #expect(TilingCommand.parse(action: "swap", parameters: ["direction": "down"]) == .swap(.down))
        #expect(TilingCommand.parse(action: "swap", parameters: [:]) == nil)
        #expect(TilingCommand.parse(action: "float", parameters: [:]) == .toggleFloat)
        #expect(TilingCommand.parse(action: "next-in-stack", parameters: [:]) == .cycleStack(forward: true))
        #expect(TilingCommand.parse(action: "previous-in-stack", parameters: [:]) == .cycleStack(forward: false))
        #expect(TilingCommand.parse(action: "send-to-display", parameters: [:]) == .sendToNextDisplay)
        #expect(TilingCommand.parse(action: "focus", parameters: [:]) == .focusMode)
        #expect(TilingCommand.parse(action: "no-peek", parameters: [:]) == .noPeek)
        #expect(TilingCommand.parse(action: "clean-space", parameters: [:]) == .cleanSpace)
        #expect(TilingCommand.parse(action: "tab-view", parameters: [:]) == .tabView)
        #expect(TilingCommand.parse(action: "settings", parameters: [:]) == .settings)
        #expect(TilingCommand.parse(action: "dance", parameters: [:]) == nil)
    }
}

@Suite struct AutoTilingSettingsTests {
    @Test func defaults() {
        let s = AutoTilingSettings()
        #expect(!s.paused && s.maxWindows == 4 && s.stackWhenFull && s.gap == 8)
        #expect(s.highlight == .activeBorder && s.dragToSwap && s.quickActionsAboveWindows && !s.focusFollowsMouse)
        let hyper: Modifiers = [.control, .option, .command]
        #expect(s.layoutShortcut(.grid) == Shortcut(kVK_ANSI_1, hyper))
        #expect(s.layoutShortcut(.columns) == Shortcut(kVK_ANSI_2, hyper))
        #expect(s.layoutShortcut(.rows) == Shortcut(kVK_ANSI_3, hyper))
        #expect(s.layoutShortcut(.side) == Shortcut(kVK_ANSI_4, hyper))
        #expect(s.swapShortcut(.left) == Shortcut(kVK_LeftArrow, hyper))
        #expect(s.swapShortcut(.right) == Shortcut(kVK_RightArrow, hyper))
        #expect(s.swapShortcut(.up) == Shortcut(kVK_UpArrow, hyper))
        #expect(s.swapShortcut(.down) == Shortcut(kVK_DownArrow, hyper))
        #expect(s.pauseShortcut == Shortcut(kVK_ANSI_T, hyper))
        #expect(s.makeMainShortcut == Shortcut(kVK_Return, hyper))
        // Everything beyond the core set starts unassigned.
        #expect(s.nextInStackShortcut == nil && s.previousInStackShortcut == nil && s.floatShortcut == nil)
        #expect(s.sendToDisplayShortcut == nil && s.focusModeShortcut == nil && s.noPeekShortcut == nil)
        #expect(s.cleanSpaceShortcut == nil && s.tabViewShortcut == nil)
        #expect(s.layout(for: "unknown") == DisplayLayout(kind: .grid, main: .half))
        #expect(s.gapPoints == 8)
    }

    @Test func roundTripKeepsClearedAndAssignedShortcuts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autotile-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var s = AutoTilingSettings()
        s.gridShortcut = nil
        s.focusModeShortcut = Shortcut(3, [.control, .option, .command])
        s.layouts["1552-41009-0"] = DisplayLayout(kind: .side, main: .twoThirds)
        s.reserve = EdgeReserve(bottom: 48, display: "1552-41009-0")
        s.excludedApps = ["com.apple.FaceTime"]
        store.save(s, id: "autotile", defaults: AutoTilingSettings())
        let loaded = store.load("autotile", default: AutoTilingSettings())
        #expect(loaded == s)
        #expect(loaded.gridShortcut == nil)
        #expect(loaded.focusModeShortcut == Shortcut(3, [.control, .option, .command]))
    }

    @Test func gapIsClampedToWholePoints() {
        var s = AutoTilingSettings()
        s.gap = 7.6
        #expect(s.gapPoints == 8)
        s.gap = -3
        #expect(s.gapPoints == 0)
        s.gap = 400
        #expect(s.gapPoints == 48)
    }
}
