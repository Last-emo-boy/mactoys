import AppKit
import Foundation
import Testing
@testable import ClipboardHistory
@testable import MacToysCore

private let now = ISO8601DateFormatter().date(from: "2026-03-05T12:00:00Z")!
private let en = Locale(identifier: "en_US")
private let utc = TimeZone(identifier: "UTC")!
private var utcCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.locale = en
    c.timeZone = utc
    return c
}

private func clip(_ text: String?, kind: ClipItem.Kind = .text, ago: TimeInterval = 60, app: String? = nil,
                  bundleID: String? = nil, name: String? = nil, pinned: Bool = false,
                  image: Data? = nil, files: [URL] = []) -> ClipItem {
    var item = ClipItem(kind: kind, text: text, image: image, files: files)
    item.date = now.addingTimeInterval(-ago)
    item.sourceApp = app
    item.sourceBundleID = bundleID
    item.name = name
    item.pinned = pinned
    return item
}

private func texts(_ items: [ClipItem]) -> [String] { items.map { $0.name ?? $0.text ?? "" } }

/// Clipboard History: search, classification, privacy, snippets, the paste stack, storage and the panel.
@Suite enum ClipboardHistoryTests {}

// MARK: - Search and filters

extension ClipboardHistoryTests {
    @Suite struct Search {
        @Test func ranksNameThenStartThenWordStartThenAnywhere() {
            let items = [
                clip("Preview build is ready", ago: 100),
                clip("Code review for the parser", ago: 200),
                clip("review the deck before Thursday", ago: 300),
                clip("x y z", ago: 400, name: "Review notes"),
                clip("Unrelated", ago: 50, app: "Preview"),
            ]
            let results = ClipSearch.results(items, query: "review", now: now, calendar: utcCalendar)
            #expect(texts(results) == ["Review notes", "review the deck before Thursday", "Code review for the parser",
                                       "Preview build is ready"])
        }

        @Test func equalScoresListNewestFirst() {
            let older = clip("launch notes", ago: 600)
            let newer = clip("launch plan", ago: 30)
            #expect(ClipSearch.results([older, newer], query: "launch", now: now).map(\.id) == [newer.id, older.id])
        }

        @Test func everyWordHasToMatch() {
            let items = [clip("review the deck"), clip("review the budget"), clip("deck chairs")]
            #expect(texts(ClipSearch.results(items, query: "review deck", now: now)) == ["review the deck"])
            #expect(ClipSearch.results(items, query: "review zebra", now: now).isEmpty)
        }

        @Test func emptyQueryKeepsOrderAndAppliesFilter() {
            let items = [clip("b", ago: 10), clip("a", ago: 20, pinned: true), clip("c", ago: 30)]
            #expect(texts(ClipSearch.results(items, query: "  ", now: now)) == ["b", "a", "c"])
            var filter = ClipFilter()
            filter.pinnedOnly = true
            #expect(texts(ClipSearch.results(items, query: "", filter: filter, now: now)) == ["a"])
        }

        @Test func caseAndDiacriticsDontMatter() {
            let items = [clip("Café au lait"), clip("CAFETERIA menu")]
            #expect(ClipSearch.results(items, query: "cafe", now: now).count == 2)
        }

        @Test func linkHostAndFileNamesAreSearched() {
            let link = clip("https://www.github.com/mactoys/mactoys/pull/214")
            let file = clip("/Users/ada/Invoices/Invoice-114.pdf", kind: .files,
                            files: [URL(fileURLWithPath: "/Users/ada/Invoices/Invoice-114.pdf")])
            #expect(ClipSearch.results([link, file], query: "github", now: now).map(\.id) == [link.id])
            #expect(ClipSearch.results([link, file], query: "invoice", now: now).map(\.id) == [file.id])
            // The folder path counts too, more weakly.
            #expect(ClipSearch.results([link, file], query: "ada", now: now).map(\.id) == [file.id])
        }

        @Test func closeSubsequenceMatchesTheTitleWeakly() {
            let link = clip("https://github.com/mactoys/mactoys")
            let exact = clip("gthb is a typo people make")
            #expect(ClipSearch.results([link, exact], query: "gthb", now: now).map(\.id) == [exact.id, link.id])
        }

        @Test func subsequenceLettersHaveToLieClose() {
            #expect(ClipSearch.isSubsequence("gthb", of: "github"))
            #expect(ClipSearch.isSubsequence("GTHB", of: "GitHub"))
            #expect(!ClipSearch.isSubsequence("gthb", of: "g-------------------t-------h------b"))
            // Short tokens never match as a subsequence.
            #expect(!ClipSearch.isSubsequence("gh", of: "github"))
        }

        @Test func appAndTypeOnlyMatchAtWordStarts() {
            let code = clip("hello there", app: "Visual Studio Code")
            let viewer = clip("something", app: "Preview")
            let link = clip("https://example.com/a")
            #expect(ClipSearch.results([code, viewer, link], query: "studio", now: now).map(\.id) == [code.id])
            #expect(ClipSearch.results([code, viewer, link], query: "tudio", now: now).isEmpty)
            // "view" is inside "Preview", not at a word start.
            #expect(ClipSearch.results([code, viewer, link], query: "view", now: now).isEmpty)
            #expect(ClipSearch.results([code, viewer, link], query: "links", now: now).map(\.id) == [link.id])
            #expect(ClipSearch.results([code, viewer, link], query: "inks", now: now).isEmpty)
        }

        @Test func matchQuality() {
            #expect(ClipSearch.quality(of: "deck", in: "deck") == 4)
            #expect(ClipSearch.quality(of: "deck", in: "Deck chairs") == 3)
            #expect(ClipSearch.quality(of: "deck", in: "the deck") == 2)
            #expect(ClipSearch.quality(of: "deck", in: "tdeck, the deck") == 2)
            #expect(ClipSearch.quality(of: "deck", in: "tdeck") == 1)
            #expect(ClipSearch.quality(of: "deck", in: "desk") == 0)
        }

        @Test func filtersByTypeAndApp() {
            let items = [
                clip("https://example.com", app: "Safari", bundleID: "com.apple.Safari"),
                clip("#FF5F4A", app: "Freeform", bundleID: "com.apple.freeform"),
                clip("plain words", ago: 10, app: "Notes"),
                clip("more words", ago: 20, app: "Notes"),
            ]
            var filter = ClipFilter()
            filter.type = .color
            #expect(texts(ClipSearch.results(items, query: "", filter: filter, now: now)) == ["#FF5F4A"])
            filter = ClipFilter()
            filter.app = "com.apple.Safari"
            #expect(texts(ClipSearch.results(items, query: "", filter: filter, now: now)) == ["https://example.com"])
            // Entries without a bundle id are matched by app name.
            filter.app = "Notes"
            #expect(texts(ClipSearch.results(items, query: "words", filter: filter, now: now)) == ["plain words", "more words"])
            #expect(filter.isActive)
            #expect(!ClipFilter().isActive)
        }

        @Test func filtersByDate() {
            let items = [
                clip("this morning", ago: 4 * 3600),
                clip("last night", ago: 16 * 3600),
                clip("three days ago", ago: 3 * 86_400),
                clip("three weeks ago", ago: 21 * 86_400),
                clip("two months ago", ago: 60 * 86_400),
            ]
            func run(_ range: ClipFilter.DateRange) -> [String] {
                var filter = ClipFilter()
                filter.date = range
                return texts(ClipSearch.results(items, query: "", filter: filter, now: now, calendar: utcCalendar))
            }
            #expect(run(.today) == ["this morning"])
            #expect(run(.yesterday) == ["last night"])
            #expect(run(.week) == ["this morning", "last night", "three days ago"])
            #expect(run(.month) == ["this morning", "last night", "three days ago", "three weeks ago"])
            #expect(run(.any).count == 5)
        }

        @Test func snippetsPutExactAbbreviationFirst() {
            let snippets = [
                Snippet(name: "Signature (long)", abbreviation: "sigl", text: "Best regards"),
                Snippet(name: "Email signature", abbreviation: "sig", text: "Best,\nAda"),
                Snippet(name: "Address", abbreviation: "addr", text: "12 Analytical Row"),
            ]
            #expect(ClipSearch.snippets(snippets, query: "sig").map(\.abbreviation) == ["sig", "sigl"])
            #expect(ClipSearch.snippets(snippets, query: "SIG").first?.abbreviation == "sig")
            #expect(ClipSearch.snippets(snippets, query: "analytical").map(\.name) == ["Address"])
            #expect(ClipSearch.snippets(snippets, query: "").count == 3)
            #expect(ClipSearch.snippets(snippets, query: "nothing").isEmpty)
        }
    }
}

