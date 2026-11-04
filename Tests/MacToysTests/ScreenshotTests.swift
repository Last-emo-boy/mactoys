import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacToysCore
@testable import Screenshot

// MARK: - Helpers

/// A solid image (sRGB, premultiplied RGBA).
private func solidImage(width: Int, height: Int, gray: CGFloat = 1, alpha: CGFloat = 1) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: alpha))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// A black and white checkerboard of `cell`-pixel squares.
private func checkerboard(size: Int, cell: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in stride(from: 0, to: size, by: cell) {
        for x in stride(from: 0, to: size, by: cell) {
            let white = ((x / cell) + (y / cell)) % 2 == 0
            ctx.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
    return ctx.makeImage()!
}

/// RGBA of one pixel, `y` counted from the top.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let i = (y * w + x) * 4
    return Array(data[i..<i + 4])
}

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool { abs(a - b) <= tolerance }

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.001) -> Bool {
    close(a.minX, b.minX, tolerance) && close(a.minY, b.minY, tolerance)
        && close(a.width, b.width, tolerance) && close(a.height, b.height, tolerance)
}

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.001) -> Bool {
    close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance)
}

private let red = MarkupPalette.colors[0]
private let blue = MarkupPalette.colors[4]

/// Screenshot's tests, grouped by area (`swift test --filter ScreenshotTests`).
@Suite struct ScreenshotTests {}

// MARK: - Area selection

extension ScreenshotTests {
    @Suite struct AreaSelection {
        private let display = CGRect(x: 0, y: 0, width: 800, height: 600)

        @Test func dragIsNormalizedWhicheverWayYouGo() {
            let a = AreaGeometry.rect(anchor: CGPoint(x: 300, y: 200), current: CGPoint(x: 100, y: 50), square: false,
                                      fromCenter: false, in: display)
            let b = AreaGeometry.rect(anchor: CGPoint(x: 100, y: 50), current: CGPoint(x: 300, y: 200), square: false,
                                      fromCenter: false, in: display)
            #expect(a == CGRect(x: 100, y: 50, width: 200, height: 150))
            #expect(a == b)
        }

        @Test func dragStopsAtTheDisplayEdges() {
            let r = AreaGeometry.rect(anchor: CGPoint(x: 700, y: 500), current: CGPoint(x: 1200, y: -40), square: false,
                                      fromCenter: false, in: display)
            #expect(r == CGRect(x: 700, y: 0, width: 100, height: 500))
        }

        @Test func shiftMakesASquareFromTheShorterSide() {
            let down = AreaGeometry.rect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 300, y: 160), square: true,
                                         fromCenter: false, in: display)
            #expect(down == CGRect(x: 100, y: 100, width: 60, height: 60))
            let upLeft = AreaGeometry.rect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 40, y: 0), square: true,
                                           fromCenter: false, in: display)
            #expect(upLeft == CGRect(x: 40, y: 40, width: 60, height: 60))
            // Near the right edge the square is as big as the room left, never past the display.
            let edge = AreaGeometry.rect(anchor: CGPoint(x: 780, y: 100), current: CGPoint(x: 900, y: 400), square: true,
                                         fromCenter: false, in: display)
            #expect(edge == CGRect(x: 780, y: 100, width: 20, height: 20))
        }

        @Test func optionGrowsFromTheCenter() {
            let r = AreaGeometry.rect(anchor: CGPoint(x: 400, y: 300), current: CGPoint(x: 450, y: 340), square: false,
                                      fromCenter: true, in: display)
            #expect(r == CGRect(x: 350, y: 260, width: 100, height: 80))
            // The half that would leave the display limits that axis on both sides.
            let edge = AreaGeometry.rect(anchor: CGPoint(x: 30, y: 300), current: CGPoint(x: 100, y: 350), square: false,
                                         fromCenter: true, in: display)
            #expect(edge == CGRect(x: 0, y: 250, width: 60, height: 100))
            let square = AreaGeometry.rect(anchor: CGPoint(x: 400, y: 300), current: CGPoint(x: 500, y: 320), square: true,
                                           fromCenter: true, in: display)
            #expect(square == CGRect(x: 380, y: 280, width: 40, height: 40))
        }

        @Test func movingKeepsTheSizeAndStopsAtEdges() {
            let r = CGRect(x: 700, y: 500, width: 100, height: 80)
            #expect(AreaGeometry.moved(r, by: CGVector(dx: 50, dy: 50), in: display) == CGRect(x: 700, y: 520, width: 100, height: 80))
            #expect(AreaGeometry.moved(r, by: CGVector(dx: -900, dy: 0), in: display).minX == 0)
        }

        @Test func arrowKeysNudgeOrResize() {
            let r = CGRect(x: 10, y: 10, width: 100, height: 100)
            #expect(AreaGeometry.nudged(r, dx: 1, dy: 0, resize: false, in: display) == CGRect(x: 11, y: 10, width: 100, height: 100))
            #expect(AreaGeometry.nudged(r, dx: 0, dy: 10, resize: true, in: display) == CGRect(x: 10, y: 10, width: 100, height: 110))
            #expect(AreaGeometry.nudged(r, dx: -200, dy: 0, resize: true, in: display).width == AreaGeometry.minimumSide)
            #expect(AreaGeometry.nudged(r, dx: 5000, dy: 0, resize: true, in: display).maxX == display.maxX)
        }

        @Test func handlesAreFoundAndNeverFlipTheRect() {
            let r = CGRect(x: 0, y: 0, width: 200, height: 100)
            #expect(AreaGeometry.handle(at: CGPoint(x: 2, y: 3), of: r) == .topLeft)
            #expect(AreaGeometry.handle(at: CGPoint(x: 103, y: -2), of: r) == .top)
            #expect(AreaGeometry.handle(at: CGPoint(x: 199, y: 52), of: r) == .right)
            #expect(AreaGeometry.handle(at: CGPoint(x: 60, y: 60), of: r) == nil)

            let box = CGRect(x: 100, y: 100, width: 200, height: 100)
            let dragged = AreaGeometry.resized(box, handle: .topLeft, to: CGPoint(x: 400, y: 400), in: display)
            #expect(dragged == CGRect(x: 296, y: 196, width: 4, height: 4))
            let edge = AreaGeometry.resized(box, handle: .right, to: CGPoint(x: 1000, y: 0), in: display)
            #expect(edge == CGRect(x: 100, y: 100, width: 700, height: 100))
        }

        @Test func edgesSnapToWholeDevicePixels() {
            let r = CGRect(x: 10.3, y: 10.2, width: 100.4, height: 50.1)
            #expect(AreaGeometry.pixelRect(r, scale: 2) == CGRect(x: 21, y: 20, width: 200, height: 101))
            #expect(AreaGeometry.snapped(r, scale: 2) == CGRect(x: 10.5, y: 10, width: 100, height: 50.5))
            #expect(AreaGeometry.snapped(CGRect(x: 0.5, y: 0.4, width: 10, height: 10), scale: 1)
                        == CGRect(x: 1, y: 0, width: 10, height: 10))
            let size = AreaGeometry.pixelSize(r, scale: 2)
            #expect(size.width == 200 && size.height == 101)
        }

        @Test func clicksAreNotCaptures() {
            #expect(!AreaGeometry.isUsable(CGRect(x: 0, y: 0, width: 3, height: 300)))
            #expect(AreaGeometry.isUsable(CGRect(x: 0, y: 0, width: 4, height: 4)))
        }

        @Test func thePreviousAreaFitsAChangedDisplay() {
            let smaller = CGRect(x: 0, y: 0, width: 1440, height: 900)
            #expect(AreaGeometry.restored(CGRect(x: 1500, y: 900, width: 400, height: 300), in: smaller)
                        == CGRect(x: 1040, y: 600, width: 400, height: 300))
            #expect(AreaGeometry.restored(CGRect(x: 0, y: 0, width: 2000, height: 1200), in: smaller) == smaller)
            #expect(AreaGeometry.restored(CGRect(x: 10, y: 10, width: 2, height: 2), in: smaller) == nil)
        }

        @Test func theLoupeFlipsAwayFromEdges() {
            let size = CGSize(width: 120, height: 140)
            #expect(AreaGeometry.loupeOrigin(pointer: CGPoint(x: 100, y: 100), size: size, in: display) == CGPoint(x: 122, y: 122))
            let corner = AreaGeometry.loupeOrigin(pointer: CGPoint(x: 760, y: 560), size: size, in: display)
            #expect(corner == CGPoint(x: 760 - 22 - 120, y: 560 - 22 - 140))
        }
    }
}

