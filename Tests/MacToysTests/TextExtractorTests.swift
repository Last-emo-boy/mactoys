import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TextExtractor

@Suite struct TextExtractorTests {
    private func box(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 60, _ h: CGFloat = 20) -> TextBox {
        TextBox(text, CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func groupsBoxesIntoLinesInReadingOrder() {
        let boxes = [
            box("world", 80, 2),          // same line, slightly lower
            box("second line", 0, 40, 120),
            box("Hello", 0, 0),
            box("third", 0, 80),
        ]
        #expect(TextLayout.lines(boxes) == "Hello world\nsecond line\nthird")
        #expect(TextLayout.rows(boxes).map { $0.map(\.text) } == [["Hello", "world"], ["second line"], ["third"]])
    }

    @Test func singleLineRejoinsHyphenationAndCJK() {
        let boxes = [box("Optical char-", 0, 0, 150), box("acter recognition", 0, 30, 180), box("is fun", 0, 60)]
        #expect(TextLayout.singleLine(boxes) == "Optical character recognition is fun")
        #expect(TextLayout.join("你好", "世界") == "你好世界")
        #expect(TextLayout.join("東京", "Tokyo") == "東京 Tokyo")
        #expect(TextLayout.join("well-", "Known", rejoinHyphen: true) == "well- Known")
        #expect(TextLayout.join("", "x") == "x")
    }

    @Test func tableClustersRowsAndColumns() {
        // A spanning title, a header and two rows; the middle column of the last row is empty.
        let boxes = [
            box("Quarterly results by region", 0, 0, 400),
            box("Region", 0, 40), box("Q1", 150, 40, 30), box("Q2", 260, 41, 30),
            box("North", 0, 70), box("1.2", 152, 71, 28), box("1.9", 262, 70, 28),
            box("South", 0, 100), box("2.4", 262, 101, 28),
        ]
        #expect(TextLayout.table(boxes) == """
        Quarterly results by region\t\t
        Region\tQ1\tQ2
        North\t1.2\t1.9
        South\t\t2.4
        """)
    }

    @Test func tableSplitsRowsReturnedAsOneLine() {
        let row = TextBox("Apples 12 Fresh", CGRect(x: 0, y: 0, width: 300, height: 20), words: [
            .init("Apples", CGRect(x: 0, y: 0, width: 60, height: 20)),
            .init("12", CGRect(x: 140, y: 0, width: 20, height: 20)),
            .init("Fresh", CGRect(x: 240, y: 0, width: 60, height: 20)),
        ])
        let row2 = TextBox("Pears 3 Ripe", CGRect(x: 0, y: 30, width: 300, height: 20), words: [
            .init("Pears", CGRect(x: 0, y: 30, width: 50, height: 20)),
            .init("3", CGRect(x: 142, y: 30, width: 10, height: 20)),
            .init("Ripe", CGRect(x: 240, y: 30, width: 40, height: 20)),
        ])
        #expect(TextLayout.cells(of: row).map(\.text) == ["Apples", "12", "Fresh"])
        #expect(TextLayout.table([row, row2]) == "Apples\t12\tFresh\nPears\t3\tRipe")
    }

    @Test func tableWithOneColumnFallsBackToLines() {
        #expect(TextLayout.table([box("a", 0, 0), box("b", 0, 30)]) == "a\nb")
    }

    @Test func picksTheWordUnderTheClick() {
        let line = TextBox("copy this word", CGRect(x: 0, y: 0, width: 200, height: 20), words: [
            .init("copy", CGRect(x: 0, y: 0, width: 50, height: 20)),
            .init("this", CGRect(x: 60, y: 0, width: 50, height: 20)),
            .init("word", CGRect(x: 120, y: 0, width: 60, height: 20)),
        ])
        #expect(TextLayout.word(at: CGPoint(x: 80, y: 10), in: [line]) == "this")
        #expect(TextLayout.word(at: CGPoint(x: 186, y: 10), in: [line]) == "word")
        #expect(TextLayout.word(at: CGPoint(x: 400, y: 10), in: [line]) == nil)
    }

    @Test func visionRectsBecomeTopLeftPixels() {
        let r = TextRecognizer.pixelRect(CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2), in: CGSize(width: 1000, height: 500))
        #expect(r.minX == 100)
        #expect(abs(r.minY - 50) < 0.001)
        #expect(r.width == 500)
        #expect(abs(r.height - 100) < 0.001)
    }

    @MainActor @Test func shiftMovesTheSelection() {
        let model = SelectionModel(mode: .lines, language: nil)
        model.begin(at: CGPoint(x: 10, y: 10))
        model.update(to: CGPoint(x: 50, y: 40), moving: false)
        model.update(to: CGPoint(x: 70, y: 50), moving: true)
        #expect(model.rect == CGRect(x: 30, y: 20, width: 40, height: 30))
        model.update(to: CGPoint(x: 100, y: 60), moving: false)
        #expect(model.rect == CGRect(x: 30, y: 20, width: 70, height: 40))
    }

    /// Black text on white, one string per line.
    static func render(_ lines: [String], size: CGSize = CGSize(width: 900, height: 260)) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        for (i, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 40, y: size.height - 80 - CGFloat(i) * 90)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        return ctx.makeImage()
    }

    @Test func recognizesRenderedText() throws {
        let image = try #require(Self.render(["Invoice 2048", "Total due 12.50"]))
        let boxes = try TextRecognizer.recognize(image, options: .init(language: "en-US", words: true))
        let text = TextLayout.lines(boxes)
        #expect(text.contains("Invoice 2048"))
        #expect(text.contains("Total due 12.50"))
        #expect(text.components(separatedBy: "\n").count == 2)
        let total = try #require(boxes.first { $0.text.contains("Total") }?.words.first)
        #expect(TextLayout.word(at: CGPoint(x: total.rect.midX, y: total.rect.midY), in: boxes) == "Total")
    }
}
