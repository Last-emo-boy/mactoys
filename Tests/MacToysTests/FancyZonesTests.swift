import CoreGraphics
import Foundation
import Testing
@testable import FancyZones
@testable import MacToysCore

@Suite struct FancyZonesTests {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func layout(_ kind: ZoneLayout.Kind, _ count: Int) -> ZoneLayout {
        var l = ZoneLayout.template(kind)
        l.zoneCount = count
        return l
    }

    // MARK: Templates

    @Test func columnsSplitEvenlyWithSpacing() {
        let z = ZoneGeometry.zones(for: layout(.columns, 3), in: screen, spacing: 12)
        #expect(z.count == 3)
        #expect(z.map(\.width) == [384, 384, 384])
        #expect(z.map(\.minX) == [12, 408, 804])
        #expect(z.allSatisfy { $0.minY == 12 && $0.height == 776 })
    }

    @Test func columnsWithoutSpacingTile() {
        let z = ZoneGeometry.zones(for: layout(.columns, 4), in: screen, spacing: 0)
        #expect(z == [CGRect(x: 0, y: 0, width: 300, height: 800), CGRect(x: 300, y: 0, width: 300, height: 800),
                      CGRect(x: 600, y: 0, width: 300, height: 800), CGRect(x: 900, y: 0, width: 300, height: 800)])
    }

    @Test func rowsStackTopToBottom() {
        let z = ZoneGeometry.zones(for: layout(.rows, 2), in: CGRect(x: 100, y: 50, width: 600, height: 400), spacing: 0)
        #expect(z == [CGRect(x: 100, y: 50, width: 600, height: 200), CGRect(x: 100, y: 250, width: 600, height: 200)])
    }

    @Test func gridNumbersColumnByColumn() {
        let z = ZoneGeometry.zones(for: layout(.grid, 4), in: screen, spacing: 0)
        #expect(z == [CGRect(x: 0, y: 0, width: 600, height: 400), CGRect(x: 0, y: 400, width: 600, height: 400),
                      CGRect(x: 600, y: 0, width: 600, height: 400), CGRect(x: 600, y: 400, width: 600, height: 400)])
    }

    @Test func gridMergesLeftoverCellsIntoFirstColumn() {
        let z = ZoneGeometry.zones(for: layout(.grid, 5), in: screen, spacing: 0)
        #expect(z.count == 5)
        #expect(z[0] == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(z[1] == CGRect(x: 400, y: 0, width: 400, height: 400))
        #expect(z[4] == CGRect(x: 800, y: 400, width: 400, height: 400))
    }

    @Test func priorityGridHasWideCenter() {
        let z = ZoneGeometry.zones(for: layout(.priorityGrid, 5), in: screen, spacing: 0)
        #expect(z.count == 5)
        #expect(z[0] == CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(z[1] == CGRect(x: 0, y: 400, width: 300, height: 400))
        #expect(z[2] == CGRect(x: 300, y: 0, width: 600, height: 800))
        #expect(z[3] == CGRect(x: 900, y: 0, width: 300, height: 400))
        let three = ZoneGeometry.zones(for: layout(.priorityGrid, 3), in: screen, spacing: 0)
        #expect(three.map(\.width) == [300, 600, 300])
        #expect(GridLayout.priority(14).zoneCount == 14)
    }

    @Test func focusCascades() {
        let z = ZoneGeometry.zones(for: layout(.focus, 3), in: screen, spacing: 30)
        #expect(z.count == 3)
        #expect(z[0] == CGRect(x: 240, y: 160, width: 720, height: 480))
        #expect(z[1].origin == CGPoint(x: 290, y: 210))
        #expect(z[2].origin == CGPoint(x: 340, y: 260))
        #expect(ZoneGeometry.zones(for: layout(.focus, 1), in: screen, spacing: 0).count == 1)
    }

    @Test func blankHasNoZones() {
        #expect(ZoneGeometry.zones(for: .template(.blank), in: screen, spacing: 10).isEmpty)
        #expect(ZoneLayout.template(.blank).count == 0)
    }

    @Test func everyTemplateProducesItsZoneCountInsideTheArea() {
        let area = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        for kind in [ZoneLayout.Kind.focus, .columns, .rows, .grid, .priorityGrid] {
            for n in 1...12 {
                let l = layout(kind, n)
                let z = ZoneGeometry.zones(for: l, in: area, spacing: 8)
                #expect(z.count == n, "\(kind) \(n)")
                #expect(l.count == n)
                #expect(z.allSatisfy { area.contains($0) && $0.width > 0 && $0.height > 0 }, "\(kind) \(n)")
            }
        }
    }

    @Test func gridZonesDoNotOverlap() {
        for n in 1...11 {
            let z = ZoneGeometry.zones(for: layout(.priorityGrid, n), in: screen, spacing: 0)
            for i in z.indices { for j in z.indices where j > i { #expect(z[i].intersection(z[j]).area == 0) } }
            #expect(z.reduce(0) { $0 + $1.area } == screen.area, "priority \(n) tiles the screen")
        }
    }

    @Test func spacingIsIgnoredWhenHidden() {
        var l = layout(.columns, 2)
        l.showSpacing = false
        #expect(l.zones(in: screen).first == CGRect(x: 0, y: 0, width: 600, height: 800))
        l.showSpacing = true
        l.spacing = 20
        #expect(l.zones(in: screen).first == CGRect(x: 20, y: 20, width: 570, height: 760))
    }

    // MARK: Grid editing

    @Test func splitVerticallyThenHorizontally() {
        var g = GridLayout.columns(1)
        g = g.splitting(zone: 0, vertical: true, at: 0.25)
        #expect(g.zoneCount == 2)
        #expect(g.columns.map { ($0 * 100).rounded() } == [25, 75])
        g = g.splitting(zone: 1, vertical: false, at: 0.5)
        #expect(g.zoneCount == 3)
        #expect(g.rowCount == 2)
        // Left zone spans both rows; the right column is split.
        #expect(g.cells == [[0, 1], [0, 2]])
        let z = g.zones(in: screen, spacing: 0)
        #expect(z[0] == CGRect(x: 0, y: 0, width: 300, height: 800))
        #expect(z[2] == CGRect(x: 300, y: 400, width: 900, height: 400))
    }

    @Test func splitRejectsSlivers() {
        let g = GridLayout.columns(1)
        #expect(g.splitting(zone: 0, vertical: true, at: 0.01) == g)
        #expect(g.splitting(zone: 0, vertical: true, at: 0.995) == g)
        #expect(g.splitting(zone: 5, vertical: true, at: 0.5) == g)
    }

    @Test func splitOnExistingBoundaryReusesIt() {
        var g = GridLayout.grid(4).merging([0, 2])     // top row merged
        #expect(g.zoneCount == 3)
        #expect(g.cells == [[0, 0], [1, 2]])
        g = g.splitting(zone: 0, vertical: true, at: 0.5)
        #expect(g.zoneCount == 4)
        #expect(g.columnCount == 2)
        #expect(g.cells == [[0, 2], [1, 3]])
    }

    @Test func mergeGrowsToRectangleAndCollapses() {
        let g = GridLayout.columns(3)
        #expect(g.mergeClosure([0, 2]) == [0, 1, 2])
        let merged = g.merging([0, 2])
        #expect(merged.zoneCount == 1)
        #expect(merged.columnCount == 1)
        #expect(merged == GridLayout.columns(1))
    }

    @Test func mergeLeftColumnOfGrid() {
        let g = GridLayout.grid(4).merging([0, 1])
        #expect(g.zoneCount == 3)
        #expect(g.cells == [[0, 1], [0, 2]])
        #expect(g.mergeClosure([1]) == [1])
        #expect(g.merging([1]) == g)
    }

    @Test func mergeClosureIncludesZonesCrossingTheBox() {
        // Left tall zone 0, right column split into 1 (top) and 2 (bottom).
        let g = GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [0, 2]])
        #expect(g.mergeClosure([0, 1]) == [0, 1, 2])
        #expect(g.mergeClosure([1, 2]) == [1, 2])
    }

    @Test func splittersFollowZoneBoundaries() {
        let g = GridLayout.grid(4).merging([0, 2])
        let s = g.splitters
        let vertical = s.filter(\.vertical)
        let horizontal = s.filter { !$0.vertical }
        #expect(vertical.count == 1)
        #expect(vertical[0].range == 0.5...1.0)
        #expect(horizontal.count == 1)
        #expect(horizontal[0].range == 0.0...1.0)
        #expect(horizontal[0].position == 0.5)
    }

    @Test func movingSplitterResizesNeighborsAndClamps() {
        let g = GridLayout.columns(3)
        let moved = g.movingSplitter(vertical: true, index: 0, to: 0.5)
        #expect(abs(moved.columns[0] - 0.5) < 1e-9)
        #expect(abs(moved.columns[1] - 1.0 / 6) < 1e-9)
        #expect(abs(moved.columns[2] - 1.0 / 3) < 1e-9)
        let clamped = g.movingSplitter(vertical: true, index: 0, to: 0.99)
        #expect(abs(clamped.columns[1] - GridLayout.minimumFraction) < 1e-9)
        #expect(g.movingSplitter(vertical: true, index: 2, to: 0.5) == g)
        let rows = GridLayout.rows(2).movingSplitter(vertical: false, index: 0, to: 0.25)
        #expect(rows.rows.map { ($0 * 100).rounded() } == [25, 75])
    }

    @Test func malformedGridsAreRejected() {
        #expect(GridLayout.priority(7).isValid)
        #expect(!GridLayout(rows: [0.5, 0.5], columns: [1], cells: [[0]]).isWellFormed)          // row count
        #expect(!GridLayout(rows: [1], columns: [0.5, 0.5], cells: [[0]]).isWellFormed)          // column count
        #expect(!GridLayout(rows: [1], columns: [1, -1], cells: [[0, 1]]).isWellFormed)          // negative fraction
        #expect(!GridLayout(rows: [1], columns: [0.5, 0.5], cells: [[0, 2]]).isValid)            // gap in numbering
        #expect(!GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [1, 0]]).isValid)   // not rectangles
        var l = ZoneLayout.newGrid(name: "Bad")
        l.grid = GridLayout(rows: [0.5, 0.5], columns: [1], cells: [[0]])
        #expect(l.count == 0 && l.zones(in: screen).isEmpty, "a malformed grid never crashes geometry")
        let lib = LayoutLibrary(custom: [l, ZoneLayout(id: "c", name: "C", kind: .canvas,
                                                       canvas: CanvasLayout(referenceWidth: 0, referenceHeight: 10, zones: []))])
        #expect(lib.normalized().custom.isEmpty)
    }

    @Test func transposeRoundTrips() {
        let g = GridLayout.priority(7)
        #expect(g.transposed().transposed() == g)
    }

    // MARK: Canvas

    @Test func canvasScalesToOtherDisplays() {
        let c = CanvasLayout(referenceWidth: 1000, referenceHeight: 500,
                             zones: [CanvasZone(x: 100, y: 50, width: 400, height: 200),
                                     CanvasZone(x: 0, y: 0, width: 1000, height: 500)])
        let z = c.zones(in: CGRect(x: 1440, y: 25, width: 2000, height: 1000))
        #expect(z[0] == CGRect(x: 1640, y: 125, width: 800, height: 400))
        #expect(z[1] == CGRect(x: 1440, y: 25, width: 2000, height: 1000))
        var l = ZoneLayout.newCanvas(name: "C", reference: CGSize(width: 1000, height: 500))
        l.canvas = c
        #expect(ZoneGeometry.zones(for: l, in: CGRect(x: 0, y: 0, width: 500, height: 250), spacing: 40)[0]
                == CGRect(x: 50, y: 25, width: 200, height: 100))
    }

    @Test func duplicatingTemplatesKeepsTheirZones() {
        let ref = CGSize(width: 1200, height: 800)
        let pg = layout(.priorityGrid, 5)
        let copy = pg.duplicated(name: "Mine", reference: ref)
        #expect(copy.kind == .customGrid)
        #expect(copy.id != pg.id)
        #expect(copy.zones(in: screen) == pg.zones(in: screen))
        let focus = layout(.focus, 2).duplicated(name: "F", reference: ref)
        #expect(focus.kind == .canvas)
        #expect(focus.zones(in: screen) == layout(.focus, 2).zones(in: screen))
    }

    // MARK: Hit testing

    @Test func hitTestHighlightsAdjacentZonesNearTheirEdge() {
        let z = ZoneGeometry.zones(for: layout(.columns, 2), in: screen, spacing: 0)
        #expect(ZoneGeometry.zones(at: CGPoint(x: 200, y: 300), in: z, distance: 20) == [0])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 590, y: 300), in: z, distance: 20) == [0, 1])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 590, y: 300), in: z, distance: 5) == [0])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 900, y: 300), in: z, distance: 20) == [1])
    }

    @Test func hitTestIgnoresPointsOutsideASingleZone() {
        let z = [CGRect(x: 100, y: 100, width: 200, height: 200)]
        #expect(ZoneGeometry.zones(at: CGPoint(x: 90, y: 150), in: z, distance: 20).isEmpty)
        #expect(ZoneGeometry.zones(at: CGPoint(x: 150, y: 150), in: z, distance: 20) == [0])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 700, y: 700), in: z, distance: 20).isEmpty)
    }

    @Test func hitTestInGapBetweenSpacedZones() {
        let z = ZoneGeometry.zones(for: layout(.columns, 2), in: screen, spacing: 20)
        // The gap between the zones is 20 pt wide around x = 600.
        #expect(ZoneGeometry.zones(at: CGPoint(x: 600, y: 300), in: z, distance: 15) == [0, 1])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 600, y: 300), in: z, distance: 5).isEmpty)
    }

    @Test func overlappingZonesPickOneByAlgorithm() {
        let big = CGRect(x: 0, y: 0, width: 800, height: 600)
        let small = CGRect(x: 100, y: 100, width: 200, height: 200)
        let z = [big, small]
        let p = CGPoint(x: 150, y: 150)
        #expect(ZoneGeometry.zones(at: p, in: z, distance: 10, algorithm: .smallest) == [1])
        #expect(ZoneGeometry.zones(at: p, in: z, distance: 10, algorithm: .largest) == [0])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 295, y: 295), in: z, distance: 10, algorithm: .closestCenter) == [0])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 210, y: 200), in: z, distance: 10, algorithm: .closestCenter) == [1])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 150, y: 200), in: z, distance: 10, algorithm: .positional) == [1])
        #expect(ZoneGeometry.zones(at: CGPoint(x: 250, y: 200), in: z, distance: 10, algorithm: .positional) == [0])
    }

    // MARK: Spanning

    @Test func spanUnionsTheBoundingBox() {
        let z = ZoneGeometry.zones(for: layout(.grid, 4), in: screen, spacing: 0)
        #expect(ZoneGeometry.union(of: [0, 3], in: z) == screen)
        #expect(Set(ZoneGeometry.span(from: [0], to: [3], in: z)) == [0, 1, 2, 3])
        #expect(ZoneGeometry.span(from: [0], to: [2], in: z) == [0, 2])
        #expect(ZoneGeometry.union(of: [0, 2], in: z) == CGRect(x: 0, y: 0, width: 1200, height: 400))
        let spaced = ZoneGeometry.zones(for: layout(.columns, 3), in: screen, spacing: 12)
        #expect(ZoneGeometry.span(from: [0], to: [2], in: spaced) == [0, 1, 2])
        #expect(ZoneGeometry.union(of: [], in: z).isNull)
    }

    @Test func frameMatchingFindsSnappedZones() {
        let z = ZoneGeometry.zones(for: layout(.grid, 4), in: screen, spacing: 0)
        #expect(ZoneGeometry.zonesMatching(frame: CGRect(x: 1, y: 0, width: 599, height: 401), in: z) == [0])
        #expect(ZoneGeometry.zonesMatching(frame: CGRect(x: 0, y: 0, width: 1200, height: 400), in: z) == [0, 2])
        #expect(ZoneGeometry.zonesMatching(frame: CGRect(x: 50, y: 50, width: 300, height: 300), in: z).isEmpty)
    }

    // MARK: Keyboard navigation

    @Test func zoneIndexNavigation() {
        #expect(ZoneGeometry.index(after: [0], count: 3, direction: .right, wrap: false) == 1)
        #expect(ZoneGeometry.index(after: [2], count: 3, direction: .right, wrap: false) == nil)
        #expect(ZoneGeometry.index(after: [2], count: 3, direction: .right, wrap: true) == 0)
        #expect(ZoneGeometry.index(after: [0], count: 3, direction: .left, wrap: true) == 2)
        #expect(ZoneGeometry.index(after: [0, 1], count: 3, direction: .down, wrap: false) == 2)
        #expect(ZoneGeometry.index(after: [1, 2], count: 3, direction: .up, wrap: false) == 0)
        #expect(ZoneGeometry.index(after: [], count: 3, direction: .right, wrap: false) == 0)
        #expect(ZoneGeometry.index(after: [], count: 3, direction: .left, wrap: false) == 2)
        #expect(ZoneGeometry.index(after: [], count: 0, direction: .left, wrap: true) == nil)
    }

    @Test func relativePositionNavigation() {
        let z = ZoneGeometry.zones(for: layout(.grid, 4), in: screen, spacing: 0)
        #expect(ZoneGeometry.zone(from: z[0], direction: .right, in: z) == 2)
        #expect(ZoneGeometry.zone(from: z[0], direction: .down, in: z) == 1)
        #expect(ZoneGeometry.zone(from: z[3], direction: .left, in: z) == 1)
        #expect(ZoneGeometry.zone(from: z[3], direction: .up, in: z) == 2)
        #expect(ZoneGeometry.zone(from: z[0], direction: .up, in: z) == nil)
        #expect(ZoneGeometry.zone(from: z[2], direction: .right, in: z) == nil)
        // A free window goes to the nearest zone whose center lies to its right.
        let window = CGRect(x: 300, y: 500, width: 200, height: 200)
        #expect(ZoneGeometry.zone(from: window, direction: .right, in: z) == 3)
    }

    @Test func relativeNavigationPrefersAlignedZones() {
        // Priority grid: from the top-left zone, right goes to the center, then to the top-right.
        let z = ZoneGeometry.zones(for: layout(.priorityGrid, 5), in: screen, spacing: 0)
        #expect(ZoneGeometry.zone(from: z[0], direction: .right, in: z) == 2)
        #expect(ZoneGeometry.zone(from: z[2], direction: .right, in: z) == 3 || ZoneGeometry.zone(from: z[2], direction: .right, in: z) == 4)
        #expect(ZoneGeometry.zone(from: z[1], direction: .up, in: z) == 0)
    }

    @Test func relativeWrapEntersFromTheOppositeEdge() {
        let z = ZoneGeometry.zones(for: layout(.grid, 4), in: screen, spacing: 0)
        #expect(ZoneGeometry.wrappedZone(from: z[2], direction: .right, in: z, area: screen) == 0)
        #expect(ZoneGeometry.wrappedZone(from: z[3], direction: .right, in: z, area: screen) == 1)
        #expect(ZoneGeometry.wrappedZone(from: z[1], direction: .down, in: z, area: screen) == 0)
        #expect(ZoneGeometry.wrappedZone(from: z[0], direction: .left, in: z, area: screen) == 2)
    }

    @Test func extendingAcrossZonesUsesSpan() {
        let z = ZoneGeometry.zones(for: layout(.columns, 4), in: screen, spacing: 0)
        guard let next = ZoneGeometry.zone(from: z[1], direction: .right, in: z) else {
            Issue.record("no zone to the right"); return
        }
        #expect(next == 2)
        #expect(ZoneGeometry.span(from: [1], to: [next], in: z) == [1, 2])
        #expect(ZoneGeometry.union(of: [1, 2], in: z) == CGRect(x: 300, y: 0, width: 600, height: 800))
    }

    @Test func textPreviewForTheCLI() {
        var l = layout(.columns, 3)
        l.showSpacing = false
        #expect(ZoneGeometry.preview(l, width: 6, height: 2) == "112233\n112233")
        #expect(ZoneGeometry.preview(.template(.blank), width: 3, height: 1) == "···")
        let pg = ZoneGeometry.preview(layout(.priorityGrid, 5), width: 8, height: 4)
        #expect(pg == "11333344\n11333344\n22333355\n22333355")
    }

    // MARK: Library

    @Test func quickKeysStayUnique() {
        var lib = LayoutLibrary()
        let custom = ZoneLayout.newGrid(name: "Coding")
        lib.add(custom)
        lib.setQuickKey(1, for: custom.id)
        #expect(lib.layout(quickKey: 1)?.id == custom.id)
        #expect(lib.templates.first { $0.kind == .priorityGrid }?.quickKey == nil)
        lib.setQuickKey(nil, for: custom.id)
        #expect(lib.layout(quickKey: 1) == nil)
    }

    @Test func wheelCyclesKeyedLayoutsInKeyOrder() {
        var lib = LayoutLibrary()
        let order = lib.wheelCycle.map(\.kind)
        #expect(order == [.priorityGrid, .columns, .rows, .grid])
        #expect(lib.cycled(from: "grid", steps: 1)?.kind == .priorityGrid)
        #expect(lib.cycled(from: "priorityGrid", steps: -1)?.kind == .grid)
        #expect(lib.cycled(from: "focus", steps: 1)?.kind == .priorityGrid)
        for t in lib.templates { lib.setQuickKey(nil, for: t.id) }
        #expect(lib.wheelCycle.count == 5)
        lib.add(.newGrid(name: "A"))
        lib.add(.newGrid(name: "B"))
        #expect(lib.wheelCycle.map(\.name) == ["A", "B"])
    }

    @Test func resolveByNumberIdOrName() {
        var lib = LayoutLibrary()
        let c = ZoneLayout.newGrid(name: "Ultrawide 3+1")
        lib.add(c)
        #expect(lib.resolve("2")?.kind == .columns)
        #expect(lib.resolve("ultrawide 3+1")?.id == c.id)
        #expect(lib.resolve(c.id)?.id == c.id)
        #expect(lib.resolve("priority grid")?.kind == .priorityGrid)
        #expect(lib.resolve("nothing") == nil)
    }

    @Test func assignmentFallsBackToOrientationDefault() {
        var lib = LayoutLibrary()
        #expect(lib.layout(forDisplay: "a", vertical: false, defaultHorizontal: "columns", defaultVertical: "rows").kind == .columns)
        #expect(lib.layout(forDisplay: "a", vertical: true, defaultHorizontal: "columns", defaultVertical: "rows").kind == .rows)
        let c = ZoneLayout.newGrid(name: "X")
        lib.add(c)
        lib.assignments["a"] = c.id
        #expect(lib.layout(forDisplay: "a", vertical: false, defaultHorizontal: "columns", defaultVertical: "rows").id == c.id)
        lib.delete(id: c.id)
        #expect(lib.assignments["a"] == nil)
    }

    @Test func normalizeRepairsLibrary() {
        var lib = LayoutLibrary(templates: [ZoneLayout.template(.columns)], custom: [
            ZoneLayout(id: "broken", name: "Broken", kind: .customGrid),
            ZoneLayout.newGrid(name: "Ok"),
        ])
        lib.custom[1].quickKey = 12
        let n = lib.normalized()
        #expect(n.templates.map(\.kind) == ZoneLayout.Kind.templates)
        #expect(n.custom.map(\.name) == ["Ok"])
        #expect(n.custom[0].quickKey == nil)
        #expect(lib.uniqueName("Columns") == "Columns 2")
    }

    @Test func templatesAreStoredInEnglishAndShownByKind() {
        let pg = ZoneLayout.template(.priorityGrid)
        #expect(pg.name == "Priority Grid")
        #expect(pg.displayName == ZoneLayout.Kind.priorityGrid.title)
        #expect(LayoutLibrary().resolve("Priority Grid")?.kind == .priorityGrid)
        let custom = ZoneLayout.newGrid(name: "Coding")
        #expect(custom.displayName == "Coding")
    }

    @Test func libraryAndSettingsPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var lib = LayoutLibrary()
        var g = ZoneLayout.newGrid(name: "Split")
        g.grid = GridLayout.columns(2).splitting(zone: 1, vertical: false, at: 0.4)
        lib.add(g)
        lib.add(.newCanvas(name: "Free", reference: CGSize(width: 1512, height: 945)))
        lib.assignments["1552-41001-0"] = g.id
        store.save(lib, id: "fancyzones.layouts")
        #expect(store.load("fancyzones.layouts", default: LayoutLibrary()) == lib)

        var s = FancyZonesSettings()
        s.moveLeft = nil
        s.opacity = 70
        store.save(s, id: "fancyzones")
        let back = store.load("fancyzones", default: FancyZonesSettings())
        #expect(back.moveLeft == nil, "a cleared shortcut stays cleared")
        #expect(back.moveRight == FancyZonesSettings().moveRight)
        #expect(back.opacity == 70)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Activation key

    @Test func activationKeysMapToTheirModifier() {
        let cases: [(ActivationKey, CGEventFlags)] = [(.shift, .maskShift), (.function, .maskSecondaryFn),
                                                       (.option, .maskAlternate), (.control, .maskControl)]
        for (key, flag) in cases {
            #expect(key.flag == flag)
            #expect(key.zonesActive(flags: flag, toggled: false), "\(key) held")
            #expect(!key.zonesActive(flags: [], toggled: false), "\(key) not held")
            #expect(key.zonesActive(flags: [flag, .maskCommand], toggled: false), "⌘ (span) doesn't get in the way")
            #expect(!key.zonesActive(flags: flag, toggled: true), "the mouse-button toggle flips \(key)")
            #expect(key.zonesActive(flags: [], toggled: true))
        }
        #expect(!ActivationKey.shift.zonesActive(flags: .maskCommand, toggled: false), "⌘ alone never activates")
        #expect(!ActivationKey.option.zonesActive(flags: .maskShift, toggled: false))
        #expect(ActivationKey.allCases.compactMap(\.glyph) == ["⇧", "fn", "⌥", "⌃"])
    }

    @Test func noActivationKeyMeansZonesAlwaysOnAndShiftDragsFreely() {
        let key = ActivationKey.none
        #expect(key.flag.isEmpty)
        #expect(key.glyph == nil)
        #expect(key.zonesActive(flags: [], toggled: false))
        #expect(key.zonesActive(flags: .maskAlternate, toggled: false))
        #expect(!key.zonesActive(flags: .maskShift, toggled: false))
        #expect(!key.zonesActive(flags: [], toggled: true))
        #expect(key.zonesActive(flags: .maskShift, toggled: true))
    }

    @Test func activationMigratesFromHoldShift() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        // Fresh install: ⇧, and nothing stored for the new key.
        #expect(FancyZonesSettings().activation == .shift)
        #expect(FancyZonesSettings().activationKey == nil)
        // A file written before the choice existed.
        try Data(#"{"holdShiftToActivate": false, "opacity": 30}"#.utf8).write(to: store.url(for: "fancyzones"))
        var old = store.load("fancyzones", default: FancyZonesSettings())
        #expect(old.activation == .none, "zones always on stays zones always on")
        #expect(old.opacity == 30)
        try Data(#"{"holdShiftToActivate": true}"#.utf8).write(to: store.url(for: "fancyzones"))
        old = store.load("fancyzones", default: FancyZonesSettings())
        #expect(old.activation == .shift)

        // Choosing a key stores it and keeps the old flag in step for older versions.
        var s = FancyZonesSettings()
        s.activation = .function
        #expect(s.holdShiftToActivate)
        store.save(s, id: "fancyzones", defaults: FancyZonesSettings())
        let back = store.load("fancyzones", default: FancyZonesSettings())
        #expect(back.activation == .function)
        s.activation = .none
        #expect(!s.holdShiftToActivate)
        store.save(s, id: "fancyzones", defaults: FancyZonesSettings())
        #expect(store.load("fancyzones", default: FancyZonesSettings()).activation == .none)
    }

    @Test func newSettingsDefaults() {
        let s = FancyZonesSettings()
        #expect(!s.edgeSnap)
        #expect(s.editorSnapToGrid)
        #expect(s.editorGridDivisions == 12)
        #expect(FancyZonesSettings.gridDivisionChoices.contains(s.editorGridDivisions))
        var odd = s
        odd.editorGridDivisions = 0
        #expect(odd.gridDivisions == 2)
    }

    // MARK: Edge snap

    @Test func edgeSnapRegionsOnALoneDisplay() {
        let d = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(EdgeSnap.region(at: CGPoint(x: 0, y: 450), display: d, others: []) == .left)
        #expect(EdgeSnap.region(at: CGPoint(x: 1439, y: 450), display: d, others: []) == .right)
        #expect(EdgeSnap.region(at: CGPoint(x: 720, y: 0), display: d, others: []) == .fill)
        #expect(EdgeSnap.region(at: CGPoint(x: 0, y: 20), display: d, others: []) == .topLeft)
        #expect(EdgeSnap.region(at: CGPoint(x: 30, y: 0), display: d, others: []) == .topLeft)
        #expect(EdgeSnap.region(at: CGPoint(x: 1439, y: 880), display: d, others: []) == .bottomRight)
        #expect(EdgeSnap.region(at: CGPoint(x: 40, y: 899), display: d, others: []) == .bottomLeft)
        #expect(EdgeSnap.region(at: CGPoint(x: 720, y: 899), display: d, others: []) == nil, "the bottom edge only has corners")
        #expect(EdgeSnap.region(at: CGPoint(x: 720, y: 450), display: d, others: []) == nil)
        #expect(EdgeSnap.region(at: CGPoint(x: 10, y: 450), display: d, others: []) == nil, "too far from the edge")
    }

    @Test func edgeSnapNeverFiresWhereDisplaysMeet() {
        // A 1080p display, a taller one to its right (top aligned), a third above the first.
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let c = CGRect(x: 0, y: -1117, width: 1728, height: 1117)
        let all = [a, b, c]
        func region(_ p: CGPoint, _ d: CGRect) -> EdgeSnapRegion? {
            EdgeSnap.region(at: p, display: d, others: all.filter { $0 != d })
        }
        #expect(region(CGPoint(x: 1919, y: 500), a) == nil, "a's right edge leads into b")
        #expect(region(CGPoint(x: 1920, y: 500), b) == nil, "b's left edge leads into a")
        #expect(region(CGPoint(x: 0, y: 500), a) == .left)
        #expect(region(CGPoint(x: 4479, y: 700), b) == .right)
        #expect(region(CGPoint(x: 1920, y: 1250), b) == .left, "below a, b's left edge is free")
        #expect(region(CGPoint(x: 900, y: 0), a) == nil, "a's top leads into c")
        #expect(region(CGPoint(x: 1850, y: 0), a) == .topRight, "past c's right end, a's top is free")
        #expect(region(CGPoint(x: 900, y: -1117), c) == .fill)
        #expect(region(CGPoint(x: 900, y: -1), c) == nil, "c's bottom leads into a")
        #expect(EdgeSnap.isShared(.right, of: a, at: CGPoint(x: 1919, y: 10), others: [b]))
        #expect(!EdgeSnap.isShared(.right, of: a, at: CGPoint(x: 1919, y: 10), others: [c]))
        #expect(!EdgeSnap.isShared(.left, of: b, at: CGPoint(x: 1920, y: 1300), others: [a]))
    }

    @Test func edgeSnapTargetsTileTheWorkArea() {
        let work = CGRect(x: 1440, y: 25, width: 1511, height: 875)
        let left = EdgeSnapRegion.left.rect(in: work), right = EdgeSnapRegion.right.rect(in: work)
        #expect(left.minX == work.minX && right.maxX == work.maxX && left.maxX == right.minX)
        #expect(left.height == work.height)
        let quarters: [EdgeSnapRegion] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let rects = quarters.map { $0.rect(in: work) }
        #expect(rects.reduce(0) { $0 + $1.area } == work.area)
        for i in rects.indices { for j in rects.indices where j > i { #expect(rects[i].intersection(rects[j]).area == 0) } }
        #expect(EdgeSnapRegion.fill.rect(in: work) == work)
    }

    // MARK: Canvas snapping

    private var canvasArea: CGSize { CGSize(width: 1200, height: 800) }

    @Test func snappingPrefersNeighborEdgesOverTheGrid() {
        let snapper = CanvasSnapper(area: canvasArea, zones: [CGRect(x: 0, y: 0, width: 437, height: 300)], gridDivisions: 12)
        #expect(snapper.stepX == 100)
        #expect(snapper.snapX(441) == 437, "a neighbor's edge within tolerance wins")
        #expect(snapper.snapX(460) == 500, "otherwise the nearest grid line")
        #expect(snapper.snapX(1195) == 1200, "the display edge")
        let noGrid = CanvasSnapper(area: canvasArea, zones: [CGRect(x: 0, y: 0, width: 437, height: 300)], gridDivisions: nil)
        #expect(noGrid.snapX(460) == 460)
        #expect(noGrid.snapX(432) == 437)
        #expect(CanvasSnapper.free.snapX(441) == 441)
        #expect(CanvasSnapper.free.move(CGRect(x: 3, y: 3, width: 50, height: 50)).rect == CGRect(x: 3, y: 3, width: 50, height: 50))
    }

    @Test func movingKeepsTheSizeAndShowsGuides() {
        let snapper = CanvasSnapper(area: canvasArea, zones: [CGRect(x: 0, y: 0, width: 437, height: 300)], gridDivisions: 12)
        let moved = snapper.move(CGRect(x: 443, y: 10, width: 300, height: 200))
        #expect(moved.rect == CGRect(x: 437, y: 0, width: 300, height: 200))
        #expect(moved.guides == [SnapGuide(vertical: true, position: 437)], "a guide where it meets the zone, none at the display edge")
        // Right edge closer to the display edge than the left one is to anything: it snaps there.
        let right = snapper.move(CGRect(x: 896, y: 400, width: 300, height: 200)).rect
        #expect(right.maxX == 1200 && right.width == 300)
    }

    @Test func zonesMovedAwayFromTheirOwnEdgesDontSnapToThemselves() {
        let zones = [CGRect(x: 100, y: 100, width: 300, height: 200)]
        let snapper = CanvasSnapper(area: canvasArea, zones: zones, excluding: 0, gridDivisions: nil)
        #expect(snapper.move(CGRect(x: 104, y: 100, width: 300, height: 200)).rect.minX == 104)
    }

    @Test func resizingSnapsOnlyTheMovingEdges() {
        let snapper = CanvasSnapper(area: canvasArea, zones: [CGRect(x: 800, y: 0, width: 400, height: 800)], gridDivisions: 12)
        let r = snapper.resize(CGRect(x: 233, y: 140, width: 562, height: 300), edges: .right)
        #expect(r.rect == CGRect(x: 233, y: 140, width: 567, height: 300), "right edge meets the neighbor at 800")
        #expect(r.guides == [SnapGuide(vertical: true, position: 800)])
        let corner = snapper.resize(CGRect(x: 233, y: 140, width: 300, height: 300), edges: [.bottom, .right]).rect
        #expect(corner.maxX == 500)
        #expect(abs(corner.maxY - 800.0 * 7 / 12) < 0.001)
        #expect(corner.minX == 233 && corner.minY == 140, "the other edges stay")
        let tiny = snapper.resize(CGRect(x: 0, y: 0, width: 45, height: 100), edges: .right, minimum: 40)
        #expect(tiny.rect.width == 45, "snapping never shrinks a zone below the minimum")
    }

    @Test func drawingSnapsBothCornersAndStaysInside() {
        let snapper = CanvasSnapper(area: canvasArea, zones: [], gridDivisions: 12)
        let drawn = snapper.draw(from: CGPoint(x: 3, y: 5), to: CGPoint(x: 596, y: 402), in: canvasArea)
        #expect(drawn.rect.origin == .zero)
        #expect(drawn.rect.width == 600)
        #expect(abs(drawn.rect.height - 400) < 0.001)
        #expect(drawn.guides.isEmpty, "the display edge needs no guide")
        let backwards = snapper.draw(from: CGPoint(x: 1300, y: 900), to: CGPoint(x: 710, y: 330), in: canvasArea)
        #expect(backwards.rect.maxX == 1200 && backwards.rect.minX == 700)
        #expect(backwards.rect.maxY == 800)
    }

    @Test @MainActor func editorDrawsAZoneAndAddsIt() {
        let display = ZoneDisplay(key: "d", name: "D", number: 1, frame: CGRect(origin: .zero, size: canvasArea),
                                  workArea: CGRect(origin: .zero, size: canvasArea), isBuiltIn: true)
        let model = EditorModel(displays: [display], selectedKey: "d", library: LayoutLibrary(), pickerScreen: display.frame,
                                defaultHorizontal: "columns", defaultVertical: "rows", snapToGrid: true, gridDivisions: 12)
        model.newIsCanvas = true
        model.beginCreate()
        model.create()
        let before = model.draft?.canvas?.zones.count ?? 0
        model.drawZone(from: CGPoint(x: 8, y: 6), to: CGPoint(x: 291, y: 270), in: canvasArea)
        #expect(model.showsGrid)
        #expect(model.drawingZone == CGRect(x: 0, y: 0, width: 300, height: 800.0 / 3))
        model.finishDrawing(in: canvasArea)
        #expect(model.draft?.canvas?.zones.count == before + 1)
        #expect(model.canvasSelection == before)
        #expect(model.drawingZone == nil && model.guides.isEmpty && !model.showsGrid)
        // Too small to hold a window: nothing is added.
        model.drawZone(from: CGPoint(x: 600, y: 600), to: CGPoint(x: 610, y: 612), in: canvasArea)
        model.finishDrawing(in: canvasArea)
        #expect(model.draft?.canvas?.zones.count == before + 1)
        // ⌘ held: free placement.
        model.commandDown = true
        model.drawZone(from: CGPoint(x: 13, y: 17), to: CGPoint(x: 413, y: 317), in: canvasArea)
        #expect(model.drawingZone == CGRect(x: 13, y: 17, width: 400, height: 300))
        #expect(!model.showsGrid)
    }

    // MARK: Presets

    @Test func presetsAreValidLayoutsThatTileTheDisplay() {
        #expect(LayoutPreset.workflows.count == 6)
        #expect(LayoutPreset.ultrawide.count == 5)
        #expect(Set(LayoutPreset.allCases.map(\.title)).count == LayoutPreset.allCases.count)
        for p in LayoutPreset.allCases {
            let g = p.grid
            #expect(g.isValid, "\(p)")
            #expect(g == g.normalized(), "\(p) is stored normalized")
            #expect(p.zoneSymbols.count == g.zoneCount, "\(p) has a symbol per zone")
            #expect(g.zoneCount >= 3 && p.primaryZone < g.zoneCount, "\(p)")
            #expect(!p.title.isEmpty && !p.summary.isEmpty)
            #expect((p.aspectLabel != nil) == (p.group == .ultrawide))
            for area in [CGRect(x: 0, y: 25, width: 1440, height: 875), CGRect(x: -5120, y: 0, width: 5120, height: 1415)] {
                let z = g.zones(in: area, spacing: 0)
                #expect(z.allSatisfy { area.contains($0) && $0.width >= 100 && $0.height >= 100 }, "\(p) in \(area)")
                for i in z.indices { for j in z.indices where j > i { #expect(z[i].intersection(z[j]).area == 0, "\(p)") } }
                #expect(abs(z.reduce(0) { $0 + $1.area } - area.area) < 1, "\(p) covers the area")
            }
            let l = p.makeLayout()
            #expect(l.kind == .customGrid && l.count == g.zoneCount && l.name == p.title && !l.isTemplate)
        }
        #expect(LayoutPreset.centerFocus.grid.columns.map { ($0 * 100).rounded() } == [25, 50, 25])
        #expect(LayoutPreset.thirds.grid == .columns(3))
        #expect(LayoutPreset.fiveColumns.grid.zoneCount == 5)
        // Vibecoding: editor above terminal on the left, preview in the middle, chat on the right.
        let v = LayoutPreset.vibecoding.grid.zones(in: screen, spacing: 0)
        #expect(v[0].minX == 0 && v[1].minX == 0 && v[0].maxY == v[1].minY)
        #expect(v[2].height == screen.height && v[3].maxX == screen.maxX)
    }

    @Test func adoptingAPresetReusesAnUntouchedCopy() {
        var lib = LayoutLibrary()
        let first = lib.adopt(.vibecoding)
        #expect(lib.custom.count == 1)
        #expect(lib.adopt(.vibecoding).id == first.id, "picking it again doesn't pile up copies")
        // Once edited, picking the preset makes a fresh copy with its own name.
        var edited = first
        edited.grid = first.grid?.splitting(zone: 2, vertical: false, at: 0.5)
        lib.update(edited)
        let second = lib.adopt(.vibecoding)
        #expect(second.id != first.id)
        #expect(second.name == "\(LayoutPreset.vibecoding.title) 2")
        #expect(lib.normalized().custom.count == 2, "preset layouts survive normalization")
        #expect(LayoutPreset.resolve("centerFocus") == .centerFocus)
        #expect(LayoutPreset.resolve(LayoutPreset.thirds.title.uppercased()) == .thirds)
        #expect(LayoutPreset.resolve("nope") == nil)
    }

    // MARK: Display identity

    @Test func displayKeysSurviveReconnects() {
        let builtIn = DisplayIdentity(displayID: 1, uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", hardwareID: "1552-41055-4251086178")
        let studio = DisplayIdentity(displayID: 2, uuid: "98253CF1-5A5E-4089-B0BB-13AE936453BD", hardwareID: "1552-44610-4071091802")
        let before = ZoneDisplay.keys(for: [builtIn, studio])
        // Unplugged and plugged in again: macOS hands out new display ids.
        var replugged = studio
        replugged.displayID = 7
        let after = ZoneDisplay.keys(for: [builtIn, replugged])
        #expect(before.map(\.key) == after.map(\.key))
        #expect(before[1].key == "98253CF1-5A5E-4089-B0BB-13AE936453BD")
        #expect(before[1].legacy == "1552-44610-4071091802", "the key earlier versions stored layouts under")
    }

    @Test func identicalMonitorsWithoutSerialsKeepTheirOwnKeys() {
        let left = DisplayIdentity(displayID: 3, uuid: "AAAA-1", hardwareID: "4268-41200-0")
        let right = DisplayIdentity(displayID: 4, uuid: "BBBB-2", hardwareID: "4268-41200-0")
        let keys = ZoneDisplay.keys(for: [left, right])
        #expect(keys.map(\.key) == ["AAAA-1", "BBBB-2"])
        #expect(keys.map(\.legacy) == ["4268-41200-0-3", "4268-41200-0-4"])
        // Reconnected with swapped display ids: the UUID keys follow the monitors.
        var l2 = left, r2 = right
        l2.displayID = 4
        r2.displayID = 3
        #expect(ZoneDisplay.keys(for: [l2, r2]).map(\.key) == ["AAAA-1", "BBBB-2"])
        // Without a UUID the hardware key stands in; a repeated UUID is told apart by position.
        let bare = DisplayIdentity(displayID: 9, uuid: nil, hardwareID: "1-2-3")
        #expect(ZoneDisplay.keys(for: [bare]).first?.key == "1-2-3")
        #expect(ZoneDisplay.keys(for: [bare]).first?.legacy == nil)
        let twins = ZoneDisplay.keys(for: [DisplayIdentity(displayID: 1, uuid: "U", hardwareID: "a"),
                                          DisplayIdentity(displayID: 2, uuid: "U", hardwareID: "b")])
        #expect(twins.map(\.key) == ["U", "U#2"])
    }

    @Test func layoutsSavedUnderTheOldKeyStillApply() {
        var lib = LayoutLibrary()
        let mine = ZoneLayout.newGrid(name: "Mine")
        lib.add(mine)
        lib.assignments["1552-44610-4071091802"] = mine.id          // written by an earlier version
        let found = lib.layout(forDisplay: "UUID-1", legacyKey: "1552-44610-4071091802", vertical: false,
                               defaultHorizontal: "columns", defaultVertical: "rows")
        #expect(found.id == mine.id)
        lib.assign("rows", toDisplay: "UUID-1", legacyKey: "1552-44610-4071091802")
        #expect(lib.assignments["UUID-1"] == "rows")
        #expect(lib.assignments["1552-44610-4071091802"] == "rows", "kept in step for the CLI and older versions")
        lib.assignments["1552-44610-4071091802"] = mine.id
        #expect(lib.layout(forDisplay: "UUID-1", legacyKey: "1552-44610-4071091802", vertical: false,
                           defaultHorizontal: "columns", defaultVertical: "rows").kind == .rows, "the UUID key wins")
        let d = ZoneDisplay(key: "UUID-1", name: "", number: 1, frame: screen, workArea: screen, isBuiltIn: false,
                            legacyKey: "1552-44610-4071091802")
        #expect(d.matches("UUID-1") && d.matches("1552-44610-4071091802") && !d.matches("other"))
    }

    // MARK: Auto Tiling

    private let leftScreen = ScreenSlot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        workArea: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let rightScreen = ScreenSlot(displayID: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                                         workArea: CGRect(x: 1440, y: 0, width: 2560, height: 1440))

    @Test func autoTilingGateBlocksOnlyItsDisplays() {
        let open = AutoTilingGate(screens: [leftScreen, rightScreen], manages: nil)
        #expect(open.isEmpty && !open.blocks(CGPoint(x: 2000, y: 500)))
        let gate = AutoTilingGate(screens: [leftScreen, rightScreen], manages: { $0 == 2 })
        #expect(gate.managed == [rightScreen.frame])
        #expect(gate.blocks(CGPoint(x: 2000, y: 500)))
        #expect(!gate.blocks(CGPoint(x: 700, y: 500)))
        #expect(gate.blocks(CGRect(x: 1500, y: 100, width: 1200, height: 800)), "a window on the managed display")
        #expect(!gate.blocks(CGRect(x: 600, y: 100, width: 1200, height: 600)), "mostly on the free display")
        #expect(!gate.blocks(CGRect.null))
        #expect(!AutoTilingGate.open.blocks(CGPoint(x: 2000, y: 500)))
    }

    @Test @MainActor func zoneEngineAsksAutoTilingEachTime() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let engine = ZoneEngine(settings: Persisted("fancyzones", default: FancyZonesSettings(), store: store),
                                library: Persisted(LayoutLibrary.storageID, default: LayoutLibrary(), store: store),
                                history: Persisted("history", default: [String: ZoneHistoryEntry](), store: store))
        var managed: Set<CGDirectDisplayID> = []
        engine.autoTilingManages = { { managed.contains($0) } }
        let screens = [leftScreen, rightScreen]
        #expect(engine.autoTilingGate(screens: screens).isEmpty)
        managed = [2]
        #expect(engine.autoTilingGate(screens: screens).blocks(CGPoint(x: 3000, y: 700)), "Auto Tiling took the display")
        managed = []
        #expect(!engine.autoTilingGate(screens: screens).blocks(CGPoint(x: 3000, y: 700)), "and gave it back")
        engine.autoTilingManages = { nil }
        #expect(engine.autoTilingGate(screens: screens) == .open, "Auto Tiling off")
    }
}