// MARK: - Types and colors

extension ClipboardHistoryTests {
    @Suite struct ContentTypes {
        @Test func classifiesLinks() {
            #expect(ClipContentType.of(clip("https://example.com/a?b=c")) == .link)
            #expect(ClipContentType.of(clip("  https://example.com\n")) == .link)
            #expect(ClipContentType.of(clip("mailto:ada@example.com")) == .link)
            #expect(ClipContentType.of(clip("file:///Users/ada/notes.txt")) == .link)
            #expect(ClipContentType.of(clip("see https://example.com")) == .text)
            #expect(ClipContentType.of(clip("mailto:")) == .text)
            #expect(ClipContentType.of(clip("https://")) == .text)
        }

        @Test func classifiesColors() {
            for value in ["#FF5F4A", "#fff", "#FF5F4A80", "0xFF5F4A", "rgb(10, 132, 255)", "rgba(10,132,255,0.5)",
                          "hsl(211, 100%, 52%)", "hsla(211 100% 52% / 50%)"] {
                #expect(ClipContentType.of(clip(value)) == .color, "\(value)")
            }
            for value in ["#GG0000", "#12345", "rgb(300, 0, 0)", "hsl(10, 50, 50)", "#FF5F4A is the accent"] {
                #expect(ClipContentType.of(clip(value)) != .color, "\(value)")
            }
        }

