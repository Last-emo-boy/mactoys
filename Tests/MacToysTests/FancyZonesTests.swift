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
}
