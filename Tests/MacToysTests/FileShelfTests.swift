import AppKit
import Foundation
import Testing
@testable import FileShelf
@testable import MacToysCore

@Suite struct FileShelfTests {
    // MARK: Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// Pointer samples at 120 Hz.
    private func trace(_ duration: Double, start: Double = 0, _ position: (Double) -> (Double, Double)) -> [(Double, Double, Double)] {
        stride(from: 0.0, through: duration, by: 1.0 / 120).map { t in
            let (x, y) = position(t)
            return (x, y, start + t)
        }
    }

    private func fires(_ sensitivity: ShakeSensitivity, _ samples: [(Double, Double, Double)]) -> Bool {
        var detector = ShakeDetector(tuning: sensitivity.tuning)
        return samples.contains { detector.add(x: $0.0, y: $0.1, time: $0.2) }
    }

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("mactoys.tests.shelf.\(UUID().uuidString)"))
    }

    private func pngData() -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    // MARK: Shake detector

    @Test func quickSideToSideShakeOpensAShelf() {
        let shake = trace(1.0) { t in (500 + 60 * sin(2 * .pi * 4 * t), 300) }
        #expect(fires(.medium, shake))
        #expect(fires(.low, trace(1.4) { t in (500 + 70 * sin(2 * .pi * 4 * t), 300) }))
        #expect(fires(.high, shake))
    }

    @Test func upAndDownAndDiagonalShakesCountToo() {
        #expect(fires(.medium, trace(1.0) { t in (400, 300 + 60 * sin(2 * .pi * 4 * t)) }))
        #expect(fires(.medium, trace(1.0) { t in (400 + 45 * sin(2 * .pi * 4 * t), 300 + 45 * sin(2 * .pi * 4 * t)) }))
    }

    @Test func ordinaryDragsNeverOpenAShelf() {
        // A straight drag across the screen.
        #expect(!fires(.high, trace(0.8) { t in (100 + 1000 * t, 200 + 300 * t) }))
        // A curved drag to the Dock.
        #expect(!fires(.high, trace(1.2) { t in (200 + 700 * t, 400 - 250 * sin(.pi * t / 1.2)) }))
        // Overshooting the target, coming back, settling.
        let overshoot = trace(0.5) { t in (600 * t / 0.5, 300) }
            + trace(0.15, start: 0.5) { t in (600 - 50 * t / 0.15, 300) }
            + trace(0.2, start: 0.65) { t in (550 + 20 * t / 0.2, 300) }
        #expect(!fires(.high, overshoot))
        // Hand tremor while hovering over a drop target.
        #expect(!fires(.high, trace(2) { t in (300 + 3 * sin(2 * .pi * 11 * t), 300 + 2 * cos(2 * .pi * 7 * t)) }))
        // Slow, wide sweeps (looking for a folder) are not a shake.
        #expect(!fires(.high, trace(4) { t in (500 + 200 * sin(2 * .pi * 0.7 * t), 300) }))
    }

    @Test func sensitivityDecidesHowSmallAShakeCanBe() {
        let small = trace(1.0) { t in (500 + 15 * sin(2 * .pi * 5 * t), 300) }
        #expect(fires(.high, small))
        #expect(!fires(.medium, small))
        #expect(!fires(.low, small))
    }

    @Test func aShakeBrokenByAPauseStartsOver() {
        let first = trace(0.25) { t in (500 + 60 * sin(2 * .pi * 4 * t), 300) }
        let pause = trace(1.0, start: 0.25) { _ in (500 + 60 * sin(2 * .pi), 300) }
        let second = trace(0.25, start: 1.25) { t in (500 + 60 * sin(2 * .pi * 4 * t), 300) }
        #expect(!fires(.medium, first + pause + second))
    }

    @Test func shakeAfterALongDragStillCounts() {
        let drag = trace(0.6) { t in (100 + 800 * t, 300) }
        let shake = trace(1.0, start: 0.6) { t in (580 + 60 * sin(2 * .pi * 4 * t), 300) }
        #expect(fires(.medium, drag + shake))
    }

    @Test func detectorResetsAfterFiringAndOnReset() {
        var d = ShakeDetector(tuning: ShakeSensitivity.medium.tuning)
        let shake = trace(2.0) { t in (500 + 60 * sin(2 * .pi * 4 * t), 300) }
        let fireTimes = shake.filter { d.add(x: $0.0, y: $0.1, time: $0.2) }.map(\.2)
        // Firing resets the count, so a long shake fires again only after another full set of reversals.
        #expect(fireTimes.count >= 2)
        #expect(zip(fireTimes, fireTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.4 })

        var e = ShakeDetector(tuning: ShakeSensitivity.medium.tuning)
        let half = trace(0.45) { t in (500 + 60 * sin(2 * .pi * 4 * t), 300) }
        for s in half { _ = e.add(x: s.0, y: s.1, time: s.2) }
        e.reset()
        let rest = trace(0.3, start: 0.45) { t in (500 + 60 * sin(2 * .pi * 4 * (t + 0.45)), 300) }
        #expect(!rest.contains { e.add(x: $0.0, y: $0.1, time: $0.2) })
    }

    // MARK: Item model

    @Test func addingSkipsDuplicatesAndKeepsDropOrder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try write("a", to: a)
        try write("b", to: b)
        var shelf = Shelf()
        #expect(shelf.add([.file(a), .file(b)]).count == 2)
        // The same file again, spelled differently, and twice within one drop.
        let again = URL(fileURLWithPath: dir.path + "/./a.txt")
        #expect(shelf.add([.file(again), .file(b)]).isEmpty)
        let c = dir.appendingPathComponent("c.txt")
        try write("c", to: c)
        #expect(shelf.add([.file(c), .file(c)]).count == 1)
        #expect(shelf.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(shelf.pileItems.map(\.name) == ["c.txt", "b.txt", "a.txt"])

        let store = ClippingStore(root: dir.appendingPathComponent("Clippings"))
        let t1 = try store.item(for: .text("Same words"))
        let t2 = try store.item(for: .text("Same words"))
        let l1 = try store.item(for: .link(URL(string: "https://example.com/a")!, title: "A"))
        let l2 = try store.item(for: .link(URL(string: "https://example.com/a")!, title: "Other title"))
        #expect(shelf.add([t1, t2, l1, l2]).count == 2)

        shelf.remove([shelf.items[1].id])
        #expect(shelf.items.map(\.name).prefix(2) == ["a.txt", "c.txt"])
        #expect(shelf.items(Set([shelf.items[0].id])).count == 1)
        #expect(shelf.items([]).count == shelf.items.count)
    }

    @Test func recentShelvesKeepTheNewestTenWithItems() {
        var recent: [Shelf] = []
        let item = ShelfItem(kind: .file, url: URL(fileURLWithPath: "/tmp/x"), name: "x")
        var shelves: [Shelf] = []
        for _ in 0..<12 { shelves.append(Shelf(items: [item])) }
        for s in shelves { ShelfArchive.pushRecent(s, into: &recent) }
        #expect(recent.count == 10)
        #expect(recent.first?.id == shelves.last?.id)
        // Pushing a shelf again moves it to the front instead of duplicating it.
        ShelfArchive.pushRecent(shelves[5], into: &recent)
        #expect(recent.first?.id == shelves[5].id && recent.filter { $0.id == shelves[5].id }.count == 1)
        // Empty shelves aren't worth remembering.
        ShelfArchive.pushRecent(Shelf(), into: &recent)
        #expect(recent.first?.id == shelves[5].id)
    }

    @Test func savedShelvesComeBackWithoutMissingFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("Keep.pdf")
        let gone = dir.appendingPathComponent("Gone.pdf")
        let moving = dir.appendingPathComponent("Folder/Moving.key")
        try write("k", to: keep)
        try write("g", to: gone)
        try write("m", to: moving)
        let store = ClippingStore(root: dir.appendingPathComponent("Clippings"))
        let text = try store.item(for: .text("Remember the milk"))
        var shelf = Shelf(items: [.file(keep), .file(gone), .file(moving), text], title: "Work", pinned: false,
                          frame: CGRect(x: 100, y: 200, width: 156, height: 176))
        shelf.expanded = true
        let archiveURL = dir.appendingPathComponent("shelves.json")
        ShelfPersistence.save(ShelfArchive(open: [shelf], recent: [Shelf(items: [.file(gone)])]), to: archiveURL)

        try FileManager.default.removeItem(at: gone)
        let movedTo = dir.appendingPathComponent("Moved Here.key")
        try FileManager.default.moveItem(at: moving, to: movedTo)

        let loaded = ShelfPersistence.load(from: archiveURL)
        #expect(loaded.open.first == shelf)
        let restored = try #require(ShelfPersistence.restore(loaded.open[0]))
        #expect(restored.items.map(\.name) == ["Keep.pdf", "Moved Here.key", text.name])
        #expect(resolved(restored.items[1].url) == resolved(movedTo))
        #expect(restored.title == "Work" && restored.expanded && restored.frame == shelf.frame)
        // A shelf whose files are all gone is dropped, unless it is pinned.
        #expect(ShelfPersistence.restore(loaded.recent[0]) == nil)
        var pinned = loaded.recent[0]
        pinned.pinned = true
        #expect(ShelfPersistence.restore(pinned)?.items.isEmpty == true)
        // A missing or damaged archive is an empty one.
        try Data("{".utf8).write(to: archiveURL)
        #expect(ShelfPersistence.load(from: archiveURL) == ShelfArchive())
        #expect(ShelfPersistence.load(from: dir.appendingPathComponent("none.json")) == ShelfArchive())
    }

    @Test func clippingsAreFilesThatCanBeRenamedAndCleanedUp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClippingStore(root: dir)
        let text = try store.item(for: .text("Meeting notes\nAgenda: launch"))
        #expect(text.kind == .text && text.owned && text.name == "Meeting notes.txt")
        #expect(try String(contentsOf: text.url, encoding: .utf8) == "Meeting notes\nAgenda: launch")
        #expect(text.preview?.hasPrefix("Meeting notes") == true)
        let image = try store.item(for: .image(pngData(), "png"))
        #expect(image.kind == .image && image.url.pathExtension == "png" && image.byteSize ?? 0 > 0)
        let link = try store.item(for: .link(URL(string: "https://developer.apple.com/xcode/")!, title: "Xcode"))
        #expect(link.name == "Xcode.webloc" && link.link?.host() == "developer.apple.com")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: link.url), format: nil) as? [String: String]
        #expect(plist?["URL"] == "https://developer.apple.com/xcode/")
        #expect(store.contains(text.url) && !store.contains(dir))

        let renamed = try store.rename(text, to: "Agenda")
        #expect(renamed.name == "Agenda.txt" && FileManager.default.fileExists(atPath: renamed.url.path))
        #expect(!FileManager.default.fileExists(atPath: text.url.path))
        #expect(try store.rename(renamed, to: "  ").name == "Agenda.txt")
        let plan = try store.rename(renamed, to: "Plan.md")
        #expect(plan.name == "Plan.md" && FileManager.default.fileExists(atPath: plan.url.path))

        // Only folders no item refers to are deleted, and fresh ones are spared.
        store.collectGarbage(keeping: [plan], sparingAfter: Date().addingTimeInterval(-60))
        #expect(FileManager.default.fileExists(atPath: image.url.path))
        store.collectGarbage(keeping: [plan])
        #expect(FileManager.default.fileExists(atPath: plan.url.path))
        #expect(!FileManager.default.fileExists(atPath: image.url.path))
        #expect(!FileManager.default.fileExists(atPath: link.url.path))
    }

    // MARK: Pasteboard

    @Test @MainActor func filesAndFolderReferencesBecomeFileDrops() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Report.pdf"), folder = dir.appendingPathComponent("Photos", isDirectory: true)
        try write("pdf", to: a)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pb = pasteboard()
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString(a.absoluteString, forType: .fileURL)
        let second = NSPasteboardItem()
        // Finder writes file reference URLs (file:///.file/id=…).
        let reference = (folder as NSURL).fileReferenceURL()?.absoluteString ?? folder.absoluteString
        second.setString(reference, forType: .fileURL)
        pb.writeObjects([first, second])
        let drops = ShelfPasteboardReader.drops(from: pb)
        #expect(drops.count == 2)
        if case .file(let url) = drops[0] { #expect(resolved(url) == resolved(a)) } else { Issue.record("expected a file") }
        if case .file(let url) = drops[1] { #expect(resolved(url) == resolved(folder)) } else { Issue.record("expected a folder") }
        #expect(ShelfPasteboardReader.hasContent(pb))
    }

    @Test @MainActor func imagesBecomeImageDrops() {
        let png = pngData()
        let pb = pasteboard()
        pb.clearContents()
        let p = NSPasteboardItem()
        p.setData(png, forType: .png)
        p.setString("https://example.com/cat.png", forType: .URL)
        pb.writeObjects([p])
        #expect(ShelfPasteboardReader.drops(from: pb) == [.image(png, "png")])

        pb.clearContents()
        let tiffItem = NSPasteboardItem()
        tiffItem.setData(NSImage(data: png)!.tiffRepresentation!, forType: .tiff)
        pb.writeObjects([tiffItem])
        guard case .image(let data, let ext)? = ShelfPasteboardReader.drops(from: pb).first else {
            Issue.record("expected an image")
            return
        }
        #expect(ext == "png" && NSBitmapImageRep(data: data)?.pixelsWide == 2)

        pb.clearContents()
        let jpeg = NSPasteboardItem()
        jpeg.setData(Data([0xFF, 0xD8, 0xFF, 0xE0]), forType: .jpeg)
        pb.writeObjects([jpeg])
        #expect(ShelfPasteboardReader.drops(from: pb) == [.image(Data([0xFF, 0xD8, 0xFF, 0xE0]), "jpg")])
    }

    @Test @MainActor func linksAndTextBecomeTheirOwnDrops() {
        let pb = pasteboard()
        pb.clearContents()
        let link = NSPasteboardItem()
        link.setString("https://www.apple.com/macos/", forType: .URL)
        link.setString("https://www.apple.com/macos/", forType: .string)
        link.setString("macOS – Apple", forType: .urlName)
        let text = NSPasteboardItem()
        text.setString("Pick up the prints\nat 5 pm", forType: .string)
        let bareURL = NSPasteboardItem()
        bareURL.setString("  https://example.com/path?q=1 \n", forType: .string)
        let sentence = NSPasteboardItem()
        sentence.setString("see https://example.com later", forType: .string)
        let blank = NSPasteboardItem()
        blank.setString("   \n", forType: .string)
        pb.writeObjects([link, text, bareURL, sentence, blank])
        #expect(ShelfPasteboardReader.drops(from: pb) == [
            .link(URL(string: "https://www.apple.com/macos/")!, title: "macOS – Apple"),
            .text("Pick up the prints\nat 5 pm"),
            .link(URL(string: "https://example.com/path?q=1")!, title: nil),
            .text("see https://example.com later"),
        ])

        pb.clearContents()
        let rich = NSPasteboardItem()
        let rtf = NSAttributedString(string: "Bold idea").rtf(from: NSRange(location: 0, length: 9), documentAttributes: [:])!
        rich.setData(rtf, forType: .rtf)
        pb.writeObjects([rich])
        #expect(ShelfPasteboardReader.drops(from: pb) == [.text("Bold idea")])

        pb.clearContents()
        #expect(ShelfPasteboardReader.drops(from: pb).isEmpty)
        #expect(!ShelfPasteboardReader.hasContent(pb))
    }

    @Test @MainActor func copiedItemsReadBackAsTheSameThings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Budget.numbers")
        try write("n", to: file)
        let store = ClippingStore(root: dir.appendingPathComponent("Clippings"))
        let text = try store.item(for: .text("Call Ana back"))
        let link = try store.item(for: .link(URL(string: "https://example.org/")!, title: "Example"))
        let image = try store.item(for: .image(pngData(), "png"))
        let pb = pasteboard()
        ShelfPasteboardWriter.copy([.file(file), text, link, image], to: pb)
        let drops = ShelfPasteboardReader.drops(from: pb)
        #expect(drops.count == 4)
        if case .file(let url) = drops[0] { #expect(resolved(url) == resolved(file)) } else { Issue.record("expected a file") }
        #expect(drops[1] == .text("Call Ana back"))
        #expect(drops[2] == .link(URL(string: "https://example.org/")!, title: "Example"))
        if case .image(_, let ext) = drops[3] { #expect(ext == "png") } else { Issue.record("expected an image") }
    }

    @Test @MainActor func draggedClippingsCarryTheirContentBesideTheFilePromise() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClippingStore(root: dir)
        let text = try store.item(for: .text("Hello there"))
        let pb = pasteboard()
        let writer = ShelfPasteboardWriter.dragWriter(for: text)
        let promise = try #require(writer as? ClippingPromiseProvider)
        #expect(promise.writableTypes(for: pb).contains(.string))
        #expect(promise.pasteboardPropertyList(forType: .string) as? String == "Hello there")
        #expect(ClippingPromiseDelegate.shared.filePromiseProvider(promise, fileNameForType: "public.plain-text") == text.name)

        // Fulfilling the promise copies the clipping, numbering the name when it's taken.
        let destination = try tempDir()
        defer { try? FileManager.default.removeItem(at: destination) }
        try write("old", to: destination.appendingPathComponent(text.name))
        var written: Error?? = .none
        ClippingPromiseDelegate.shared.filePromiseProvider(promise, writePromiseTo: destination.appendingPathComponent(text.name)) { written = .some($0) }
        #expect(written != nil && written! == nil)
        let copy = destination.appendingPathComponent("Hello there 2.txt")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Hello there")

        let link = try store.item(for: .link(URL(string: "https://example.com")!, title: nil))
        let linkWriter = try #require(ShelfPasteboardWriter.dragWriter(for: link) as? ClippingPromiseProvider)
        #expect(linkWriter.pasteboardPropertyList(forType: .string) as? String == "https://example.com")
        // Files travel as plain file URLs.
        let fileURL = dir.appendingPathComponent("plain.txt")
        try write("p", to: fileURL)
        #expect(ShelfPasteboardWriter.dragWriter(for: .file(fileURL)) is NSURL)
    }

    // MARK: Naming

    @Test func zipNamesFollowFinder() {
        #expect(ShelfNaming.zipName(for: ["Report.pdf"]) == "Report.pdf.zip")
        #expect(ShelfNaming.zipName(for: ["Photos"]) == "Photos.zip")
        #expect(ShelfNaming.zipName(for: ["a.txt", "b.txt"]) == "Archive.zip")
        #expect(ShelfNaming.zipName(for: ["a", "b"], archive: "Archiv") == "Archiv.zip")
        #expect(ShelfNaming.zipName(for: ["a", "b"], existing: ["Archive.zip"]) == "Archive 2.zip")
        #expect(ShelfNaming.zipName(for: ["a", "b"], existing: ["archive.zip", "Archive 2.zip"]) == "Archive 3.zip")
        #expect(ShelfNaming.zipName(for: ["Report.pdf"], existing: ["Report.pdf.zip"]) == "Report.pdf 2.zip")
    }

    @Test func uniqueNamesNumberBeforeTheExtension() {
        #expect(ShelfNaming.unique("notes.txt", existing: []) == "notes.txt")
        #expect(ShelfNaming.unique("notes.txt", existing: ["notes.txt"]) == "notes 2.txt")
        #expect(ShelfNaming.unique("notes.txt", existing: ["NOTES.TXT", "notes 2.txt"]) == "notes 3.txt")
        #expect(ShelfNaming.unique("Makefile", existing: ["Makefile"]) == "Makefile 2")
        #expect(ShelfNaming.unique(".env", existing: [".env"]) == ".env 2")
    }

    @Test func clippingNamesComeFromTheirContent() {
        #expect(ShelfNaming.textClippingName("Meeting notes\nSecond line") == "Meeting notes.txt")
        #expect(ShelfNaming.textClippingName("   \n\n", fallback: "Text Clipping") == "Text Clipping.txt")
        #expect(ShelfNaming.textClippingName("a/b: c") == "a-b- c.txt")
        #expect(ShelfNaming.textClippingName("...hidden") == "hidden.txt")
        let long = ShelfNaming.textClippingName("The quick brown fox jumps over the lazy dog and keeps running far away")
        #expect(long == "The quick brown fox jumps over the lazy.txt")
        #expect(ShelfNaming.linkClippingName(URL(string: "https://example.com/a")!, title: "Docs: Intro") == "Docs- Intro.webloc")
        #expect(ShelfNaming.linkClippingName(URL(string: "https://example.com/a")!, title: nil) == "example.com.webloc")

        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 4; c.hour = 14; c.minute = 32; c.second = 7
        let date = Calendar(identifier: .gregorian).date(from: c)!
        #expect(ShelfNaming.imageClippingName(date: date, ext: "png") == "Image 2026-11-04 at 14.32.07.png")
    }

    // MARK: File operations

    @Test func compressingMakesFinderStyleArchives() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("Report.pdf")
        let photo = dir.appendingPathComponent("Photos/beach.jpg")
        try write("pdf", to: report)
        try write("jpg", to: photo)
        let single = try ShelfFileOps.compressSync([report], into: dir, archiveWord: "Archive")
        #expect(single.lastPathComponent == "Report.pdf.zip")
        let multi = try ShelfFileOps.compressSync([report, dir.appendingPathComponent("Photos")], into: dir, archiveWord: "Archive")
        #expect(multi.lastPathComponent == "Archive.zip")
        let again = try ShelfFileOps.compressSync([report, dir.appendingPathComponent("Photos")], into: dir, archiveWord: "Archive")
        #expect(again.lastPathComponent == "Archive 2.zip")

        let out = dir.appendingPathComponent("out")
        #expect(Shell.run("/usr/bin/ditto", ["-x", "-k", multi.path, out.path]).ok)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Photos/beach.jpg").path))
        // Nothing of the staging folder is left behind next to the archives.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["Archive 2.zip", "Archive.zip", "Photos", "Report.pdf", "Report.pdf.zip", "out"])
    }

    @Test func movingIntoAFolderNumbersTakenNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a/notes.txt")
        let target = dir.appendingPathComponent("b", isDirectory: true)
        try write("new", to: file)
        try write("old", to: target.appendingPathComponent("notes.txt"))
        let moved = try ShelfFileOps.move(file, into: target)
        #expect(moved.lastPathComponent == "notes 2.txt")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Moving into the folder it's already in changes nothing.
        #expect(try ShelfFileOps.move(moved, into: target) == moved)
    }

    // MARK: Geometry

    @Test func newShelvesStayOnScreenAndDontCoverEachOther() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = ShelfGeometry.collapsedSize
        let centered = ShelfGeometry.newFrame(size: size, placement: .pointer, pointer: CGPoint(x: 700, y: 400), visible: screen, occupied: [])
        #expect(centered.midX == 700 && centered.contains(CGPoint(x: 700, y: 400)))
        let corner = ShelfGeometry.newFrame(size: size, placement: .pointer, pointer: CGPoint(x: 1435, y: 5), visible: screen, occupied: [])
        #expect(screen.contains(corner))
        let second = ShelfGeometry.newFrame(size: size, placement: .pointer, pointer: CGPoint(x: 700, y: 400), visible: screen, occupied: [centered])
        #expect(second.origin != centered.origin && screen.contains(second))

        let first = ShelfGeometry.newFrame(size: size, placement: .rightEdge, pointer: .zero, visible: screen, occupied: [])
        #expect(first.maxX == screen.maxX - ShelfGeometry.margin && first.maxY == screen.maxY - ShelfGeometry.margin)
        let below = ShelfGeometry.newFrame(size: size, placement: .rightEdge, pointer: .zero, visible: screen, occupied: [first])
        #expect(below.maxY < first.minY && below.minX == first.minX)
        let left = ShelfGeometry.newFrame(size: size, placement: .leftEdge, pointer: .zero, visible: screen, occupied: [first])
        #expect(left.minX == ShelfGeometry.margin && left.maxY == first.maxY)
    }

    @Test func panelSizeFollowsItemsAndLayout() {
        #expect(ShelfGeometry.size(expanded: false, itemCount: 40, layout: .grid) == ShelfGeometry.collapsedSize)
        let one = ShelfGeometry.size(expanded: true, itemCount: 1, layout: .grid)
        let six = ShelfGeometry.size(expanded: true, itemCount: 6, layout: .grid)
        let many = ShelfGeometry.size(expanded: true, itemCount: 60, layout: .grid)
        #expect(one.height == ShelfGeometry.minExpandedHeight)
        #expect(six.height > one.height && six.width == ShelfGeometry.expandedWidth)
        #expect(many.height == ShelfGeometry.maxExpandedHeight)
        #expect(ShelfGeometry.size(expanded: true, itemCount: 7, layout: .list).height
                == ShelfGeometry.headerHeight + 7 * ShelfGeometry.rowHeight + ShelfGeometry.contentPadding)
        let resized = ShelfGeometry.resized(CGRect(x: 400, y: 500, width: 156, height: 176), to: six,
                                            within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(resized.maxY == 676 && resized.midX == 478)
        let clamped = ShelfGeometry.resized(CGRect(x: 0, y: 0, width: 156, height: 176), to: six,
                                            within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(clamped.minX == 0 && clamped.minY == 0)
    }
}