        @Test func classifiesCode() {
            let swift = "let total = cart.items.reduce(0) { $0 + $1.price }\nreceipt.totalLabel.text = total.formatted()"
            #expect(ClipContentType.of(clip(swift)) == .code)
            #expect(ClipContentType.of(clip("git push origin main --force")) == .code)
            #expect(ClipContentType.of(clip("{ \"name\": \"Ada\" }")) == .code)
            #expect(ClipContentType.of(clip("func greet() {\n    print(\"hi\")\n}")) == .code)
            #expect(ClipContentType.of(clip("SELECT id, name FROM users WHERE active = 1;")) == .code)
        }

        @Test func proseStaysText() {
            #expect(ClipContentType.of(clip("Open the file and check the totals.")) == .text)
            #expect(ClipContentType.of(clip("Hi Ada,\n\nThe launch review moved to Thursday at 14:00.\n\nThanks,\nGrace")) == .text)
            #expect(ClipContentType.of(clip("Room B · 4th floor, left after the lifts")) == .text)
            #expect(ClipContentType.of(clip("")) == .text)
        }

        @Test func classifiesByKind() {
            #expect(ClipContentType.of(clip("Hello world", kind: .html)) == .richText)
            #expect(ClipContentType.of(clip("Hello world", kind: .richText)) == .richText)
            #expect(ClipContentType.of(clip("https://example.com", kind: .html)) == .link)
            #expect(ClipContentType.of(clip(nil, kind: .image, image: Data([1, 2, 3]))) == .image)
            // An image entry whose image data is gone falls back to its text.
            #expect(ClipContentType.of(clip("#00FF00", kind: .image)) == .color)
            #expect(ClipContentType.of(clip("/tmp/a.txt", kind: .files, files: [URL(fileURLWithPath: "/tmp/a.txt")])) == .file)
        }

        @Test func parsesColorValues() throws {
            let hex = try #require(ColorValue.parse("#FF5F4A"))
            #expect(hex.red == 1 && abs(hex.green - 95.0 / 255) < 1e-9 && abs(hex.blue - 74.0 / 255) < 1e-9 && hex.alpha == 1)
            #expect(ColorValue.parse("#fff") == RGBA(red: 1, green: 1, blue: 1))
            #expect(ColorValue.parse("rgba(255, 0, 0, 0.5)") == RGBA(red: 1, green: 0, blue: 0, alpha: 0.5))
            #expect(ColorValue.parse("rgb(100%, 0%, 0%)") == RGBA(red: 1, green: 0, blue: 0))
            let red = try #require(ColorValue.parse("hsl(0, 100%, 50%)"))
            #expect(abs(red.red - 1) < 1e-9 && abs(red.green) < 1e-9 && abs(red.blue) < 1e-9)
            let gray = try #require(ColorValue.parse("hsl(120deg, 0%, 25%)"))
            #expect(gray == RGBA(red: 0.25, green: 0.25, blue: 0.25))
            #expect(ColorValue.parse("rgb(1, 2)") == nil)
            #expect(ColorValue.parse("rgba(1, 2, 3, 2)") == nil)
            #expect(ColorValue.parse(String(repeating: "#", count: 80)) == nil)
        }

        @Test func formatsColorValues() throws {
            let c = try #require(ColorValue.parse("#FF5F4A"))
            #expect(ColorValue.rgbString(c) == "rgb(255, 95, 74)")
            #expect(ColorValue.hslString(c) == "hsl(7, 100%, 65%)")
            #expect(ColorValue.rgbString(RGBA(red: 0, green: 0, blue: 1, alpha: 0.5)) == "rgba(0, 0, 255, 0.50)")
            #expect(ColorValue.hslString(RGBA(red: 0.5, green: 0.5, blue: 0.5)) == "hsl(0, 0%, 50%)")
        }