// MARK: - Annotations

extension ScreenshotTests {
    @Suite struct Annotations {
        private func item(_ shape: MarkupItem.Shape, size: MarkupSize = .medium) -> MarkupItem {
            MarkupItem(shape: shape, color: red, size: size)
        }

        @Test func arrowsArePickedAlongTheirCurve() {
            let straight = item(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), bend: 0))
            #expect(straight.hit(CGPoint(x: 50, y: 4), tolerance: 4))
            #expect(!straight.hit(CGPoint(x: 50, y: 30), tolerance: 4))

            let curved = item(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), bend: 40))
            let middle = MarkupGeometry.bendHandle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), bend: 40)
            #expect(curved.hit(middle, tolerance: 4))
            #expect(!curved.hit(CGPoint(x: 50, y: 0), tolerance: 4))
        }

        @Test func theBendHandleRoundTrips() {
            let a = CGPoint(x: 20, y: 30), b = CGPoint(x: 220, y: 130)
            for bend: CGFloat in [-60, -5, 0, 12, 80] {
                let handle = MarkupGeometry.bendHandle(from: a, to: b, bend: bend)
                #expect(close(MarkupGeometry.bend(from: a, to: b, through: handle), bend))
            }
            // The curve passes through the handle at its middle.
            let curve = MarkupGeometry.arrowCurve(from: a, to: b, bend: 40, segments: 24)
            #expect(close(curve[12], MarkupGeometry.bendHandle(from: a, to: b, bend: 40)))
            #expect(MarkupGeometry.arrowCurve(from: a, to: b, bend: 0) == [a, b])
        }

        @Test func outlinesArePickedByTheirEdgeFillsAnywhere() {
            let r = CGRect(x: 100, y: 100, width: 200, height: 100)
            let outline = item(.rectangle(r, filled: false))
            #expect(outline.hit(CGPoint(x: 101, y: 150), tolerance: 4))
            #expect(!outline.hit(CGPoint(x: 200, y: 150), tolerance: 4))
            #expect(item(.rectangle(r, filled: true)).hit(CGPoint(x: 200, y: 150), tolerance: 4))

            let ring = item(.ellipse(r, filled: false))
            #expect(ring.hit(CGPoint(x: 200, y: 101), tolerance: 4))
            #expect(!ring.hit(CGPoint(x: 200, y: 150), tolerance: 4))
            #expect(item(.ellipse(r, filled: true)).hit(CGPoint(x: 200, y: 150), tolerance: 4))
            #expect(!item(.ellipse(r, filled: true)).hit(CGPoint(x: 102, y: 102), tolerance: 0))

            #expect(item(.pixelate(r)).hit(CGPoint(x: 200, y: 150), tolerance: 0))
            #expect(item(.counter(center: CGPoint(x: 50, y: 50), number: 1)).hit(CGPoint(x: 60, y: 50), tolerance: 2))
            #expect(!item(.counter(center: CGPoint(x: 50, y: 50), number: 1)).hit(CGPoint(x: 90, y: 50), tolerance: 2))
            #expect(item(.pencil([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)])).hit(CGPoint(x: 26, y: 24), tolerance: 2))
        }

        @Test func everyShapeMoves() {
            let d = CGVector(dx: 10, dy: -5)
            let r = CGRect(x: 0, y: 20, width: 30, height: 40)
            let shapes: [MarkupItem.Shape] = [
                .arrow(from: .zero, to: CGPoint(x: 40, y: 40), bend: 9), .line(from: .zero, to: CGPoint(x: 5, y: 5)),
                .rectangle(r, filled: true), .ellipse(r, filled: false), .blur(r), .pixelate(r), .spotlight(r, oval: true),
                .text(MarkupText(origin: CGPoint(x: 3, y: 4), string: "Hi", style: .solid)),
                .highlighter([.zero, CGPoint(x: 9, y: 0)]), .pencil([.zero, CGPoint(x: 1, y: 1)]),
                .counter(center: CGPoint(x: 7, y: 7), number: 3),
            ]
            for shape in shapes {
                let original = item(shape)
                let moved = original.moved(by: d)
                #expect(moved.id == original.id && moved.color == original.color)
                #expect(close(moved.bounds, original.bounds.offsetBy(dx: d.dx, dy: d.dy)), "\(shape)")
            }
        }

        @Test func handlesDragTheirPart() {
            let arrow = item(.arrow(from: .zero, to: CGPoint(x: 100, y: 0), bend: 0))
            #expect(arrow.handles == [.start, .end, .bend])
            guard case .arrow(let a, let b, _) = arrow.dragging(.end, to: CGPoint(x: 50, y: 80), in: .infinite).shape else {
                Issue.record("not an arrow")
                return
            }
            #expect(a == .zero && b == CGPoint(x: 50, y: 80))
            guard case .arrow(_, _, let bend) = arrow.dragging(.bend, to: CGPoint(x: 50, y: -30), in: .infinite).shape else {
                Issue.record("not an arrow")
                return
            }
            #expect(close(abs(bend), 30))

            let box = item(.rectangle(CGRect(x: 10, y: 10, width: 100, height: 50), filled: false))
            #expect(box.handles.count == 8)
            #expect(box.handle(at: CGPoint(x: 111, y: 61), radius: 6) == .box(.bottomRight))
            let resized = box.dragging(.box(.bottomRight), to: CGPoint(x: 210, y: 110), in: CGRect(x: 0, y: 0, width: 500, height: 500))
            #expect(resized.box == CGRect(x: 10, y: 10, width: 200, height: 100))
            #expect(item(.counter(center: .zero, number: 1)).handles.isEmpty)
        }

        @Test func strayClicksAreDropped() {
            #expect(item(.arrow(from: .zero, to: CGPoint(x: 2, y: 2), bend: 0)).isDegenerate)
            #expect(!item(.arrow(from: .zero, to: CGPoint(x: 20, y: 2), bend: 0)).isDegenerate)
            #expect(item(.rectangle(CGRect(x: 0, y: 0, width: 50, height: 2), filled: false)).isDegenerate)
            #expect(item(.pencil([.zero])).isDegenerate)
            #expect(item(.text(MarkupText(origin: .zero, string: "  \n", style: .plain))).isDegenerate)
            #expect(!item(.counter(center: .zero, number: 1)).isDegenerate)
        }

        @Test func pencilStrokesAreThinned() {
            let pts = (0...100).map { CGPoint(x: CGFloat($0) * 0.5, y: 0) }
            let thin = MarkupGeometry.thinned(pts, spacing: 5)
            #expect(thin.first == pts.first && thin.last == pts.last)
            #expect(thin.count == 11)
        }

        @Test func toolKeysAreUnique() {
            let keys = MarkupTool.allCases.map(\.key)
            #expect(Set(keys).count == keys.count)
            #expect(MarkupTool.forKey("a") == .arrow && MarkupTool.forKey("x") == .pixelate && MarkupTool.forKey("q") == nil)
            #expect(!MarkupTool.select.draws && !MarkupTool.crop.draws && MarkupTool.text.draws)
        }

        @Test func shiftSnapsTo45Degrees() {
            let flat = MarkupCanvasView.snapped(CGPoint(x: 100, y: 10), from: .zero)
            #expect(close(flat.y, 0) && close(flat.x, hypot(100, 10)))
            let diagonal = MarkupCanvasView.snapped(CGPoint(x: 100, y: 90), from: .zero)
            #expect(close(diagonal.x, diagonal.y))
        }
    }
}

