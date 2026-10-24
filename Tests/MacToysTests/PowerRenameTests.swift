import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacToysCore
@testable import PowerRename

@Suite struct PowerRenameTests {
    // MARK: Helpers

    private func engine(_ configure: (inout RenameOptions) -> Void, flavor: RegexFlavor = .standard) -> RenameEngine {
        var o = RenameOptions()
        o.enumerate = false
        configure(&o)
        return RenameEngine(options: o, flavor: flavor, seed: 42)
    }

    private func rename(_ name: String, isFolder: Bool = false, flavor: RegexFlavor = .standard,
                        _ configure: (inout RenameOptions) -> Void) throws -> String? {
        try engine(configure, flavor: flavor).newName(for: name, isFolder: isFolder)
    }

    private func items(_ names: [String], in folder: String = "/tmp/pr-test") -> [RenameItem] {
        names.enumerated().map { RenameItem(id: $0.offset, url: URL(fileURLWithPath: folder).appendingPathComponent($0.element)) }
    }

    private func plan(_ names: [String], unchecked: Set<Int> = [], existing: [String] = [],
                      _ configure: (inout RenameOptions) -> Void) throws -> [RenamePreview] {
        let env = RenameEnvironment(existingNames: { _ in existing + names })
        return try engine(configure).plan(items(names), unchecked: unchecked, environment: env)
    }

    // MARK: Search and replace

    @Test func matchAllOccurrences() throws {
        let first = try rename("powertoys-powerrename.txt") { $0.search = "power"; $0.replace = "super" }
        #expect(first == "supertoys-powerrename.txt")
        let all = try rename("powertoys-powerrename.txt") { $0.search = "power"; $0.replace = "super"; $0.matchAll = true }
        #expect(all == "supertoys-superrename.txt")
    }

    @Test func caseSensitivity() throws {
        #expect(try rename("Powertoys.txt") { $0.search = "power"; $0.replace = "x" } == "xtoys.txt")
        #expect(try rename("Powertoys.txt") { $0.search = "power"; $0.replace = "x"; $0.caseSensitive = true } == nil)
    }

    @Test func plainTextTreatsRegexCharactersLiterally() throws {
        #expect(try rename("a.b(1).txt") { $0.search = "(1)"; $0.replace = "[2]" } == "a.b[2].txt")
        #expect(try rename("price.txt") { $0.search = "price"; $0.replace = "$1 cost" } == "$1 cost.txt")
    }

    @Test func noMatchLeavesNameAlone() throws {
        #expect(try rename("notes.txt") { $0.search = "IMG"; $0.replace = "x" } == nil)
        #expect(try rename("notes.txt") { $0.search = ""; $0.replace = "x" } == nil)
    }