        @Test func textHelpers() {
            #expect(ClipText.oneLine("  Hi Ada,\n\n  the review\tmoved  ") == "Hi Ada, the review moved")
            #expect(ClipText.oneLine("abcdef", limit: 3) == "abc…")
            #expect(ClipText.oneLine(" \n ") == "")
            #expect(ClipText.lineCount("") == 0)
            #expect(ClipText.lineCount("one") == 1)
            #expect(ClipText.lineCount("one\ntwo") == 2)
            #expect(ClipText.lineCount("one\ntwo\n") == 2)
            #expect(ClipText.firstLine("\n\n  Launch checklist  \nRecord") == "Launch checklist")
            #expect(ClipText.firstLine("abcdef", limit: 4) == "abcd…")
            #expect(ClipText.host(of: URL(string: "https://www.github.com/a")!) == "github.com")
            #expect(ClipText.host(of: URL(string: "mailto:ada@example.com")!) == "ada@example.com")
        }

        @Test func displayTitles() {
            #expect(clip("  first\nsecond  ").displayTitle == "first second")
            #expect(clip("ignored", name: "Wi-Fi password").displayTitle == "Wi-Fi password")
            let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
            #expect(clip(nil, kind: .files, files: [files[0]]).displayTitle == "a.txt")
            #expect(clip("x", kind: .files, files: files).plainText == "/tmp/a.txt\n/tmp/b.txt")
            #expect(clip(nil, kind: .image, image: Data([1])).hasText == false)
            #expect(clip("words").hasText)
        }
    }
}

// MARK: - Privacy and retention

extension ClipboardHistoryTests {
    @Suite struct Privacy {
        @Test func concealedAndTransientTypesArePrivate() {
            typealias T = NSPasteboard.PasteboardType
            #expect(ClipboardHistory.isPrivate([.string, T("org.nspasteboard.ConcealedType")]))
            #expect(ClipboardHistory.isPrivate([T("org.nspasteboard.TransientType"), .string]))
            #expect(ClipboardHistory.isPrivate([T("org.nspasteboard.AutoGeneratedType")]))
            #expect(ClipboardHistory.isPrivate([.string, T("com.agilebits.onepassword")]))
            #expect(!ClipboardHistory.isPrivate([.string, .rtf, .html, T("org.nspasteboard.source")]))
            #expect(!ClipboardHistory.isPrivate([]))
        }

        @Test func concealedCopiesOnAPasteboardAreDetected() {
            let pb = NSPasteboard(name: NSPasteboard.Name("mactoys.tests.clipboard.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.setString("hunter2", forType: .string)
            #expect(!ClipboardHistory.isPrivate(pb.types ?? []))
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            #expect(ClipboardHistory.isPrivate(pb.types ?? []))
        }

        @Test func pruneKeepsTheNewestUpToTheLimit() {
            let items = (0..<6).map { clip("item \($0)", ago: TimeInterval($0) * 60) }
            #expect(texts(ClipboardHistory.pruned(items, limit: 3, maxAge: nil, now: now)) == ["item 0", "item 1", "item 2"])
            #expect(ClipboardHistory.pruned(items, limit: 10, maxAge: nil, now: now).count == 6)
        }

        @Test func pinnedItemsNeverExpireAndDontCount() {
            let items = [
                clip("new", ago: 60),
                clip("pinned old", ago: 400 * 86_400, pinned: true),
                clip("yesterday", ago: 86_400 + 60),
                clip("an hour ago", ago: 3600),
                clip("last month", ago: 40 * 86_400),
            ]
            #expect(texts(ClipboardHistory.pruned(items, limit: 2, maxAge: nil, now: now)) == ["new", "pinned old", "yesterday"])
            #expect(texts(ClipboardHistory.pruned(items, limit: 100, maxAge: 86_400, now: now)) == ["new", "pinned old", "an hour ago"])
            // Expired entries don't use up the limit.
            let sorted = items.sorted { $0.date > $1.date }
            #expect(texts(ClipboardHistory.pruned(sorted, limit: 2, maxAge: 86_400, now: now)) == ["new", "an hour ago", "pinned old"])
        }

        @Test func retentionSettings() {
            #expect(ClipboardSettings.Retention.day.interval == 86_400)
            #expect(ClipboardSettings.Retention.month.interval == TimeInterval(30 * 86_400))
            #expect(ClipboardSettings.Retention.forever.interval == nil)
            let s = ClipboardSettings()
            #expect(s.maxItems == 500 && s.retention == .month && !s.paused)
            #expect(s.excludedApps.contains("com.apple.Passwords") && s.excludedApps.contains("com.apple.keychainaccess"))
            #expect(s.excludedApps.contains("1Password") && s.excludedApps.contains("Bitwarden"))
        }

        @Test func settingsRoundTrip() throws {
            var s = ClipboardSettings()
            s.style = .bar
            s.stackOrder = .reverse
            s.excludedApps = ["com.example.vault"]
            s.pauseShortcut = nil
            s.retention = .forever
            let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: JSONEncoder().encode(s))
            #expect(decoded == s)
        }
    }
}

// MARK: - Snippets

extension ClipboardHistoryTests {
    @Suite struct Snippets {
        private let date = ISO8601DateFormatter().date(from: "2026-03-05T14:30:00Z")!