// MARK: - Document and undo

extension ScreenshotTests {
    @Suite struct Documents {
        @Test func undoRedoAndNewChangesForgetTheFuture() {
            var stack = UndoStack<Int>()
            #expect(!stack.canUndo && stack.undo(from: 0) == nil)
            stack.record(0)
            stack.record(0)  // the same state twice is one step
            stack.record(1)
            #expect(stack.past == [0, 1])
            #expect(stack.undo(from: 2) == 1)
            #expect(stack.undo(from: 1) == 0)
            #expect(stack.canRedo)
            #expect(stack.redo(from: 0) == 1)
            stack.record(1)
            #expect(!stack.canRedo)
        }

        @Test func undoIsBounded() {
            var stack = UndoStack<Int>(limit: 3)
            for i in 0..<10 { stack.record(i) }
            #expect(stack.past == [7, 8, 9])
        }

        @Test func documentsRoundTripThroughJSON() throws {
            var doc = MarkupDocument(imageSize: CGSize(width: 640, height: 400), scale: 2)
            doc.items = [
                MarkupItem(shape: .arrow(from: .zero, to: CGPoint(x: 10, y: 10), bend: 4), color: red, size: .large),
                MarkupItem(shape: .line(from: .zero, to: CGPoint(x: 5, y: 9)), color: blue, size: .small),
                MarkupItem(shape: .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4), filled: true), color: red, size: .medium),
                MarkupItem(shape: .ellipse(CGRect(x: 1, y: 2, width: 30, height: 40), filled: false), color: red, size: .medium),
                MarkupItem(shape: .text(MarkupText(origin: CGPoint(x: 8, y: 9), string: "Ünïcode ✓", style: .soft)), color: red,
                           size: .extraLarge),
                MarkupItem(shape: .highlighter([.zero, CGPoint(x: 1, y: 1)]), color: red, size: .medium),
                MarkupItem(shape: .pencil([.zero, CGPoint(x: 2, y: 2)]), color: red, size: .medium),
                MarkupItem(shape: .counter(center: CGPoint(x: 3, y: 3), number: 7), color: red, size: .medium),
                MarkupItem(shape: .blur(CGRect(x: 0, y: 0, width: 50, height: 50)), color: red, size: .medium),
                MarkupItem(shape: .pixelate(CGRect(x: 0, y: 0, width: 50, height: 50)), color: red, size: .medium),
                MarkupItem(shape: .spotlight(CGRect(x: 0, y: 0, width: 50, height: 50), oval: true), color: red, size: .medium),
            ]
            doc.crop = CGRect(x: 10, y: 10, width: 300, height: 200)
            var style = BeautifyStyle()
            style.backdrop = .solid(blue)
            style.aspect = .fourThree
            style.alignment = .bottomRight
            doc.beautify = style
            let back = try JSONDecoder().decode(MarkupDocument.self, from: JSONEncoder().encode(doc))
            #expect(back == doc)
            #expect(back.isEdited)
            #expect(!MarkupDocument(imageSize: CGSize(width: 1, height: 1), scale: 1).isEdited)
        }

        @Test func countersNumberOnAndTheTopmostItemWins() {
            var doc = MarkupDocument(imageSize: CGSize(width: 200, height: 200), scale: 1)
            #expect(doc.nextCounter == 1)
            let under = MarkupItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100), filled: true), color: red, size: .medium)
            let over = MarkupItem(shape: .counter(center: CGPoint(x: 50, y: 50), number: 4), color: blue, size: .medium)
            doc.items = [under, over]
            #expect(doc.nextCounter == 5)
            #expect(doc.item(at: CGPoint(x: 50, y: 50), tolerance: 2)?.id == over.id)
            #expect(doc.item(at: CGPoint(x: 90, y: 90), tolerance: 2)?.id == under.id)
            #expect(doc.item(at: CGPoint(x: 150, y: 150), tolerance: 2) == nil)
        }

        @Test func theCropStaysInsideTheImage() {
            var doc = MarkupDocument(imageSize: CGSize(width: 200, height: 100), scale: 2)
            #expect(doc.contentRect == doc.imageBounds)
            doc.crop = CGRect(x: 150, y: 50, width: 100, height: 100)
            #expect(doc.contentRect == CGRect(x: 150, y: 50, width: 50, height: 50))
        }

        @MainActor @Test func annotateUndoesWholeGestures() {
            let item = CaptureItem(image: solidImage(width: 200, height: 100), scale: 2, kind: .area)
            let model = AnnotateModel(item: item, settings: ScreenshotSettings())
            #expect(!model.canUndo)

            let box = MarkupItem(shape: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20), filled: false), color: red, size: .medium)
            model.apply { $0.items.append(box) }
            #expect(model.canUndo && item.document.items.count == 1)

            // A drag is one undo step however many updates it makes.
            model.beginGesture()
            for dx in 1...5 { model.update(box.id) { $0 = box.moved(by: CGVector(dx: CGFloat(dx), dy: 0)) } }
            model.endGesture()
            model.undo()
            #expect(model.document.items.first?.box == box.box)
            model.undo()
            #expect(model.document.items.isEmpty && !model.canUndo)
            model.redo()
            #expect(model.document.items.count == 1 && model.canRedo)

            // A gesture that changes nothing records nothing; a cancelled one is rolled back.
            model.beginGesture()
            model.endGesture()
            model.beginGesture()
            model.apply { _ in }
            model.update(box.id) { $0.color = blue }
            model.cancelGesture()
            #expect(model.document.items.first?.color == red)
        }

        @MainActor @Test func annotatePaletteAppliesToTheSelection() {
            let item = CaptureItem(image: solidImage(width: 200, height: 100), scale: 1, kind: .area)
            let model = AnnotateModel(item: item, settings: ScreenshotSettings())
            let counter = MarkupItem(shape: .counter(center: CGPoint(x: 20, y: 20), number: 1), color: red, size: .medium)
            model.apply { $0.items.append(counter) }
            model.selection = counter.id
            model.setColor(blue)
            #expect(model.document.items.first?.color == blue)
            model.duplicateSelection()
            #expect(model.document.items.count == 2)
            guard case .counter(let c, let n) = model.document.items.last?.shape else {
                Issue.record("not a counter")
                return
            }
            #expect(n == 2 && c == CGPoint(x: 32, y: 32))
            model.deleteSelection()
            #expect(model.document.items.count == 1 && model.selection == nil)
        }

        @MainActor @Test func cropAppliesWhenLeavingTheTool() {
            let item = CaptureItem(image: solidImage(width: 400, height: 200), scale: 2, kind: .area)
            let model = AnnotateModel(item: item, settings: ScreenshotSettings())
            model.selectTool(.crop)
            #expect(model.cropDraft == model.document.imageBounds)
            model.cropDraft = CGRect(x: 10.4, y: 10.6, width: 100, height: 50)
            model.selectTool(.pencil)
            #expect(model.document.crop == CGRect(x: 10, y: 10, width: 101, height: 51))
            // Cropping to everything means no crop.
            model.selectTool(.crop)
            model.cropDraft = CGRect(x: -20, y: -20, width: 999, height: 999)
            model.applyCrop()
            #expect(model.document.crop == nil && model.tool == .pencil)
        }

        @MainActor @Test func backgroundSliderDragsUndoAsOneStep() {
            let item = CaptureItem(image: solidImage(width: 100, height: 100), scale: 1, kind: .window)
            let model = AnnotateModel(item: item, settings: ScreenshotSettings())
            model.toggleBeautify()
            #expect(model.document.beautify != nil && model.showsBeautify)
            model.editBeautify { $0.padding = 10 }
            model.editBeautify { $0.padding = 20 }
            model.editBeautify { $0.padding = 30 }
            #expect(model.document.beautify?.padding == 30)
            model.undo()
            #expect(model.document.beautify?.padding == ScreenshotSettings().beautify.padding)
            model.undo()
            #expect(model.document.beautify == nil && !model.showsBeautify)
        }

        @Test func canvasMappingRoundTrips() {
            var doc = MarkupDocument(imageSize: CGSize(width: 800, height: 600), scale: 2)
            let small = CanvasGeometry(viewSize: CGSize(width: 1000, height: 800), document: doc, showsWholeImage: false)
            #expect(small.zoom == 1)  // never enlarged
            #expect(small.canvasRect == CGRect(x: 100, y: 100, width: 800, height: 600))

            doc.beautify = BeautifyStyle()
            doc.crop = CGRect(x: 100, y: 50, width: 400, height: 300)
            let g = CanvasGeometry(viewSize: CGSize(width: 300, height: 260), document: doc, showsWholeImage: false)
            #expect(g.zoom < 1)
            for p in [CGPoint(x: 100, y: 50), CGPoint(x: 333, y: 222), CGPoint(x: 500, y: 350)] {
                #expect(close(g.image(g.view(p)), p))
            }
            // The crop's corner sits where the frame's padding ends.
            let corner = g.view(CGPoint(x: 100, y: 50))
            #expect(close(corner.x, g.canvasRect.minX + (g.layout?.content.minX ?? 0) * g.zoom))
            // The crop tool shows the whole image without the frame.
            let crop = CanvasGeometry(viewSize: CGSize(width: 1000, height: 800), document: doc, showsWholeImage: true)
            #expect(crop.layout == nil && crop.visibleImageRect == doc.imageBounds)
        }
    }
}

