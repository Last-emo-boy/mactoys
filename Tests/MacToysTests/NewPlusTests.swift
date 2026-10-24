import Foundation
import Testing
@testable import MacToysCore
@testable import NewPlus

@Suite struct NewPlusTests {
    private func date() -> Date {
        var c = DateComponents(year: 2024, month: 11, day: 22, hour: 12, minute: 8, second: 54)
        c.nanosecond = 7_000_000
        return Calendar.current.date(from: c) ?? Date()
    }

    @Test func displayNames() {
        let file = NewPlusTemplate(url: URL(fileURLWithPath: "/t/1. Report.docx"), isFolder: false)
        #expect(file.title(hideExtension: true, hideLeadingDigits: false) == "1. Report")
        #expect(file.title(hideExtension: false, hideLeadingDigits: true) == "Report.docx")
        #expect(file.title(hideExtension: true, hideLeadingDigits: true) == "Report")
        let folder = NewPlusTemplate(url: URL(fileURLWithPath: "/t/02 my.project"), isFolder: true)
        #expect(folder.title(hideExtension: true, hideLeadingDigits: true) == "my.project")
        let dot = NewPlusTemplate(url: URL(fileURLWithPath: "/t/.editorconfig"), isFolder: false)
        #expect(dot.title(hideExtension: true, hideLeadingDigits: true) == "editorconfig")
        #expect(NewPlusNames.stripLeadingDigits("123") == "123")
        #expect(NewPlusNames.stripLeadingDigits("1 - Notes") == "- Notes")
    }

    @Test func numberedNames() {
        #expect(NewPlusNames.numbered("Report.docx", 1, isFolder: false) == "Report.docx")
        #expect(NewPlusNames.numbered("Report.docx", 2, isFolder: false) == "Report 2.docx")
        #expect(NewPlusNames.numbered("my.project", 3, isFolder: true) == "my.project 3")
        #expect(NewPlusNames.numbered(".zshrc", 2, isFolder: false) == ".zshrc 2")
    }