        private func expand(_ template: String, clipboard: String? = nil) -> SnippetExpander.Result {
            SnippetExpander.expand(template, date: date, clipboard: clipboard, locale: en, timeZone: utc)
        }

        @Test func datesAndTimes() {
            #expect(expand("{date:yyyy-MM-dd}").text == "2026-03-05")
            #expect(expand("Due {date:EEEE, d MMM}").text == "Due Thursday, 5 Mar")
            #expect(expand("{date}").text == "March 5, 2026")
            let time = expand("{time}").text
            #expect(time.hasPrefix("2:30") && time.hasSuffix("PM"))
            let both = expand("{datetime}").text
            #expect(both.hasPrefix("Mar 5, 2026") && both.contains("2:30"))
        }

        @Test func placeholdersIgnoreCaseAndSpaces() {
            #expect(expand("{DATE:yyyy}").text == "2026")
            #expect(expand("{ Clipboard }", clipboard: "abc").text == "abc")
        }

        @Test func clipboardText() {
            #expect(expand("> {clipboard}", clipboard: "a quote").text == "> a quote")
            #expect(expand("[{clipboard}]").text == "[]")
        }

        @Test func cursorPosition() {
            let r = expand("Hello {cursor}world")
            #expect(r.text == "Hello world")
            #expect(r.cursorOffset == 5)
            #expect(expand("{cursor}").cursorOffset == 0)
            #expect(expand("no cursor").cursorOffset == nil)
            // Only the first cursor counts; later ones are dropped.
            let twice = expand("a{cursor}b{cursor}c")
            #expect(twice.text == "abc")
            #expect(twice.cursorOffset == 2)
            // The offset is counted in the expanded text.
            let mixed = expand("{cursor} — {date:yyyy}", clipboard: nil)
            #expect(mixed.text == " — 2026" && mixed.cursorOffset == 7)
        }

        @Test func unknownBracesStayAsTyped() {
            #expect(expand("{name} and {date:} and {cursor:x}").text == "{name} and {date:} and {cursor:x}")
            #expect(expand("open { brace").text == "open { brace")
            #expect(expand("{}").text == "{}")
            #expect(expand("func f() { return {date:yyyy} }").text == "func f() { return 2026 }")
        }
    }
}

// MARK: - Paste stack and merging

extension ClipboardHistoryTests {
    @Suite struct Stack {
        private let a = clip("a", ago: 30), b = clip("b", ago: 20), c = clip("c", ago: 10)

        @Test func copyOrderPastesTheFirstCopyFirst() {
            var stack = PasteStack(order: .copyOrder)
            stack.push(contentsOf: [a, b, c])
            #expect(texts(stack.queue) == ["a", "b", "c"])
            #expect(stack.advance()?.text == "a")
            #expect(stack.advance()?.text == "b")
            #expect(stack.count == 1 && stack.next?.text == "c")
        }

        @Test func reverseOrderPastesTheLatestCopyFirst() {
            var stack = PasteStack(order: .reverse)
            stack.push(contentsOf: [a, b, c])
            #expect(texts(stack.queue) == ["c", "b", "a"])
            #expect(stack.advance()?.text == "c")
            stack.push(clip("d"))
            #expect(texts(stack.queue) == ["d", "b", "a"])
        }

        @Test func switchingOrderKeepsTheItems() {
            var stack = PasteStack(order: .copyOrder, items: [a, b])
            stack.order = .reverse
            #expect(texts(stack.queue) == ["b", "a"])
        }