// MARK: - Redaction

extension ScreenshotTests {
    @Suite struct Redacting {
        @Test func regionsCoverWholePixelsInsideTheImage() {
            let px = Redaction.pixelRect(CGRect(x: 10.2, y: 10.7, width: 20, height: 5), scale: 2,
                                         imagePixels: CGSize(width: 100, height: 100))
            #expect(px == CGRect(x: 20, y: 21, width: 41, height: 11))
            #expect(Redaction.pixelRect(CGRect(x: 40, y: 40, width: 100, height: 100), scale: 2,
                                        imagePixels: CGSize(width: 100, height: 100)) == CGRect(x: 80, y: 80, width: 20, height: 20))
            #expect(Redaction.pixelRect(CGRect(x: 200, y: 0, width: 10, height: 10), scale: 1,
                                        imagePixels: CGSize(width: 100, height: 100)).isNull)
        }

        @Test func mosaicCellsAreBigEnoughToHideText() {
            // At least 10 points, so a line of text never stays readable…
            #expect(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 400, height: 40), scale: 2) == 20)
            // …about a twelfth of a big region…
            #expect(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 600, height: 600), scale: 1) == 50)
            // …and never more than half of a tiny one.
            #expect(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 6, height: 6), scale: 2) == 3)
            #expect(Redaction.blurRadius(for: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 2) == 16)
            let grid = Redaction.grid(width: 10, height: 9, block: 4)
            #expect(grid.columns == 3 && grid.rows == 3)
        }

        @Test func pixelateAveragesEachCell() {
            // 4×2 pixels, two 2×2 cells.
            var buffer: [UInt8] = [
                0, 0, 0, 255, 100, 100, 100, 255, 10, 10, 10, 255, 10, 10, 10, 255,
                200, 200, 200, 255, 100, 100, 100, 255, 30, 30, 30, 255, 30, 30, 30, 255,
            ]
            Redaction.pixelate(&buffer, width: 4, height: 2, block: 2)
            #expect(Array(buffer[0..<4]) == [100, 100, 100, 255])
            #expect(Array(buffer[20..<24]) == [100, 100, 100, 255])
            #expect(Array(buffer[8..<12]) == [20, 20, 20, 255])
            #expect(Array(buffer[28..<32]) == [20, 20, 20, 255])
        }

        @Test func pixelatedImagesLoseTheirDetail() throws {
            let board = checkerboard(size: 16, cell: 1)
            let out = try #require(Redaction.pixelated(board, region: CGRect(x: 0, y: 0, width: 16, height: 16), block: 4))
            #expect(out.width == 16 && out.height == 16)
            let a = pixel(out, 0, 0), b = pixel(out, 1, 0), c = pixel(out, 13, 9)
            #expect(a == b && b == c)
            #expect((120...135).contains(a[0]))
        }
    }
}