    @Test func invalidRegexThrows() {
        #expect(throws: RenameEngine.InvalidPattern.self) {
            try rename("a.txt") { $0.search = "(unclosed"; $0.useRegex = true }
        }
    }

    // MARK: Regular expressions (documented examples)

    @Test func regexCaptureGroupsReorder() throws {
        let r = try rename("29-03-2020.txt") {
            $0.search = #"(\d\d)-(\d\d)-(\d\d\d\d)"#; $0.replace = "$3-$2-$1"; $0.useRegex = true; $0.matchAll = true
        }
        #expect(r == "2020-03-29.txt")
    }

    @Test func regexWholeNameAppendsOnce() throws {
        let r = try rename("readme") { $0.search = "(.*)"; $0.replace = "$1.txt"; $0.useRegex = true; $0.matchAll = true }
        #expect(r == "readme.txt")
        let star = try rename("abc.png") { $0.search = ".*"; $0.replace = "X"; $0.useRegex = true; $0.matchAll = true }
        #expect(star == "X.png")
    }

    @Test func regexAnchorsInsertAndTrim() throws {
        #expect(try rename("photo.jpg") { $0.search = "^"; $0.replace = "foo_"; $0.useRegex = true } == "foo_photo.jpg")
        #expect(try rename("photo.jpg") { $0.search = "$"; $0.replace = "_bar"; $0.useRegex = true } == "photo_bar.jpg")
        #expect(try rename("photo.jpg") { $0.search = "^.{2}"; $0.replace = ""; $0.useRegex = true } == "oto.jpg")
        let ins = try rename("photo.jpg") { $0.search = "^(.{2})(.*)"; $0.replace = "$1foo$2"; $0.useRegex = true }
        #expect(ins == "phfoooto.jpg")
        #expect(try rename("foo123bar.txt") { $0.search = ".+?(?=bar)"; $0.replace = "X"; $0.useRegex = true } == "Xbar.txt")
    }

    @Test func regexLookbehindWorks() throws {
        #expect(try rename("v2-final.txt") { $0.search = "(?<=v)\\d"; $0.replace = "3"; $0.useRegex = true } == "v3-final.txt")
    }

    @Test func groupReferenceEdgeCases() throws {
        // $10 with a single group is group 1 followed by "0"; a missing group stays literal.
        #expect(try rename("ab.txt") { $0.search = "(a)"; $0.replace = "$10"; $0.useRegex = true } == "a0b.txt")
        #expect(try rename("ab.txt") { $0.search = "(a)"; $0.replace = "$5"; $0.useRegex = true } == "$5b.txt")
        #expect(try rename("ab.txt") { $0.search = "a"; $0.replace = "[$&]"; $0.useRegex = true } == "[a]b.txt")
        #expect(try rename("abc.txt") { $0.search = "b"; $0.replace = "<$`|$'>"; $0.useRegex = true } == "a<a|c>c.txt")
        #expect(try rename("ab.txt") { $0.search = "a"; $0.replace = "$$1"; $0.useRegex = true } == "$1b.txt")
    }

    @Test func standardFlavorKeepsBackslashes() throws {
        #expect(try rename("ab.txt") { $0.search = "a"; $0.replace = #"x\y"#; $0.useRegex = true } == #"x\yb.txt"#)
    }

    @Test func extendedFlavorCaseConversionAndNamedGroups() throws {
        let upper = try rename("hello world.txt", flavor: .extended) {
            $0.search = "(\\w+) (\\w+)"; $0.replace = #"\U$1\E $2"#; $0.useRegex = true
        }
        #expect(upper == "HELLO world.txt")
        let first = try rename("hello.txt", flavor: .extended) { $0.search = "(.+)"; $0.replace = #"\u$1"#; $0.useRegex = true }
        #expect(first == "Hello.txt")
        let named = try rename("2024-05.txt", flavor: .extended) {
            $0.search = #"(?<y>\d{4})-(?<m>\d{2})"#; $0.replace = "${m}_$+{y}_${1}"; $0.useRegex = true
        }
        #expect(named == "05_2024_2024.txt")
        let escaped = try rename("a.txt", flavor: .extended) { $0.search = "a"; $0.replace = #"\$1\\"#; $0.useRegex = true }
        #expect(escaped == #"$1\.txt"#)
    }

    // MARK: Enumeration

    @Test func documentedEnumerationExample() throws {
        let rows = try plan(["a.jpg", "ab.jpg", "abc.jpg"]) {
            $0.search = "a"; $0.replace = "Image_${padding=4;increment=2;start=10}_"; $0.enumerate = true
        }
        #expect(rows.map(\.newName) == ["Image_0010_.jpg", "Image_0012_b.jpg", "Image_0014_bc.jpg"])
    }

    @Test func enumerationCommaSyntaxAndSimpleCounter() throws {
        let rows = try plan(["x1.txt", "x2.txt", "x3.txt"]) {
            $0.search = "x"; $0.replace = "${start=10,increment=2,padding=4}-${}-"; $0.enumerate = true
        }
        #expect(rows.map(\.newName) == ["0010-0-1.txt", "0012-1-2.txt", "0014-2-3.txt"])
    }

    @Test func counterOnlyCountsRenamedItems() throws {
        let rows = try plan(["IMG_1.HEIC", "notes.txt", "IMG_2.HEIC"], unchecked: []) {
            $0.search = #"IMG_(\d+)"#; $0.replace = "Trip-${start=1,padding=3}-$1"; $0.useRegex = true; $0.enumerate = true
        }
        #expect(rows.map(\.newName) == ["Trip-001-1.HEIC", nil, "Trip-002-2.HEIC"])
        let skipping = try plan(["a1.txt", "a2.txt", "a3.txt"], unchecked: [1]) {
            $0.search = "a"; $0.replace = "${start=1}_"; $0.enumerate = true
        }
        #expect(skipping.map(\.newName) == ["1_1.txt", nil, "2_3.txt"])
        #expect(skipping[1].status == .unchecked)
    }

    @Test func negativeIncrementAndDisabledEnumeration() throws {
        let rows = try plan(["a.txt", "a2.txt"]) { $0.search = "a"; $0.replace = "${start=1,increment=-2,padding=2}"; $0.enumerate = true }
        #expect(rows.map(\.newName) == ["01.txt", "-012.txt"])
        let off = try rename("a.txt") { $0.search = "a"; $0.replace = "${start=1}"; $0.enumerate = false }
        #expect(off == "${start=1}.txt")
        let junk = try rename("a.txt") { $0.search = "a"; $0.replace = "${start=x}"; $0.enumerate = true }
        #expect(junk == "${start=x}.txt")
    }

    // MARK: Random values

    @Test func randomStrings() throws {
        let alnum = try #require(try rename("a.txt") { $0.search = "a"; $0.replace = "${rstringalnum=12}"; $0.randomize = true })
        #expect(alnum.count == 12 + 4)
        #expect(alnum.dropLast(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let alpha = try #require(try rename("a.txt") { $0.search = "a"; $0.replace = "${rstringalpha=20}"; $0.randomize = true })
        #expect(alpha.dropLast(4).allSatisfy { $0.isASCII && $0.isLetter })
        let digits = try #require(try rename("a.txt") { $0.search = "a"; $0.replace = "${rstringdigit=7}"; $0.randomize = true })
        #expect(digits.dropLast(4).count == 7 && digits.dropLast(4).allSatisfy(\.isNumber))
        let uuid = try #require(try rename("a.txt") { $0.search = "a"; $0.replace = "{${ruuidv4}}"; $0.randomize = true })
        let pattern = try NSRegularExpression(pattern: #"^\{[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\}\.txt$"#)
        #expect(pattern.firstMatch(in: uuid, range: NSRange(uuid.startIndex..., in: uuid)) != nil)
    }

    @Test func randomValuesAreStableForPreviewAndDifferPerItem() throws {
        let configure: (inout RenameOptions) -> Void = { $0.search = "a"; $0.replace = "${rstringalnum=10}"; $0.randomize = true }
        let once = try plan(["a.txt", "a2.txt"], configure).map(\.newName)
        let twice = try plan(["a.txt", "a2.txt"], configure).map(\.newName)
        #expect(once == twice)
        #expect(once[0]?.prefix(10) != once[1]?.prefix(10))
        let off = try rename("a.txt") { $0.search = "a"; $0.replace = "${ruuidv4}"; $0.randomize = false }
        #expect(off == "${ruuidv4}.txt")
    }

    // MARK: Dates

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, ms: Int = 0) -> Date {
        var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        c.nanosecond = ms * 1_000_000 + 500
        return Calendar.current.date(from: c) ?? Date()
    }

    @Test func dateTokensFollowTheDocs() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let en = Locale(identifier: "en_US")
        var c = DateComponents(year: 2020, month: 11, day: 2, hour: 9, minute: 5, second: 7)
        c.nanosecond = 45_000_000 + 900
        let d = cal.date(from: c) ?? Date()
        let v = { (t: String) in DateTokens.value(of: t, date: d, calendar: cal, locale: en) }
        #expect(v("YYYY") == "2020" && v("YY") == "20" && v("Y") == "0")
        #expect(v("MMMM") == "November" && v("MMM") == "Nov" && v("MM") == "11" && v("M") == "11")
        #expect(v("DDDD") == "Monday" && v("DDD") == "Mon" && v("DD") == "02" && v("D") == "2")
        #expect(v("hh") == "09" && v("h") == "9" && v("mm") == "05" && v("m") == "5" && v("ss") == "07" && v("s") == "7")
        #expect(v("fff") == "045" && v("ff") == "04" && v("f") == "0")
        #expect(DateTokens.expand("$MMM-$DD-$YY-powertoys", date: d, calendar: cal, locale: en) == "Nov-02-20-powertoys")
        #expect(DateTokens.expand("cost $5 and $", date: d, calendar: cal, locale: en) == "cost $5 and $")
    }

    @Test func dateTokensInReplacementUseTheChosenFileDate() throws {
        let created = date(2020, 11, 2, 14, 30, 15, ms: 123)
        let modified = date(2023, 1, 9)
        let item = RenameItem(id: 0, url: URL(fileURLWithPath: "/tmp/powertoys.png"), created: created, modified: modified)
        var o = RenameOptions()
        o.search = "powertoys"
        o.replace = "$YYYY-$MM-$DD_$hh$mm$ss.$fff-powertoys"
        let rows = try RenameEngine(options: o).plan([item])
        #expect(rows[0].newName == "2020-11-02_143015.123-powertoys.png")
        o.dateSource = .modified
        o.replace = "$YYYY-$M-$D"
        #expect(try RenameEngine(options: o).plan([item])[0].newName == "2023-1-9.png")
        o.replace = "$$YYYY"
        #expect(try RenameEngine(options: o).plan([item])[0].newName == "$YYYY.png")
    }

    // MARK: Text formatting

    @Test func textFormats() {
        #expect(TextFormat.lowercase.apply("Hello World") == "hello world")
        #expect(TextFormat.uppercase.apply("Hello World") == "HELLO WORLD")
        #expect(TextFormat.titleCase.apply("the lord OF the rings") == "The Lord of the Rings")
        #expect(TextFormat.capitalized.apply("the lord OF the rings") == "The Lord Of The Rings")
        #expect(TextFormat.capitalized.apply("my_holiday-photo 2") == "My_Holiday-Photo 2")
        #expect(TextFormat.none.apply("aBc") == "aBc")
    }

    @Test func formattingAloneRenamesEverything() throws {
        let rows = try plan(["Report Final.PDF", "a.txt"]) { $0.textFormat = .uppercase }
        #expect(rows.map(\.newName) == ["REPORT FINAL.PDF", "A.txt"])
        let both = try plan(["the report.PDF"]) { $0.textFormat = .titleCase; $0.scope = .both }
        #expect(both[0].newName == "The Report.PDF")
        let lowerBoth = try plan(["Report.PDF"]) { $0.textFormat = .lowercase; $0.scope = .both }
        #expect(lowerBoth[0].newName == "report.pdf")
        let ext = try plan(["Report.PDF"]) { $0.textFormat = .lowercase; $0.scope = .extension }
        #expect(ext[0].newName == "Report.pdf")
        let after = try rename("img_1.jpg") { $0.search = "img"; $0.replace = "photo"; $0.textFormat = .capitalized }
        #expect(after == "Photo_1.jpg")
    }

    // MARK: Name, extension, both

    @Test func scopes() throws {
        #expect(try rename("txt.txt") { $0.search = "txt"; $0.replace = "NewName" } == "NewName.txt")
        #expect(try rename("txt.txt") { $0.search = "txt"; $0.replace = "NewExtension"; $0.scope = .extension } == "txt.NewExtension")
        #expect(try rename("txt.txt") { $0.search = "txt"; $0.replace = "x"; $0.scope = .both; $0.matchAll = true } == "x.x")
        #expect(try rename("photo.jpeg") { $0.search = "jpeg"; $0.replace = ""; $0.scope = .extension } == "photo")
        #expect(try rename("README") { $0.search = "x"; $0.replace = "y"; $0.scope = .extension } == nil)
    }

    @Test func foldersAndDotFilesHaveNoExtension() throws {
        #expect(try rename("my.folder", isFolder: true) { $0.search = "folder"; $0.replace = "dir" } == "my.dir")
        #expect(try rename("my.folder", isFolder: true) { $0.search = "my"; $0.replace = "x"; $0.scope = .extension } == nil)
        #expect(try rename(".zshrc") { $0.search = "zsh"; $0.replace = "bash" } == ".bashrc")
        #expect(RenameEngine.split("archive.tar.gz", isFolder: false) == ("archive.tar", "gz"))
        #expect(RenameEngine.split(".hidden", isFolder: false) == (".hidden", nil))
    }

    // MARK: Conflicts and invalid names

    @Test func conflictsInsideTheBatchGetANumber() throws {
        let rows = try plan(["a1.txt", "a2.txt", "a3.txt"]) { $0.search = #"\d"#; $0.replace = ""; $0.useRegex = true }
        #expect(rows.map(\.newName) == ["a.txt", "a (2).txt", "a (3).txt"])
        #expect(rows.map(\.status) == [.rename, .conflict, .conflict])
        #expect(rows[1].proposedName == "a.txt")
    }

    @Test func conflictsWithFilesOnDiskAreCaseInsensitive() throws {
        let rows = try plan(["draft.txt"], existing: ["Final.txt"]) { $0.search = "draft"; $0.replace = "final" }
        #expect(rows[0].newName == "final (2).txt")
        #expect(rows[0].status == .conflict)
        let caseOnly = try plan(["photo.JPG"]) { $0.search = "JPG"; $0.replace = "jpg"; $0.scope = .extension; $0.caseSensitive = true }
        #expect(caseOnly[0].newName == "photo.jpg")
        #expect(caseOnly[0].status == .rename)
    }

    @Test func swappingNamesIsNotAConflict() throws {
        // 1 → 2 and 2 → 1: each wanted name belongs to an item that moves away.
        let rows = try plan(["1.txt", "2.txt"]) {
            $0.search = #"\d"#; $0.useRegex = true; $0.replace = "${start=2,increment=-1}"; $0.enumerate = true
        }
        #expect(rows.map(\.newName) == ["2.txt", "1.txt"])
        #expect(rows.map(\.status) == [.rename, .rename])
    }

    @Test func invalidNamesAreFlagged() throws {
        let slash = try plan(["a.txt"]) { $0.search = "a"; $0.replace = "x/y" }
        #expect(slash[0].status == .invalid("Names can’t contain “/”"))
        #expect(slash[0].newName == nil)
        let empty = try plan(["a"]) { $0.search = "a"; $0.replace = "" }
        if case .invalid = empty[0].status {} else { Issue.record("empty name should be invalid") }
        #expect(RenameEngine.validate(String(repeating: "é", count: 128)) != nil)
        #expect(RenameEngine.validate("ok name.txt") == nil)
        #expect(RenameEngine.validate("..") != nil)
        #expect(RenameEngine.validate("a:b") != nil)
    }

    // MARK: Include and exclude

    @Test func includeOptionsAndExcludePatterns() throws {
        let list = [
            RenameItem(id: 0, url: URL(fileURLWithPath: "/t/Folder a"), isFolder: true, depth: 0),
            RenameItem(id: 1, url: URL(fileURLWithPath: "/t/Folder a/a.txt"), depth: 1),
            RenameItem(id: 2, url: URL(fileURLWithPath: "/t/a.tmp"), depth: 0),
            RenameItem(id: 3, url: URL(fileURLWithPath: "/t/a.jpg"), depth: 0),
        ]
        func names(_ configure: (inout RenameOptions) -> Void) throws -> [String?] {
            var o = RenameOptions()
            o.search = "a"; o.replace = "b"
            configure(&o)
            return try RenameEngine(options: o).plan(list).map(\.newName)
        }
        #expect(try names { _ in } == ["Folder b", "b.txt", "b.tmp", "b.jpg"])
        #expect(try names { $0.includeFolders = false } == [nil, "b.txt", "b.tmp", "b.jpg"])
        #expect(try names { $0.includeFiles = false } == ["Folder b", nil, nil, nil])
        #expect(try names { $0.includeSubfolders = false } == ["Folder b", nil, "b.tmp", "b.jpg"])
        #expect(try names { $0.exclude = "*.TMP; *.jpg" } == ["Folder b", "b.txt", nil, nil])
        let rows = try RenameEngine(options: { var o = RenameOptions(); o.search = "a"; o.exclude = "*.tmp"; return o }()).plan(list)
        #expect(rows[2].status == .skipped)
    }

    // MARK: Photo metadata

    @Test func metadataValuesFromImageIOProperties() {
        let props: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 4032, kCGImagePropertyPixelHeight as String: 3024,
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple",
                                                       kCGImagePropertyTIFFModel as String: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.78, kCGImagePropertyExifExposureTime as String: 0.004,
                kCGImagePropertyExifISOSpeedRatings as String: [125], kCGImagePropertyExifFocalLength as String: 6.765,
                kCGImagePropertyExifFlash as String: 16, kCGImagePropertyExifDateTimeOriginal as String: "2025:07:14 18:03:59",
                kCGImagePropertyExifColorSpace as String: 1, kCGImagePropertyExifExposureBiasValue as String: 0.3,
                kCGImagePropertyExifLensModel as String: "Main Camera",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 47.5, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.25, kCGImagePropertyGPSLongitudeRef as String: "W",
                kCGImagePropertyGPSAltitude as String: 12.0,
            ],
        ]
        let v = PhotoMetadata.values(from: props)
        #expect(v["CAMERA_MAKE"] == "Apple" && v["CAMERA_MODEL"] == "iPhone 17 Pro" && v["LENS"] == "Main Camera")
        #expect(v["APERTURE"] == "f1.8" && v["SHUTTER"] == "1-250s" && v["ISO"] == "125" && v["FOCAL"] == "6.8mm")
        #expect(v["FLASH"] == "Off" && v["WIDTH"] == "4032" && v["HEIGHT"] == "3024" && v["ORIENTATION"] == "6")
        #expect(v["DATE_TAKEN_YYYY"] == "2025" && v["DATE_TAKEN_YY"] == "25" && v["DATE_TAKEN_MM"] == "07")
        #expect(v["DATE_TAKEN_DD"] == "14" && v["DATE_TAKEN_HH"] == "18" && v["DATE_TAKEN_mm"] == "03" && v["DATE_TAKEN_SS"] == "59")
        #expect(v["LATITUDE"] == "47.5" && v["LONGITUDE"] == "-122.25" && v["ALTITUDE"] == "12m")
        #expect(v["COLOR_SPACE"] == "sRGB" && v["EXPOSURE_BIAS"] == "+0.3EV")
    }

    @Test func metadataTokensInReplacement() throws {
        var o = RenameOptions()
        o.search = "IMG"
        o.replace = "$CAMERA_MODEL_$DATE_TAKEN_YYYY$DATE_TAKEN_MM$DATE_TAKEN_DD"
        let env = RenameEnvironment(metadata: { _ in ["CAMERA_MODEL": "X100", "DATE_TAKEN_YYYY": "2024",
                                                      "DATE_TAKEN_MM": "03", "DATE_TAKEN_DD": "01"] })
        let rows = try RenameEngine(options: o).plan(items(["IMG.jpg"]), environment: env)
        #expect(rows[0].newName == "X100_20240301.jpg")
    }

    @Test func metadataReadFromARealImage() throws {
        let dir = try FileOpsScratch()
        let url = dir.url.appendingPathComponent("shot.jpg")
        let ctx = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2019:12:31 23:59:58"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let v = PhotoMetadata.read(url)
        #expect(v["CAMERA_MODEL"] == "TestCam")
        #expect(v["WIDTH"] == "8" && v["HEIGHT"] == "6")
        #expect(v["DATE_TAKEN_YYYY"] == "2019")
        #expect(PhotoMetadata.read(dir.url.appendingPathComponent("missing.jpg")).isEmpty)
    }

    // MARK: Files on disk

    @Test func loaderListsFoldersDepthFirstAndSkipsHidden() throws {
        let dir = try FileOpsScratch()
        try dir.make("b.txt")
        try dir.make("A Folder/z.txt")
        try dir.make("A Folder/Sub/inner.txt")
        try dir.make("A Folder/.hidden")
        try dir.make("Tool.app/Contents/Info.plist")
        let list = RenameItemLoader.load([dir.url.appendingPathComponent("b.txt"), dir.url.appendingPathComponent("A Folder"),
                                          dir.url.appendingPathComponent("Tool.app")])
        #expect(list.map(\.name) == ["A Folder", "Sub", "inner.txt", "z.txt", "b.txt", "Tool.app"])
        #expect(list.map(\.depth) == [0, 1, 2, 1, 0, 0])
        #expect(list.map(\.isFolder) == [true, true, false, false, false, false])
        #expect(list.map(\.id) == Array(0..<6))
        #expect(list[0].created != nil)
    }

    @Test func applyRenamesChildrenBeforeFoldersAndUndoRestores() throws {
        let dir = try FileOpsScratch()
        try dir.make("Photos old/IMG old 1.jpg")
        try dir.make("Photos old/IMG old 2.jpg")
        try dir.make("old notes.txt")
        let list = RenameItemLoader.load([dir.url.appendingPathComponent("Photos old"), dir.url.appendingPathComponent("old notes.txt")])
        var o = RenameOptions()
        o.search = "old"; o.replace = "new"
        let rows = try RenameEngine(options: o).plan(list, environment: .live)
        let outcome = RenameExecutor.apply(RenameExecutor.operations(for: rows))
        #expect(outcome.failures.isEmpty)
        #expect(outcome.done.count == 4)
        #expect(try dir.list() == ["Photos new", "Photos new/IMG new 1.jpg", "Photos new/IMG new 2.jpg", "new notes.txt"])
        let back = RenameExecutor.undo(outcome.done)
        #expect(back.failures.isEmpty)
        #expect(try dir.list() == ["Photos old", "Photos old/IMG old 1.jpg", "Photos old/IMG old 2.jpg", "old notes.txt"])
    }

    @Test func applySwapsAndChainsWithoutLosingFiles() throws {
        let dir = try FileOpsScratch()
        try dir.make("a.txt", contents: "A")
        try dir.make("b.txt", contents: "B")
        try dir.make("c.txt", contents: "C")
        let u = { (n: String) in dir.url.appendingPathComponent(n) }
        // a → b, b → c, c → a: a cycle.
        let outcome = RenameExecutor.apply([RenameOperation(from: u("a.txt"), to: u("b.txt")),
                                            RenameOperation(from: u("b.txt"), to: u("c.txt")),
                                            RenameOperation(from: u("c.txt"), to: u("a.txt"))])
        #expect(outcome.failures.isEmpty)
        #expect(try String(contentsOf: u("b.txt"), encoding: .utf8) == "A")
        #expect(try String(contentsOf: u("c.txt"), encoding: .utf8) == "B")
        #expect(try String(contentsOf: u("a.txt"), encoding: .utf8) == "C")
        #expect(try dir.list() == ["a.txt", "b.txt", "c.txt"])
        _ = RenameExecutor.undo(outcome.done)
        #expect(try String(contentsOf: u("a.txt"), encoding: .utf8) == "A")
        #expect(try String(contentsOf: u("c.txt"), encoding: .utf8) == "C")
    }

    @Test func applyNeverOverwritesAndHandlesCaseOnlyRenames() throws {
        let dir = try FileOpsScratch()
        try dir.make("keep.txt", contents: "keep")
        try dir.make("other.txt", contents: "other")
        try dir.make("photo.JPG")
        let u = { (n: String) in dir.url.appendingPathComponent(n) }
        let outcome = RenameExecutor.apply([RenameOperation(from: u("other.txt"), to: u("keep.txt")),
                                            RenameOperation(from: u("photo.JPG"), to: u("photo.jpg"))])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.message == "An item with that name already exists")
        #expect(try String(contentsOf: u("keep.txt"), encoding: .utf8) == "keep")
        #expect(try dir.list().contains("photo.jpg"))
    }

    @Test func journalRoundTrip() throws {
        let dir = try FileOpsScratch()
        let file = dir.url.appendingPathComponent("j.json")
        let journal = RenameJournal(operations: [RenameOperation(from: URL(fileURLWithPath: "/a b"), to: URL(fileURLWithPath: "/c"))])
        try journal.save(to: file)
        #expect(RenameJournal.load(from: file)?.operations == journal.operations)
    }

    // MARK: Settings

    @Test func historyIsDedupedAndCapped() {
        var s = PowerRenameSettings()
        s.historySize = 3
        for t in ["a", "b", "c", "b", "d", ""] { s.remember(search: t, replace: t.uppercased()) }
        #expect(s.searchHistory == ["d", "b", "c"])
        #expect(s.replaceHistory == ["D", "B", "C"])
    }

    @Test func initialOptionsRestoreFlagsAndRecentValues() {
        var s = PowerRenameSettings()
        s.lastOptions.useRegex = true
        s.lastOptions.search = "stale"
        s.searchHistory = ["recent"]
        s.replaceHistory = ["new"]
        #expect(s.initialOptions.useRegex == true)
        #expect(s.initialOptions.search == "")
        s.showRecentValues = true
        #expect(s.initialOptions.search == "recent" && s.initialOptions.replace == "new")
        s.restoreFlags = false
        #expect(s.initialOptions.useRegex == false)
    }

    @Test func settingsRoundTrip() throws {
        var s = PowerRenameSettings()
        s.regexFlavor = .extended
        s.lastOptions.textFormat = .titleCase
        let back = try JSONDecoder().decode(PowerRenameSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

/// A temporary folder removed when the test ends (shared by the file utilities' tests).
final class FileOpsScratch {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The real path (/private/var/…), as libproc and the kernel report it.
        url = URL(fileURLWithPath: Self.realPath(base.path), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    @discardableResult
    func make(_ relative: String, contents: String = "") throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func list() throws -> [String] {
        let e = FileManager.default.enumerator(atPath: url.path)
        var out: [String] = []
        while let p = e?.nextObject() as? String { out.append(p) }
        return out.sorted()
    }
}
