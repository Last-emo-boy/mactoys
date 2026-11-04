import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import Testing
import Vision
@testable import TextExtractor
@testable import MacToysCore

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

    /// Whether Vision can run text recognition here at all, asked with a bare request so a bug in
    /// `TextRecognizer` still fails the test. Virtualized macOS CI runners throw from `perform`.
    static let visionReadsText: Bool = {
        guard let image = render(["OK"], size: CGSize(width: 200, height: 100)) else { return false }
        return (try? VNImageRequestHandler(cgImage: image).perform([VNRecognizeTextRequest()])) != nil
    }()

    @Test(.enabled(if: visionReadsText, "Vision text recognition can't run on this machine (virtualized CI runner)"))
    func recognizesRenderedText() throws {
        let image = try #require(Self.render(["Invoice 2048", "Total due 12.50"]))
        let boxes = try TextRecognizer.recognize(image, options: .init(language: "en-US", words: true))
        let text = TextLayout.lines(boxes)
        #expect(text.contains("Invoice 2048"))
        #expect(text.contains("Total due 12.50"))
        #expect(text.components(separatedBy: "\n").count == 2)
        let total = try #require(boxes.first { $0.text.contains("Total") }?.words.first)
        #expect(TextLayout.word(at: CGPoint(x: total.rect.midX, y: total.rect.midY), in: boxes) == "Total")
    }

    // MARK: Line joining

    @Test func paragraphsJoinWrappedLinesAndRejoinHyphens() {
        let boxes = [
            box("Optical character recog-", 0, 0, 300), box("nition turns pictures of text", 0, 26, 296),
            box("into text you can edit.", 0, 52, 180),
            box("A second paragraph starts", 0, 100, 300), box("after the gap.", 0, 126, 110),
        ]
        #expect(TextLayout.paragraphs(boxes) == """
        Optical character recognition turns pictures of text into text you can edit.

        A second paragraph starts after the gap.
        """)
    }

    @Test func paragraphsKeepShortLinesListsAndIndents() {
        // A narrow list is never joined.
        #expect(TextLayout.paragraphs([box("Milk", 0, 0, 40), box("Eggs", 0, 26, 40), box("Bread", 0, 52, 46)]) == "Milk\nEggs\nBread")
        // A short line ends where it is; list items and an indented first line start anew.
        let boxes = [
            box("Shopping list for the weekend:", 0, 0, 300),
            box("• Fresh basil and tomatoes", 0, 26, 260),
            box("• Two loaves of sourdough bread", 0, 52, 300),
            box("Then a paragraph that wraps across", 0, 100, 300), box("the whole width of the column.", 0, 126, 280),
            box("An indented paragraph follows", 30, 152, 300), box("right after it.", 0, 178, 120),
        ]
        #expect(TextLayout.paragraphs(boxes) == """
        Shopping list for the weekend:
        • Fresh basil and tomatoes
        • Two loaves of sourdough bread

        Then a paragraph that wraps across the whole width of the column.

        An indented paragraph follows right after it.
        """)
    }

    @Test func textJoinerKeepsParagraphBreaksAndLists() {
        let text = "Optical character recog-\nnition is fun\nand useful.\n\n\nSecond para-\ngraph here.\n1. First item\n2. Second item\n   continues"
        #expect(TextJoiner.joinLines(text) == "Optical character recognition is fun and useful.\n\nSecond paragraph here.\n1. First item\n2. Second item continues")
        #expect(TextJoiner.joinLines("会议改到\n周四下午") == "会议改到周四下午")
        #expect(TextJoiner.joinLines("soft\u{00AD}\nhyphen and well-\nKnown") == "softhyphen and well- Known")
        #expect(TextJoiner.joinLines("a\r\nb") == "a b")
        #expect(TextJoiner.isListItem("- dash item"))
        #expect(TextJoiner.isListItem("a) letter item"))
        #expect(!TextJoiner.isListItem("e.g. not a list"))
        #expect(!TextJoiner.isListItem("2026 was a year"))
    }

    // MARK: Additive clipboard

    @Test func additiveClipboardAppendsUntilSomethingElseIsCopied() {
        var clip = AdditiveClipboard()
        #expect(clip.add("one", changeCount: 10, separator: .newline) == "one")
        clip.didWrite(changeCount: 11)
        #expect(clip.isCurrent(changeCount: 11))
        #expect(clip.add("two", changeCount: 11, separator: .newline) == "one\ntwo")
        clip.didWrite(changeCount: 12)
        #expect(clip.add("three", changeCount: 12, separator: .blankLine) == "one\n\ntwo\n\nthree")
        clip.didWrite(changeCount: 13)
        #expect(clip.replaceLast("THREE", separator: .space) == "one two THREE")
        // Something else was copied: the next capture starts a new collection.
        #expect(!clip.isCurrent(changeCount: 20))
        #expect(clip.add("fresh", changeCount: 20, separator: .newline) == "fresh")
        clip.reset()
        #expect(clip.pieces.isEmpty && clip.writtenChangeCount == nil)
    }

    // MARK: Barcodes

    @Test func barcodePayloadsAreClassified() {
        #expect(BarcodeContent(payload: "HTTPS://EXAMPLE.COM/A1") == .link(URL(string: "https://EXAMPLE.COM/A1")!))
        #expect(BarcodeContent(payload: "www.example.org/menu") == .link(URL(string: "https://www.example.org/menu")!))
        #expect(BarcodeContent(payload: "mailto:ada@example.com?subject=Hello%20there") == .email(address: "ada@example.com", subject: "Hello there"))
        #expect(BarcodeContent(payload: "MATMSG:TO:ada@example.com;SUB:Hi;BODY:x;;") == .email(address: "ada@example.com", subject: "Hi"))
        #expect(BarcodeContent(payload: "tel:+1-555-0100") == .phone("+1-555-0100"))
        #expect(BarcodeContent(payload: "SMSTO:+15550100:See you at 8") == .message(number: "+15550100", body: "See you at 8"))
        #expect(BarcodeContent(payload: #"WIFI:T:WPA;S:Café\;Guest;P:pa\:ss\\word;H:true;;"#)
                == .wifi(network: "Café;Guest", password: "pa:ss\\word", security: "WPA", hidden: true))
        #expect(BarcodeContent(payload: "WIFI:S:Open Net;T:nopass;P:;;") == .wifi(network: "Open Net", password: nil, security: nil, hidden: false))
        #expect(BarcodeContent(payload: "geo:37.7869,-122.3997;u=35") == .location(latitude: 37.7869, longitude: -122.3997))
        #expect(BarcodeContent(payload: "BEGIN:VCARD\nVERSION:3.0\nN:Lovelace;Ada\nFN:Ada Lovelace\nEND:VCARD") == .contact(name: "Ada Lovelace"))
        #expect(BarcodeContent(payload: "MECARD:N:Lovelace,Ada;TEL:5550100;;") == .contact(name: "Ada Lovelace"))
        #expect(BarcodeContent(payload: "BEGIN:VEVENT\nSUMMARY:Launch review\nDTSTART:20261105T140000\nEND:VEVENT") == .event(title: "Launch review"))
        #expect(BarcodeContent(payload: "4006381333931", symbology: "EAN13") == .product("4006381333931"))
        #expect(BarcodeContent(payload: "12345678", symbology: "QR") == .text("12345678"))
        // Only web links open; other schemes are plain text.
        #expect(BarcodeContent(payload: "javascript:alert(1)") == .text("javascript:alert(1)"))
        #expect(BarcodeContent(payload: "file:///etc/passwd") == .text("file:///etc/passwd"))
        #expect(BarcodeContent(payload: "https://") == .text("https://"))
    }

    @Test func barcodeActionsOpenTheRightApp() {
        #expect(BarcodeContent.phone("+1 (555) 0100").openURL == URL(string: "tel:+15550100"))
        #expect(BarcodeContent.message(number: "+15550100", body: nil).openURL == URL(string: "sms:+15550100"))
        #expect(BarcodeContent.email(address: "ada@example.com", subject: "Hi there").openURL?.absoluteString == "mailto:ada@example.com?subject=Hi%20there")
        #expect(BarcodeContent.location(latitude: 1.5, longitude: 2.25).openURL?.host() == "maps.apple.com")
        #expect(BarcodeContent.wifi(network: "N", password: "secret", security: "WPA", hidden: false).openURL == nil)
        #expect(BarcodeContent.wifi(network: "N", password: "secret", security: "WPA", hidden: false).primaryText == "secret")
        #expect(Barcode(symbology: "QR", payload: "WIFI:T:WPA;S:Net;P:pw;;").copyText == "pw")
        #expect(Barcode(symbology: "QR", payload: "WIFI:T:nopass;S:Open Net;;").copyText == "Open Net")
        #expect(Barcode(symbology: "QR", payload: "mailto:ada@example.com?subject=x").copyText == "ada@example.com")
        let vcard = "BEGIN:VCARD\nFN:Ada Lovelace\nEND:VCARD"
        #expect(Barcode(symbology: "QR", payload: vcard).copyText == vcard)
        #expect(Barcode(symbology: "QR", payload: "x").isMatrix)
        #expect(!Barcode(symbology: "EAN13", payload: "x").isMatrix)
    }

    @Test func codesWinOverShortCaptionsOnly() {
        let code = [Barcode(symbology: "QR", payload: "https://example.com")]
        #expect(Capture.prefersBarcodes(text: "Scan me", barcodes: code))
        #expect(!Capture.prefersBarcodes(text: "Scan me", barcodes: []))
        #expect(!Capture.prefersBarcodes(text: "Line one\nLine two\nLine three", barcodes: code))
        var c = Capture(text: "Scan me", mode: .lines, source: .screen, barcodes: code, barcodeFirst: true)
        #expect(c.copiedText == "https://example.com")
        c.barcodeFirst = false
        #expect(c.copiedText == "Scan me")
    }

    // MARK: Card and history

    @Test func cardGoesBelowAboveOrBesideTheSelection() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 400, height: 220)
        // Room below (Cocoa: lower y).
        #expect(CardPlacement.origin(for: size, near: CGRect(x: 100, y: 500, width: 300, height: 100), in: visible)
                == CGPoint(x: 100, y: 268))
        // No room below: above.
        #expect(CardPlacement.origin(for: size, near: CGRect(x: 100, y: 60, width: 300, height: 100), in: visible)
                == CGPoint(x: 100, y: 172))
        // Clamped to the right edge.
        #expect(CardPlacement.origin(for: size, near: CGRect(x: 1300, y: 500, width: 100, height: 50), in: visible).x == 1032)
        // A tall selection: beside it.
        #expect(CardPlacement.origin(for: size, near: CGRect(x: 100, y: 20, width: 300, height: 840), in: visible)
                == CGPoint(x: 412, y: 640))
        // No selection: the top-right corner.
        #expect(CardPlacement.origin(for: size, near: nil, in: visible) == CGPoint(x: 1024, y: 639))
    }

    @MainActor @Test func recentCapturesDedupeTrimAndPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = CaptureHistory(file: file)
        history.limit = 3
        for i in 1...4 { history.add(Capture(text: "text \(i)", mode: .lines, source: .screen)) }
        #expect(history.items.map(\.text) == ["text 4", "text 3", "text 2"])
        history.add(Capture(text: "text 2", mode: .lines, source: .screen))
        #expect(history.items.map(\.text) == ["text 2", "text 4", "text 3"])
        var first = history.items[0]
        first.text = "text 2, joined"
        history.update(first)
        #expect(history.items[0].text == "text 2, joined")
        // Nothing is written until saving is turned on.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        history.setPersistence(true)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let reloaded = CaptureHistory(file: file)
        reloaded.setPersistence(true)
        #expect(reloaded.items.map(\.text) == ["text 2, joined", "text 4", "text 3"])
        reloaded.setPersistence(false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func settingsKeepOlderFilesWorking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        // A settings file from before the card, barcodes and the other new options.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"mode":"table","languageCorrection":false,"showConfirmation":false}"#.utf8)
            .write(to: store.url(for: "textextractor"))
        let s = store.load("textextractor", default: TextExtractorSettings())
        #expect(s.mode == .table && !s.languageCorrection && !s.showConfirmation)
        #expect(s.detectBarcodes && !s.additive && s.feedback == .card && s.captureAdding == nil)
        #expect(s.activation == TextExtractorSettings().activation)
    }

    /// Vision's barcode detector, probed the same way as text recognition.
    static let visionDetectsBarcodes: Bool = {
        guard let image = qrImage("probe") else { return false }
        return (try? VNImageRequestHandler(cgImage: image).perform([VNDetectBarcodesRequest()])) != nil
    }()

    static func qrImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -60, dy: -60)))
        return CIContext().createCGImage(padded, from: padded.extent)
    }

    @Test(.enabled(if: visionDetectsBarcodes, "Vision barcode detection can't run on this machine (virtualized CI runner)"))
    func detectsAGeneratedQRCode() throws {
        let image = try #require(Self.qrImage("WIFI:T:WPA;S:Studio;P:correct horse;;"))
        let found = try TextRecognizer.analyze(image, options: .init(language: "en-US"), barcodes: true)
        #expect(found.barcodes.first?.symbology == "QR")
        #expect(found.barcodes.first?.content == .wifi(network: "Studio", password: "correct horse", security: "WPA", hidden: false))
    }
}