        @Test func repeatedCopiesAreAddedOnce() {
            var stack = PasteStack()
            stack.push(a)
            stack.push(clip("a"))
            stack.push(b)
            stack.push(clip("a"))
            #expect(texts(stack.queue) == ["a", "b", "a"])
        }

        @Test func removeAndClear() {
            var stack = PasteStack(items: [a, b, c])
            stack.remove(b.id)
            #expect(texts(stack.queue) == ["a", "c"])
            stack.clear()
            #expect(stack.isEmpty && stack.advance() == nil)
        }

        @Test func mergeJoinsTextsWithTheSeparator() {
            #expect(ClipMerge.merge([a, b, c], separator: ", ")?.text == "a, b, c")
            #expect(ClipMerge.merge([a, b], separator: "\n")?.kind == .text)
            #expect(ClipMerge.merge([a], separator: "\n") == nil)
            // Images have no text: fewer than two texts merge to nothing.
            #expect(ClipMerge.merge([a, clip(nil, kind: .image, image: Data([1]))], separator: "\n") == nil)
        }

        @Test func mergeCombinesFiles() throws {
            let x = URL(fileURLWithPath: "/tmp/x.txt"), y = URL(fileURLWithPath: "/tmp/y.txt")
            let merged = try #require(ClipMerge.merge([clip("x", kind: .files, files: [x, y]), clip("y", kind: .files, files: [y])],
                                                      separator: "\n"))
            #expect(merged.kind == .files && merged.files == [x, y])
            #expect(merged.text == "/tmp/x.txt\n/tmp/y.txt")
            // Files with text: the paths join the text.
            #expect(ClipMerge.merge([a, clip("x", kind: .files, files: [x])], separator: " ")?.text == "a /tmp/x.txt")
        }
    }
}

// MARK: - Storage

extension ClipboardHistoryTests {
    @Suite struct Storage {
        private func tempDirectory() throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-clipboard-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        @MainActor @Test func pinboardsAndSnippetsRoundTrip() throws {
            let dir = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("library.json")

            let library = ClipLibrary(file: file)
            let board = library.createPinboard(name: "Launch", tint: .indigo)
            library.add([clip("https://mactoys.app", name: "Release page", pinned: true), clip("#5E5CE6")], to: board.id)
            library.createPinboard(name: "Design")
            library.addSnippet(Snippet(name: "Signature", abbreviation: "sig", text: "Best,\n{cursor}"))
            library.flush()
            ClipLibrary.waitForSaves()

            let reloaded = ClipLibrary(file: file)
            #expect(reloaded.data == library.data)
            #expect(reloaded.pinboards.map(\.name) == ["Launch", "Design"])
            #expect(reloaded.pinboards[0].tint == .indigo)
            #expect(texts(reloaded.pinboards[0].items) == ["Release page", "#5E5CE6"])
            #expect(reloaded.snippets.first?.abbreviation == "sig")
        }

        @MainActor @Test func addingToAPinboardCopiesAndDeduplicates() throws {
            let library = ClipLibrary(file: nil)
            let board = library.createPinboard(name: "Board")
            let original = clip("hello", pinned: true)
            library.add([original], to: board.id)
            let copy = try #require(library.pinboard(board.id)?.items.first)
            #expect(copy.id != original.id && !copy.pinned && copy.text == "hello")

            library.add([clip("other")], to: board.id)
            library.add([clip("hello", name: "Greeting")], to: board.id)
            let items = try #require(library.pinboard(board.id)?.items)
            #expect(texts(items) == ["Greeting", "other"])
            #expect(items[0].id == copy.id)

            library.remove([copy.id], from: board.id)
            #expect(texts(library.pinboard(board.id)?.items ?? []) == ["other"])
            library.deletePinboard(board.id)
            #expect(library.pinboards.isEmpty)
        }

        @MainActor @Test func newPinboardsCycleTheirColors() {
            let library = ClipLibrary(file: nil)
            let tints = (0..<3).map { library.createPinboard(name: "B\($0)").tint }
            #expect(tints == Array(Pinboard.tints.prefix(3)))
        }

        @MainActor @Test func unreadableLibraryStartsEmpty() throws {
            let dir = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("library.json")
            try Data("not json".utf8).write(to: file)
            let library = ClipLibrary(file: file)
            #expect(library.pinboards.isEmpty && library.snippets.isEmpty)
        }

