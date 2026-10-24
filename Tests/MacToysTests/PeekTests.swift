import Foundation
import Testing
@testable import MacToysCore
@testable import Peek
@testable import PreviewKit

@Suite struct PeekTests {
    private func urls(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func titleAndWrappingNavigation() {
        var items = PeekItems(urls(["a.png", "b.png", "c.png"]), index: 2)
        #expect(items.title == "c.png — 3 of 3")
        items.next()
        #expect(items.current?.lastPathComponent == "a.png")
        items.previous()
        #expect(items.current?.lastPathComponent == "c.png")
        #expect(PeekItems(urls(["only.txt"])).title == "only.txt")
        #expect(PeekItems([]).title == "Peek")
        #expect(PeekItems(urls(["a", "b"]), index: 9).index == 1)
    }

    @Test func removingTheCurrentItemShowsTheNextOne() {
        var items = PeekItems(urls(["a", "b", "c"]), index: 1)
        items.removeCurrent()
        #expect(items.current?.lastPathComponent == "c")
        items.removeCurrent()
        #expect(items.current?.lastPathComponent == "a")
        items.removeCurrent()
        #expect(items.isEmpty && items.current == nil)
        items.removeCurrent()
        #expect(items.isEmpty)
    }

    @Test func siblingsInFinderOrderSkippingHiddenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["img10.png", "img2.png", "Img1.png", ".DS_Store", "notes.txt"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let items = PeekItems.siblings(of: dir.appendingPathComponent("img2.png"))
        #expect(items.urls.map(\.lastPathComponent) == ["Img1.png", "img2.png", "img10.png", "notes.txt"])
        #expect(items.index == 1)
        let hidden = PeekItems.siblings(of: dir.appendingPathComponent(".DS_Store"))
        #expect(hidden.current?.lastPathComponent == ".DS_Store" && hidden.count == 5)
    }

    @Test func existingDropsMissingAndDuplicatePaths() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = PeekItems.existing([file, URL(fileURLWithPath: "/no/such/file"), file])
        #expect(result == [file])
    }

    @Test func relativeDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(PeekMetadata.relativeDate(now.addingTimeInterval(-60), now: now, calendar: cal).hasPrefix("Today "))
        #expect(PeekMetadata.relativeDate(now.addingTimeInterval(-86_400), now: now, calendar: cal).hasPrefix("Yesterday "))
        #expect(!PeekMetadata.relativeDate(now.addingTimeInterval(-86_400 * 9), now: now, calendar: cal).hasPrefix("Yesterday"))
        #expect(PeekLoader.formatDuration(75) == "1:15")
        #expect(PeekLoader.formatDuration(3_725) == "1:02:05")
    }

    @Test func settingsCarryIntoPreviewOptions() {
        var s = PeekSettings()
        s.codeWrap = true
        s.codeFontSize = 15
        s.codeMaxFileSizeKB = 1
        s.codeTheme = .dark
        let o = s.previewOptions(base: FinderAddonsSettings())
        #expect(o.code.wrap && o.code.fontSize == 15 && o.maxTextBytes == 1024)
        #expect(o.markdownTheme == .dark)
        #expect(o.showLocalImages)
        #expect(PeekSettings().activation == Shortcut(35, [.control, .option]))
    }
}