// MARK: - Background frame

extension ScreenshotTests {
    @Suite struct BackgroundFrame {
        private let content = CGSize(width: 400, height: 300)

        private func style(padding: Double = 50, aspect: AspectPreset = .auto, alignment: BeautifyAlignment = .center) -> BeautifyStyle {
            var s = BeautifyStyle()
            s.padding = padding
            s.aspect = aspect
            s.alignment = alignment
            return s
        }

        @Test func paddingSurroundsTheCapture() {
            let layout = BeautifyLayout.make(content: content, style: style(), scale: 2)
            #expect(layout.canvas == CGSize(width: 500, height: 400))
            #expect(layout.content == CGRect(x: 50, y: 50, width: 400, height: 300))
            #expect(layout.pixelSize.width == 1000 && layout.pixelSize.height == 800)
        }

        @Test func aspectPresetsAddRoomOnOneAxis() {
            let wide = BeautifyLayout.make(content: content, style: style(aspect: .sixteenNine), scale: 1)
            #expect(close(wide.canvas.width / wide.canvas.height, 16.0 / 9.0))
            #expect(wide.canvas.height == 400)
            #expect(close(wide.content.midX, wide.canvas.width / 2))

            let square = BeautifyLayout.make(content: CGSize(width: 400, height: 100), style: style(aspect: .square), scale: 1)
            #expect(square.canvas == CGSize(width: 500, height: 500))
            #expect(square.content.minY == 200)
        }