        @Test func historyKeepsImagesInSidecarFiles() throws {
            let dir = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let list = dir.appendingPathComponent("history.json")
            let images = dir.appendingPathComponent("Images")
            let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
            let picture = clip(nil, kind: .image, image: png)
            let text = clip("words", app: "Notes", bundleID: "com.apple.Notes", name: "Named")

            ClipboardStore.save([picture, text], to: list, images: images)
            let sidecar = ClipboardStore.imageFile(for: picture.id, in: images)
            #expect(try Data(contentsOf: sidecar) == png)
            let raw = try JSONDecoder().decode([ClipItem].self, from: Data(contentsOf: list))
            #expect(raw.allSatisfy { $0.image == nil })

            let loaded = ClipboardStore.load(from: list, images: images)
            #expect(loaded == [picture, text])

            // An entry that's gone takes its image file with it.
            try Data([0]).write(to: images.appendingPathComponent("stale.png"))
            ClipboardStore.save([text], to: list, images: images)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(!FileManager.default.fileExists(atPath: images.appendingPathComponent("stale.png").path))
            #expect(ClipboardStore.load(from: list, images: images) == [text])
        }

        @Test func historyWithInlineImagesStillLoads() throws {
            let dir = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let list = dir.appendingPathComponent("history.json")
            let picture = clip(nil, kind: .image, image: Data([9, 8, 7]))
            try JSONEncoder().encode([picture]).write(to: list)
            #expect(ClipboardStore.load(from: list, images: dir.appendingPathComponent("Images")) == [picture])
            #expect(ClipboardStore.load(from: dir.appendingPathComponent("missing.json"), images: dir).isEmpty)
        }
    }
}

// MARK: - Panel model

@MainActor
private final class RecordingHost: ClipboardPanelHost {
    var pasted: [(item: ClipItem, plain: Bool, original: ClipItem?)] = []
    var copied: [(item: ClipItem, plain: Bool)] = []
    var snippets: [(snippet: Snippet, plain: Bool, copyOnly: Bool)] = []
    var stacked: [[ClipItem]] = []

    func paste(_ item: ClipItem, plain: Bool, original: ClipItem?) { pasted.append((item, plain, original)) }
    func copy(_ item: ClipItem, plain: Bool) { copied.append((item, plain)) }
    func pasteSnippet(_ snippet: Snippet, plain: Bool, copyOnly: Bool) { snippets.append((snippet, plain, copyOnly)) }
    func addToStack(_ items: [ClipItem]) { stacked.append(items) }
    func open(_ url: URL) {}
    func reveal(_ urls: [URL]) {}
    func closePanel() {}
    func openSettings() {}
}

extension ClipboardHistoryTests {
    @MainActor
    @Suite struct PanelModel {
        private let host = RecordingHost()

        private func model(_ items: [ClipItem], snippets: [Snippet] = [], settings: ClipboardSettings = ClipboardSettings()) -> ClipboardPanelModel {
            let m = ClipboardPanelModel(history: SampleHistory(items), library: ClipLibrary(file: nil, initial: LibraryData(snippets: snippets)),
                                        settings: settings)
            m.host = host
            return m
        }

        @Test func numbersTheFirstNineRows() {
            let m = model((0..<12).map { clip("item \($0)", ago: TimeInterval($0)) })
            #expect(m.rows.map(\.number) == (1...9).map(Optional.init) + [nil, nil, nil])
        }

        @Test func searchShowsMatchingSnippetsFirst() {
            let m = model([clip("sig sauce"), clip("other")],
                          snippets: [Snippet(name: "Email signature", abbreviation: "sig", text: "Best,\nAda")])
            m.query = "sig"
            #expect(m.rows.first?.snippet?.abbreviation == "sig")
            #expect(m.rows.dropFirst().compactMap(\.clip?.text) == ["sig sauce"])
            // A filter means the user is looking for history entries only.
            m.filter.type = .text
            #expect(m.rows.allSatisfy { $0.clip != nil })
        }

        @Test func returnPastesAndShiftReturnPastesPlainText() throws {
            let first = clip("first", ago: 10), second = clip("second", ago: 20)
            let m = model([first, second])
            m.select(1)
            m.activate()
            m.activate(plain: true)
            #expect(host.pasted.map(\.item.id) == [second.id, second.id])
            #expect(host.pasted.map(\.plain) == [false, true])
            #expect(host.pasted.first?.original?.id == second.id)

            var settings = ClipboardSettings()
            settings.returnAction = .copy
            let copying = model([first], settings: settings)
            copying.activate()
            #expect(host.copied.map(\.item.id) == [first.id])
        }