    @Test func variablesFollowTheDocs() {
        let ctx = NewPlusVariables.Context(date: date(), parentFolderName: "PowerShell project",
                                           environment: ["USERNAME": "cgaarden", "USERPROFILE": "C:/Users/cgaarden", "Path": "x"])
        #expect(NewPlusVariables.expand("$YYYY-$MM-$DD, $hh $mm $ss  - $PARENT_FOLDER_NAME by %USERNAME%", context: ctx)
                == "2024-11-22, 12 08 54  - PowerShell project by cgaarden")
        // Invalid characters in values become spaces; environment names are case-insensitive.
        #expect(NewPlusVariables.expand("File %userprofile%", context: ctx) == "File C  Users cgaarden")
        #expect(NewPlusVariables.expand("%PATH%-%path%", context: ctx) == "x-x")
        #expect(NewPlusVariables.expand("$fff $ff $f $Y $M $D $h $m $s", context: ctx) == "007 00 0 4 11 22 12 8 54")
        #expect(NewPlusVariables.expand("$USERNAME", context: ctx) == "cgaarden")
        // Unknown names stay as they are.
        #expect(NewPlusVariables.expand("100% %NOPE% $x 50%", context: ctx) == "100% %NOPE% $x 50%")
        #expect(NewPlusVariables.expand("$yyyy", context: ctx) == "$yyyy")
    }

    @Test func listingSortsFoldersFirstInFinderOrder() throws {
        let dir = try FileOpsScratch()
        try dir.make("10 b.txt")
        try dir.make("2 a.txt")
        try dir.make("Zeta/inner.txt")
        try dir.make(".hidden")
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        let list = NewPlusTemplates.list(in: dir.url)
        #expect(list.map(\.fileName) == ["Alpha", "Zeta", "2 a.txt", "10 b.txt"])
        #expect(list.map(\.isFolder) == [true, true, false, false])
        #expect(NewPlusTemplates.find("a", in: list, hideExtension: true, hideLeadingDigits: true)?.fileName == "2 a.txt")
        #expect(NewPlusTemplates.find("10 b.txt", in: list, hideExtension: false, hideLeadingDigits: false)?.fileName == "10 b.txt")
        #expect(NewPlusTemplates.find("zeta", in: list, hideExtension: true, hideLeadingDigits: false)?.fileName == "Zeta")
        #expect(NewPlusTemplates.find("missing", in: list, hideExtension: true, hideLeadingDigits: false) == nil)
        #expect(NewPlusTemplates.list(in: dir.url.appendingPathComponent("nope")).isEmpty)
    }

    @Test func seedingWritesUsefulTemplates() throws {
        let dir = try FileOpsScratch()
        let folder = dir.url.appendingPathComponent("Templates")
        try NewPlusTemplates.seed(folder)
        let list = NewPlusTemplates.list(in: folder)
        #expect(list.first?.fileName == "Project" && list.first?.isFolder == true)
        #expect(list.contains { $0.fileName == "Text Document.txt" })
        #expect(list.count >= 6)
        let script = folder.appendingPathComponent("Shell Script.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Project/src").path))
    }

    @Test func createsFilesWithUniqueNames() throws {
        let dir = try FileOpsScratch()
        let template = try dir.make("Templates/Note.md", contents: "# Hi\n")
        let dest = dir.url.appendingPathComponent("Dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let t = NewPlusTemplate(url: template, isFolder: false)
        let first = try NewPlusCreator.create(from: t, in: dest)
        let second = try NewPlusCreator.create(from: t, in: dest)
        #expect(first.lastPathComponent == "Note.md")
        #expect(second.lastPathComponent == "Note 2.md")
        #expect(try String(contentsOf: second, encoding: .utf8) == "# Hi\n")
        let created = try second.resourceValues(forKeys: [.creationDateKey]).creationDate
        #expect(created.map { abs($0.timeIntervalSinceNow) < 60 } == true)
    }

    @Test func createsFoldersRecursivelyWithVariables() throws {
        let dir = try FileOpsScratch()
        try dir.make("Templates/$YYYY Client/$PARENT_FOLDER_NAME notes.md", contents: "notes")
        try dir.make("Templates/$YYYY Client/assets/$MM-$DD.txt")
        try dir.make("Templates/$YYYY Client/.gitignore", contents: ".DS_Store\n")
        let dest = dir.url.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let t = NewPlusTemplate(url: dir.url.appendingPathComponent("Templates/$YYYY Client"), isFolder: true)

        let plain = try NewPlusCreator.create(from: t, in: dest)
        #expect(plain.lastPathComponent == "$YYYY Client")
        #expect(FileManager.default.fileExists(atPath: plain.appendingPathComponent("assets/$MM-$DD.txt").path))

        let made = try NewPlusCreator.create(from: t, in: dest, options: .init(replaceVariables: true, date: date()))
        #expect(made.lastPathComponent == "2024 Client")
        let names = try FileManager.default.contentsOfDirectory(atPath: made.path).sorted()
        #expect(names == [".gitignore", "2024 Client notes.md", "assets"])
        #expect(FileManager.default.fileExists(atPath: made.appendingPathComponent("assets/11-22.txt").path))
        #expect(try String(contentsOf: made.appendingPathComponent("2024 Client notes.md"), encoding: .utf8) == "notes")
    }

    @Test func leadingDigitsAreDroppedFromNewItemsWhenHidden() throws {
        let dir = try FileOpsScratch()
        let template = try dir.make("Templates/01. Invoice.numbers")
        let dest = dir.url.appendingPathComponent("D", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let t = NewPlusTemplate(url: template, isFolder: false)
        #expect(try NewPlusCreator.create(from: t, in: dest, options: .init(stripLeadingDigits: true)).lastPathComponent == "Invoice.numbers")
        #expect(try NewPlusCreator.create(from: t, in: dest).lastPathComponent == "01. Invoice.numbers")
    }

    @Test func topLevelParentFolderNameIsTheDestination() throws {
        let dir = try FileOpsScratch()
        let template = try dir.make("Templates/$PARENT_FOLDER_NAME.txt")
        let dest = dir.url.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let made = try NewPlusCreator.create(from: NewPlusTemplate(url: template, isFolder: false), in: dest,
                                             options: .init(replaceVariables: true))
        #expect(made.lastPathComponent == "Receipts.txt")
    }

    @Test func creationFailures() throws {
        let dir = try FileOpsScratch()
        let template = try dir.make("Templates/a.txt")
        let t = NewPlusTemplate(url: template, isFolder: false)
        #expect(throws: NewPlusCreator.Failure.self) { try NewPlusCreator.create(from: t, in: dir.url.appendingPathComponent("missing")) }
        let gone = NewPlusTemplate(url: dir.url.appendingPathComponent("Templates/gone.txt"), isFolder: false)
        #expect(throws: NewPlusCreator.Failure.self) { try NewPlusCreator.create(from: gone, in: dir.url) }
    }

    @Test func manifestMatchesWhatTheExtensionShows() throws {
        var s = NewPlusSettings()
        s.customTemplatesFolder = "/x/Templates"
        s.hideLeadingDigits = true
        let templates = [NewPlusTemplate(url: URL(fileURLWithPath: "/x/Templates/Folder"), isFolder: true),
                         NewPlusTemplate(url: URL(fileURLWithPath: "/x/Templates/1. Doc.txt"), isFolder: false)]
        let m = NewPlusMenuManifest(templates: templates, settings: s)
        #expect(m.templatesFolder == "/x/Templates")
        #expect(m.items.map(\.title) == ["Folder", "Doc"])
        #expect(m.items.map(\.fileName) == ["Folder", "1. Doc.txt"])
        let back = try JSONDecoder().decode(NewPlusMenuManifest.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        #expect(NewPlusSettings().templatesFolder.path.hasSuffix("MacToys/NewPlus/Templates"))
    }

    @Test @MainActor func pickerFiltersAndWraps() {
        let urls = ["Project", "Markdown Note.md", "Shell Script.sh"].map { URL(fileURLWithPath: "/t/\($0)") }
        let model = NewPlusPickerModel(templates: urls.enumerated().map { NewPlusTemplate(url: $1, isFolder: $0 == 0) },
                                       destination: URL(fileURLWithPath: "/tmp"), hideExtension: true, hideLeadingDigits: false)
        model.move(-1)
        #expect(model.selected?.fileName == "Shell Script.sh")
        model.query = "note"
        #expect(model.filtered.map(\.fileName) == ["Markdown Note.md"])
        #expect(model.selected?.fileName == "Markdown Note.md")
        model.query = "zzz"
        #expect(model.selected == nil)
    }
}