        @Test func alignmentPlacesTheCaptureInTheFreeSpace() {
            let topLeft = BeautifyLayout.make(content: content, style: style(aspect: .sixteenNine, alignment: .topLeft), scale: 1)
            #expect(topLeft.content.origin == CGPoint(x: 50, y: 50))
            let right = BeautifyLayout.make(content: content, style: style(aspect: .sixteenNine, alignment: .bottomRight), scale: 1)
            #expect(close(right.content.maxX, right.canvas.width - 50))
            #expect(right.content.maxY == right.canvas.height - 50)
        }

        @Test func cornersNeverExceedHalfTheShortSide() {
            var s = style()
            s.cornerRadius = 999
            #expect(BeautifyLayout.make(content: CGSize(width: 40, height: 20), style: s, scale: 1).cornerRadius == 10)
            s.cornerRadius = -3
            #expect(BeautifyLayout.make(content: content, style: s, scale: 1).cornerRadius == 0)
        }

        @Test func xPostImagesAre1200By675() {
            let layout = BeautifyLayout.make(content: CGSize(width: 1800, height: 300), style: style(aspect: .xPost), scale: 2)
            #expect(layout.pixelSize.width == 1200 && layout.pixelSize.height == 675)
        }

        @Test func shadowStrengthIsClamped() {
            #expect(BeautifyLayout.shadow(strength: -1).alpha == 0)
            #expect(BeautifyLayout.shadow(strength: 7) == BeautifyLayout.shadow(strength: 1))
        }

        @Test func framedImagesMatchTheirLayout() throws {
            let capture = solidImage(width: 200, height: 100, gray: 0.5)
            var s = style(padding: 20)
            s.backdrop = .solid(RGBA(red: 1, green: 0, blue: 0))
            s.shadow = 0
            s.cornerRadius = 0
            let out = try #require(Beautifier.render(capture, size: CGSize(width: 100, height: 50), style: s, scale: 2))
            #expect(out.width == 280 && out.height == 180)
            #expect(pixel(out, 5, 5) == [255, 0, 0, 255])        // backdrop
            #expect(pixel(out, 140, 90)[0] == pixel(out, 140, 90)[1])  // capture (gray)
            // Every preset paints without failing.
            for preset in BackdropPreset.allCases {
                s.backdrop = .preset(preset)
                #expect(Beautifier.render(capture, size: CGSize(width: 100, height: 50), style: s, scale: 2) != nil)
            }
        }
    }
}

// MARK: - Rendering