        @Test func markedRowsPasteMerged() throws {
            let m = model([clip("one", ago: 10), clip("two", ago: 20), clip("three", ago: 30)])
            m.select(0)
            m.select(2, toggle: true)
            #expect(m.targetClips.map(\.text) == ["one", "three"])
            m.perform(.paste)
            let pasted = try #require(host.pasted.last)
            #expect(pasted.item.text == "one\nthree" && pasted.original == nil)
        }

        @Test func shiftSelectsARange() {
            let m = model((0..<5).map { clip("item \($0)", ago: TimeInterval($0)) })
            m.select(1)
            m.select(3, extend: true)
            #expect(m.targetClips.compactMap(\.text) == ["item 1", "item 2", "item 3"])
            m.move(1)
            #expect(m.marked.isEmpty && m.selection == 4)
        }

        @Test func mergeAddsANewEntryOnTop() {
            var settings = ClipboardSettings()
            settings.mergeSeparator = .comma
            let m = model([clip("one", ago: 10), clip("two", ago: 20), clip("three", ago: 30)], settings: settings)
            m.now = { now }
            m.select(1)
            m.select(2, toggle: true)
            m.perform(.merge)
            #expect(m.history.items.first?.text == "two, three")
            #expect(m.history.items.count == 4)
            #expect(m.marked.isEmpty)
            #expect(m.selectedRow?.clip?.text == "two, three")
        }

        @Test func renameAndEdit() throws {
            let item = clip("total = 42", kind: .html)
            let m = model([item])
            m.perform(.rename)
            #expect(m.mode == .renaming(item.id, ""))
            m.mode = .renaming(item.id, "  Cart total ")
            m.commitSheet()
            #expect(m.history.items.first?.name == "Cart total")
            #expect(m.mode == .browse)
            m.refresh()

            m.mode = .renaming(item.id, "   ")
            m.commitSheet()
            #expect(m.history.items.first?.name == nil)
            m.refresh()

            m.perform(.edit)
            #expect(m.mode == .editing(item.id, "total = 42"))
            m.mode = .editing(item.id, "total = 43")
            m.commitSheet()
            let edited = try #require(m.history.items.first)
            // Edited rich text becomes plain text.
            #expect(edited.text == "total = 43" && edited.kind == .text && edited.html == nil)
        }

        @Test func deleteRemovesTheMarkedEntries() {
            let m = model([clip("a", ago: 1), clip("b", ago: 2), clip("c", ago: 3)])
            m.select(0)
            m.select(2, toggle: true)
            m.perform(.delete)
            m.refresh()
            #expect(m.rows.compactMap(\.clip?.text) == ["b"])
        }

        @Test func pinboardSourceShowsItsItems() {
            let m = model([clip("history entry")])
            let board = m.library.createPinboard(name: "Launch")
            m.library.add([clip("on the board")], to: board.id)
            m.source = .pinboard(board.id)
            #expect(m.rows.compactMap(\.clip?.text) == ["on the board"])
            m.perform(.delete)
            #expect(m.library.pinboard(board.id)?.items.isEmpty == true)
            #expect(m.history.items.count == 1)
            m.cycleSource(1)
            #expect(m.source == .snippets)
            m.cycleSource(1)
            #expect(m.source == .history)
        }

        @Test func pinTogglesTogether() {
            let m = model([clip("a", ago: 1, pinned: true), clip("b", ago: 2)])
            m.select(0)
            m.select(1, toggle: true)
            m.perform(.togglePin)
            #expect(m.history.items.allSatisfy { $0.pinned })
            m.refresh()
            m.perform(.togglePin)
            #expect(m.history.items.allSatisfy { !$0.pinned })
        }

        @Test func pasteStackGetsMarkedEntriesInCopyOrder() {
            let m = model([clip("newest", ago: 1), clip("middle", ago: 2), clip("oldest", ago: 3)])
            m.select(0)
            m.select(2, extend: true)
            m.perform(.addToStack)
            #expect(host.stacked.last.map(texts) == ["oldest", "middle", "newest"])
        }

        @Test func snippetsPasteThroughTheHost() {
            let snippet = Snippet(name: "Signature", abbreviation: "sig", text: "Best")
            let m = model([], snippets: [snippet])
            m.source = .snippets
            m.perform(.copy)
            m.activate(plain: true)
            #expect(host.snippets.map(\.copyOnly) == [true, false])
            #expect(host.snippets.map(\.plain) == [false, true])
        }

        @Test func clearKeepsPinnedEntries() {
            let m = model([clip("a", pinned: true), clip("b")])
            m.perform(.clearHistory)
            #expect(m.mode == .confirmClear)
            m.commitSheet()
            #expect(texts(m.history.items) == ["a"])
        }
    }
}