extension ScreenshotTests {
    @Suite struct Rendering {
        @Test func annotationsLandWhereTheyWereDrawn() throws {
            // Image points have a top-left origin: a box at the top-left must paint the top-left pixels.
            let base = solidImage(width: 80, height: 60)
            var doc = MarkupDocument(imageSize: CGSize(width: 40, height: 30), scale: 2)
            doc.items = [MarkupItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), filled: true),
                                    color: RGBA(red: 0, green: 0, blue: 1), size: .medium)]
            let out = try #require(Compositor.render(base: base, document: doc, redactions: nil))
            #expect(out.width == 80 && out.height == 60)
            #expect(pixel(out, 6, 6) == [0, 0, 255, 255])
            #expect(pixel(out, 70, 50) == [255, 255, 255, 255])
        }

        @Test func cropAndRetinaSetTheOutputSize() throws {
            let base = solidImage(width: 400, height: 200)
            var doc = MarkupDocument(imageSize: CGSize(width: 200, height: 100), scale: 2)
            doc.crop = CGRect(x: 10, y: 10, width: 50, height: 40)
            let cropped = try #require(Compositor.render(base: base, document: doc, redactions: nil))
            #expect(cropped.width == 100 && cropped.height == 80)
            let oneX = try #require(Compositor.render(base: base, document: doc, redactions: nil, retina: false))
            #expect(oneX.width == 50 && oneX.height == 40)
            doc.beautify = BeautifyStyle()
            doc.beautify?.padding = 10
            let framed = try #require(Compositor.render(base: base, document: doc, redactions: nil))
            #expect(framed.width == 140 && framed.height == 120)
        }

        @MainActor @Test func itemsCacheTheirRenderingUntilEdited() {
            let item = CaptureItem(image: solidImage(width: 100, height: 100), scale: 2, kind: .area)
            #expect(item.pointSize == CGSize(width: 50, height: 50))
            let first = item.rendered
            #expect(item.rendered === first)
            item.document.crop = CGRect(x: 0, y: 0, width: 20, height: 10)
            #expect(item.rendered !== first)
            #expect(item.pointSize == CGSize(width: 20, height: 10))
            #expect(item.outputScale(retina: false) == 1 && item.outputScale(retina: true) == 2)
            item.document.beautify = BeautifyStyle()
            item.document.beautify?.aspect = .xPost
            #expect(item.output(retina: true).width == 1200)
            #expect(item.outputScale(retina: true) == 1)
        }

        @Test func windowsGetRoomForTheirShadow() throws {
            let layout = WindowFramer.layout(window: CGSize(width: 300, height: 200), shadow: true, padding: 10)
            let m = WindowFramer.shadowMargin + 10
            #expect(layout.canvas == CGSize(width: 300 + m * 2, height: 200 + m * 2))
            #expect(layout.window == CGRect(x: m, y: m, width: 300, height: 200))
            let image = solidImage(width: 60, height: 40)
            #expect(WindowFramer.compose(image, scale: 2, shadow: false, padding: 0) === image)
            let framed = try #require(WindowFramer.compose(image, scale: 2, shadow: true, padding: 0))
            #expect(framed.width == 60 + Int(WindowFramer.shadowMargin) * 4)
            #expect(pixel(framed, 0, 0)[3] == 0)  // transparent corner
        }

        @Test func recognizedLinesReadTopToBottomThenLeftToRight() {
            // Vision's boxes are normalized with a bottom-left origin.
            let lines: [(CGRect, String)] = [
                (CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05), "last"),
                (CGRect(x: 0.6, y: 0.81, width: 0.3, height: 0.05), "second"),
                (CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05), "first"),
                (CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05), "middle"),
            ]
            #expect(TextReader.order(lines) == ["first", "second", "middle", "last"])
        }
    }
}

// MARK: - Files, history and settings

extension ScreenshotTests {
    @Suite struct FilesAndHistory {
        private var calendar: Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }

        private var date: Date { Date(timeIntervalSince1970: 1_793_831_797) }  // 2026-11-04 22:36:37 UTC

        @Test func filesAreNamedFromTheTemplate() {
            let name = FileNamer.name(template: FileNamer.defaultTemplate, date: date, format: .png, calendar: calendar,
                                      locale: Locale(identifier: "en_US"))
            #expect(name == "Screenshot 2026-11-04 at 22.36.37.png")
            #expect(FileNamer.name(template: "$MMMM $D", date: date, format: .jpeg, calendar: calendar,
                                   locale: Locale(identifier: "en_US")) == "November 4.jpg")
        }

        @Test func takenNamesGetANumber() {
            let taken: Set = ["Shot.png", "Shot 2.png"]
            #expect(FileNamer.name(template: "Shot", date: date, format: .png, calendar: calendar) { taken.contains($0) } == "Shot 3.png")
            #expect(FileNamer.name(template: "Shot", date: date, format: .heic, calendar: calendar) { taken.contains($0) } == "Shot.heic")
        }

        @Test func namesAreSafeForFinder() {
            #expect(FileNamer.sanitized("a/b:c") == "a-b.c")
            #expect(FileNamer.sanitized("..hidden") == "hidden")
            #expect(FileNamer.sanitized("  \t ") == "Screenshot")
            #expect(FileNamer.sanitized("tab\u{0007}bell") == "tabbell")
            #expect(FileNamer.sanitized(String(repeating: "x", count: 300)).count == 200)
        }

        @Test func formatsKnowTheirFiles() {
            #expect(ImageFormat.jpeg.fileExtension == "jpg" && ImageFormat.jpeg.isLossy)
            #expect(!ImageFormat.png.isLossy && ImageFormat.heic.typeIdentifier == "public.heic")
        }

        @Test func pngKeepsAlphaAndJPEGIsFlattened() throws {
            let image = solidImage(width: 30, height: 20, gray: 0.2, alpha: 0.5)
            let png = try ImageEncoder.data(image, format: .png, quality: 1, scale: 2)
            let pngSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
            #expect(decoded.width == 30 && decoded.height == 20 && ImageEncoder.hasAlpha(decoded))
            let props = CGImageSourceCopyPropertiesAtIndex(pngSource, 0, nil) as? [CFString: Any]
            #expect((props?[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 144)

            let jpeg = try ImageEncoder.data(image, format: .jpeg, quality: 0.8)
            let jpegSource = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let flat = try #require(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
            #expect(!ImageEncoder.hasAlpha(flat))
            // Half-transparent dark gray over white.
            #expect((130...160).contains(pixel(flat, 15, 10)[0]))
        }

        @Test func savedFilesReopenAtTheirScale() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-tests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            var settings = ScreenshotSettings()
            settings.fileNameTemplate = "Capture"
            let image = solidImage(width: 40, height: 20)
            let first = try ImageEncoder.save(image, to: folder, settings: settings, scale: 2)
            let second = try ImageEncoder.save(image, to: folder, settings: settings, scale: 2)
            #expect(first.lastPathComponent == "Capture.png" && second.lastPathComponent == "Capture 2.png")
            let loaded = try #require(CaptureTransfer.load(first))
            #expect(loaded.0.width == 40 && loaded.1 == 2)
        }

        private func entry(_ hoursAgo: Double, bytes: Int64, now: Date) -> HistoryEntry {
            HistoryEntry(id: UUID(), date: now.addingTimeInterval(-hoursAgo * 3600), kind: .area, pixelWidth: 10, pixelHeight: 10,
                         scale: 2, bytes: bytes, savedPath: nil)
        }

        @Test func historyDropsOldEntriesFirst() {
            let now = Date()
            let a = entry(1, bytes: 400, now: now), b = entry(5, bytes: 400, now: now), c = entry(30, bytes: 400, now: now)
            #expect(HistoryPruner.toRemove([a, b, c], limitBytes: 1000, maxAgeDays: 0, now: now) == [c.id])
            #expect(HistoryPruner.toRemove([c, a, b], limitBytes: 500, maxAgeDays: 0, now: now) == [b.id, c.id])
            #expect(HistoryPruner.toRemove([a, b, c], limitBytes: 10_000, maxAgeDays: 1, now: now) == [c.id])
            #expect(HistoryPruner.toRemove([a, b], limitBytes: 10_000, maxAgeDays: 0, now: now).isEmpty)
        }

        @Test func theNewestCaptureAlwaysStays() {
            let now = Date()
            let huge = entry(0, bytes: 9_000_000, now: now), old = entry(2, bytes: 10, now: now)
            #expect(HistoryPruner.toRemove([old, huge], limitBytes: 1000, maxAgeDays: 0, now: now) == [old.id])
        }

        @MainActor @Test func historyReadsItsIndex() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-history-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let entries = [entry(0, bytes: 100, now: now), entry(1, bytes: 250, now: now)]
            try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"))
            let history = CaptureHistory(directory: folder)
            #expect(history.entries == entries && history.totalBytes == 350)
            history.delete(entries[0].id)
            #expect(history.entries == [entries[1]])
            #expect(CaptureHistory(directory: folder.appendingPathComponent("empty")).entries.isEmpty)
        }

        @Test func thumbnailsAreSmall() throws {
            let big = solidImage(width: 1600, height: 400)
            let thumb = try #require(CaptureHistory.thumbnail(big))
            #expect(thumb.width == 640 && thumb.height == 160)
            let small = solidImage(width: 100, height: 50)
            #expect(CaptureHistory.thumbnail(small) === small)
        }
    }
}

extension ScreenshotTests {
    @Suite struct SettingsAndLayout {
        @Test func onlyTheAreaShortcutIsAssigned() {
            let s = ScreenshotSettings()
            #expect(s.areaShortcut == Shortcut(kVK_ANSI_A, [.control, .option]))
            #expect(s.windowShortcut == nil && s.screenShortcut == nil && s.previousAreaShortcut == nil && s.historyShortcut == nil)
            #expect(s.showQuickAccess && s.saveToFile && !s.copyToClipboard && s.keepHistory)
            #expect(s.fileNameTemplate == FileNamer.defaultTemplate)
        }

        @Test func settingsRoundTripAndKeepClearedShortcuts() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = SettingsStore(directory: folder)
            var s = ScreenshotSettings()
            s.areaShortcut = nil
            s.windowShortcut = Shortcut(kVK_ANSI_W, [.control, .option])
            s.format = .jpeg
            s.beautify.backdrop = .preset(.meadow)
            s.overlayCorner = .topRight
            store.save(s, id: "screenshot", defaults: ScreenshotSettings())
            let back = store.load("screenshot", default: ScreenshotSettings())
            #expect(back == s)
            #expect(back.areaShortcut == nil)
        }

        @Test func olderSettingsFilesKeepNewDefaults() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = SettingsStore(directory: folder)
            try #"{"format":"heic","historyLimitMB":50}"#.data(using: .utf8)!.write(to: store.url(for: "screenshot"))
            let s = store.load("screenshot", default: ScreenshotSettings())
            #expect(s.format == .heic && s.historyLimitMB == 50)
            #expect(s.areaShortcut == ScreenshotSettings().areaShortcut && s.beautify == BeautifyStyle())
        }

        @Test func autoBeautifyAndCorners() {
            #expect(!AutoBeautify.off.applies(to: .window))
            #expect(AutoBeautify.windows.applies(to: .window) && !AutoBeautify.windows.applies(to: .area))
            #expect(AutoBeautify.all.applies(to: .screen))
            #expect(OverlayCorner.topLeft.isTop && OverlayCorner.topLeft.isLeft && !OverlayCorner.bottomRight.isLeft)
        }

        @Test func quickAccessCardsKeepASensibleShape() {
            #expect(QuickAccessLayout.cardSize(image: CGSize(width: 1600, height: 1000), width: 216) == CGSize(width: 216, height: 135))
            #expect(QuickAccessLayout.cardSize(image: CGSize(width: 2000, height: 40), width: 200).height == 100)
            #expect(QuickAccessLayout.cardSize(image: CGSize(width: 40, height: 2000), width: 200).height == 210)
        }

        @Test func quickAccessCardsStackFromTheCorner() {
            let visible = CGRect(x: 0, y: 0, width: 1440, height: 400)
            let sizes = [CGSize(width: 200, height: 150), CGSize(width: 200, height: 100), CGSize(width: 200, height: 200)]
            let up = QuickAccessLayout.frames(sizes: sizes, corner: .bottomLeft, in: visible)
            #expect(up.count == 2)  // the third doesn't fit
            #expect(up[0] == CGRect(x: 18, y: 18, width: 200, height: 150))
            #expect(up[1].minY == up[0].maxY + QuickAccessLayout.spacing)
            let down = QuickAccessLayout.frames(sizes: sizes, corner: .topRight, in: visible)
            #expect(down[0] == CGRect(x: 1440 - 18 - 200, y: 400 - 18 - 150, width: 200, height: 150))
            #expect(down[1].maxY == down[0].minY - QuickAccessLayout.spacing)
        }
    }
}
