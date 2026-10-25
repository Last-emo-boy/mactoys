import Foundation
import Testing
@testable import PlistPreview

@Suite struct PlistPreviewTests {
    static let sample: [String: Any] = [
        "autohide": true,
        "tilesize": 48,
        "magnification": 1.5,
        "orientation": "bottom",
        "persistent-apps": [["tile-type": "file-tile", "GUID": 123], "plain"],
        "created": Date(timeIntervalSince1970: 1_700_000_000),
        "blob": Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]),
        "empty": [String: Any](),
    ]

    // MARK: Conversion

    @Test func convertsPropertyListsBothWays() throws {
        let node = PlistNode.from(Self.sample)
        #expect(node.type == .dictionary)
        #expect(node.children?.map(\.key) == ["autohide", "blob", "created", "empty", "magnification", "orientation", "persistent-apps", "tilesize"])
        let back = node.propertyList as? NSDictionary
        #expect(back?.isEqual(to: Self.sample) == true)
    }

    @Test func distinguishesBooleansIntegersAndReals() {
        let node = PlistNode.from(Self.sample)
        func value(_ key: String) -> PlistNode.Value? { node.children?.first { $0.key == key }?.value }
        #expect(value("autohide") == .boolean(true))
        #expect(value("tilesize") == .integer(48))
        #expect(value("magnification") == .real(1.5))
        let json = try? JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":1.25,"d":null}"#.utf8))
        var nulls = 0
        let j = PlistNode.from(json as Any, nulls: &nulls)
        #expect(j.children?.map(\.value) == [.boolean(true), .integer(1), .real(1.25), .string("")])
        #expect(nulls == 1)
    }

    @Test func survivesEveryFileFormat() throws {
        let node = PlistNode.from(Self.sample)
        for format in [PlistFormat.xml, .binary] {
            let data = try PlistCodec.encode(node, as: format)
            let (decoded, detected, _) = try PlistCodec.decode(data)
            #expect(detected == format)
            #expect((decoded.propertyList as? NSDictionary)?.isEqual(to: Self.sample) == true)
        }
        #expect(throws: PlistCodec.Failure.self) { try PlistCodec.encode(node, as: .json) }
        let jsonNode = PlistNode.from(["name": "x", "n": [1, 2, 3], "ok": false] as [String: Any])
        let json = try PlistCodec.encode(jsonNode, as: .json)
        let (decoded, format, _) = try PlistCodec.decode(json)
        #expect(format == .json)
        #expect(decoded.children?.first { $0.key == "ok" }?.value == .boolean(false))
        let (openStep, osFormat, _) = try PlistCodec.decode(Data(#"{ a = 1; b = ( x, y ); }"#.utf8))
        #expect(osFormat == .openStep)
        #expect(openStep.children?.count == 2)
        #expect(throws: PlistCodec.Failure.self) { try PlistCodec.decode(Data([0xFF, 0x00, 0x13])) }
    }

    // MARK: Values and types

    @Test func parsesValuesForTheirType() {
        let n = PlistNode(value: .integer(1))
        #expect(n.parsed("42") == .integer(42))
        #expect(n.parsed("4.5") == .real(4.5))
        #expect(n.parsed("abc") == nil)
        #expect(PlistNode(value: .boolean(false)).parsed("yes") == .boolean(true))
        #expect(PlistNode(value: .boolean(false)).parsed("maybe") == nil)
        #expect(PlistNode(value: .data(Data())).parsed("<dead beef>") == .data(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(PlistNode(value: .data(Data())).parsed("abc") == nil)
        #expect(PlistNode(value: .date(Date())).parsed("2026-10-25T10:00:00Z") == .date(Date(timeIntervalSince1970: 1_792_922_400)))
        #expect(PlistNode(value: .string("")).parsed("  spaced ") == .string("  spaced "))
        #expect(PlistNode(value: .dictionary([])).parsed("x") == nil)
    }

    @Test func formatsValues() {
        #expect(PlistNode(value: .boolean(true)).valueText == "YES")
        #expect(PlistNode(value: .integer(48)).valueText == "48")
        #expect(PlistNode(value: .real(48)).valueText == "48.0")
        #expect(PlistNode(value: .real(0.25)).valueText == "0.25")
        #expect(PlistNode(value: .data(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]))).valueText == "<deadbeef 01>")
        // "1 item" is the catalog's English plural form; without tables the key's own form shows.
        #expect(PlistNode(value: .array([PlistNode(value: .string("a")), PlistNode(value: .string("b"))])).summary == "2 items")
    }

    @Test func changesTypesKeepingWhatFits() {
        #expect(PlistNode(value: .string("12")).converted(to: .number) == .integer(12))
        #expect(PlistNode(value: .string("1.5")).converted(to: .number) == .real(1.5))
        #expect(PlistNode(value: .integer(7)).converted(to: .string) == .string("7"))
        #expect(PlistNode(value: .integer(0)).converted(to: .boolean) == .boolean(false))
        #expect(PlistNode(value: .string("YES")).converted(to: .boolean) == .boolean(true))
        #expect(PlistNode(value: .boolean(true)).converted(to: .number) == .integer(1))
        #expect(PlistNode(value: .string("hi")).converted(to: .data) == .data(Data("hi".utf8)))
        #expect(PlistNode(value: .data(Data("hi".utf8))).converted(to: .string) == .string("hi"))
        #expect(PlistNode(value: .integer(0)).converted(to: .date) == .date(Date(timeIntervalSince1970: 0)))
        let a = PlistNode(value: .array([PlistNode(value: .string("x")), PlistNode(value: .integer(2))]))
        guard case .dictionary(let d) = a.converted(to: .dictionary) else { Issue.record("expected dictionary"); return }
        #expect(d.map(\.key) == ["Item 0", "Item 1"])
        guard case .array(let back) = PlistNode(value: .dictionary(d)).converted(to: .array) else { Issue.record("expected array"); return }
        #expect(back.map(\.value) == [.string("x"), .integer(2)])
        #expect(PlistNode(value: .string("x")).converted(to: .array) == .array([]))
        #expect(PlistNode(value: .integer(3)).converted(to: .number) == .integer(3), "same type is a no-op")
    }

    // MARK: Paths and tree edits

    @Test func computesKeyPaths() throws {
        let root = PlistNode.from(Self.sample)
        let apps = try #require(root.children?.first { $0.key == "persistent-apps" })
        let first = try #require(apps.children?.first)
        let tile = try #require(first.children?.first { $0.key == "tile-type" })
        #expect(root.path(to: tile.id) == ["persistent-apps", "0", "tile-type"])
        #expect(PlistNode.keyPath(["persistent-apps", "0", "tile-type"]) == ":persistent-apps:0:tile-type")
        #expect(PlistNode.keyPath(["a:b"]) == ":a\\:b")
        #expect(root.path(to: root.id) == [])
        #expect(root.path(to: UUID()) == nil)
        #expect(root.parent(of: tile.id)?.id == first.id)
        #expect(root.parent(of: root.id) == nil)
    }

    @Test func modifiesNestedNodes() throws {
        var root = PlistNode.from(Self.sample)
        let apps = try #require(root.children?.first { $0.key == "persistent-apps" })
        let plain = try #require(apps.children?.last)
        #expect(root.modify(plain.id) { $0.value = .string("changed") })
        #expect(root.node(plain.id)?.value == .string("changed"))
        #expect(root.modifyParent(of: plain.id) { c, i in c.remove(at: i) })
        #expect(root.node(plain.id) == nil)
        #expect(root.node(apps.id)?.children?.count == 1)
        #expect(!root.modify(UUID()) { _ in })
    }

    @Test func uniqueKeysAndCopies() {
        let siblings = [PlistNode(key: "New Item", value: .string("")), PlistNode(key: "New Item 2", value: .string(""))]
        #expect(PlistNode.uniqueKey("New Item", among: siblings) == "New Item 3")
        #expect(PlistNode.uniqueKey("Other", among: siblings) == "Other")
        let tree = PlistNode.from(Self.sample)
        let copy = tree.copyWithNewIDs()
        #expect(Set(copy.allIDs).isDisjoint(with: Set(tree.allIDs)))
        #expect((copy.propertyList as? NSDictionary)?.isEqual(to: Self.sample) == true)
    }

    @Test func flattensExpandedRows() throws {
        let root = PlistNode.from(Self.sample)
        #expect(PlistOutline.rows(root, expanded: []).count == 1)
        let top = PlistOutline.rows(root, expanded: [root.id])
        #expect(top.count == 9)
        #expect(top[0].displayKey == "Root" && top[1].depth == 1)
        let apps = try #require(root.children?.first { $0.key == "persistent-apps" })
        let open = PlistOutline.rows(root, expanded: [root.id, apps.id])
        let appsRow = try #require(open.firstIndex { $0.id == apps.id })
        #expect(open[appsRow + 1].displayKey == "Item 0" && open[appsRow + 1].depth == 2)
        #expect(open[appsRow + 2].displayKey == "Item 1")
    }

    @Test func searchShowsMatchesWithTheirAncestors() {
        let root = PlistNode.from(Self.sample)
        let matches = PlistOutline.search(root, "file-tile")
        #expect(matches.count == 1)
        let rows = PlistOutline.rows(root, expanded: [], matches: matches)
        #expect(rows.map(\.displayKey) == ["Root", "persistent-apps", "Item 0", "tile-type"])
        #expect(PlistOutline.search(root, "ITEM 1").count == 1, "array items match by their Item n label")
        #expect(PlistOutline.search(root, "  ").isEmpty)
    }

    @Test func diffsByKeyPath() {
        let old = PlistNode.from(["a": 1, "b": "x", "list": [1, 2], "gone": true] as [String: Any])
        let new = PlistNode.from(["a": 2, "b": "x", "list": [1, 2, 3], "new": "y"] as [String: Any])
        let d = PlistDiff.diff(old, new)
        #expect(d.map { PlistNode.keyPath($0.path) }.sorted() == [":a", ":gone", ":list:2", ":new"])
        #expect(d.first { $0.path == ["a"] }?.kind == .changed)
        #expect(d.first { $0.path == ["gone"] }?.kind == .removed)
        #expect(d.first { $0.path == ["list", "2"] }?.kind == .added)
        #expect(PlistDiff.diff(old, old).isEmpty)
        #expect(PlistDiff.diff(PlistNode(value: .integer(2)), PlistNode(value: .real(2))).isEmpty)
    }

    // MARK: Document

    @Test @MainActor func documentEditsWithUndo() throws {
        let doc = PlistDocument(root: PlistNode.from(["a": 1, "b": 2] as [String: Any]))
        #expect(!doc.isDirty && !doc.canUndo)
        let a = try #require(doc.root.children?.first)
        #expect(!doc.rename(a.id, to: "b"), "duplicate keys are refused")
        #expect(doc.message?.kind == .error)
        #expect(doc.rename(a.id, to: "c"))
        #expect(doc.isDirty && doc.canUndo)
        #expect(!doc.setValue(a.id, text: "not a number"))
        #expect(doc.setValue(a.id, text: "7"))
        doc.changeType(a.id, to: .string)
        #expect(doc.root.node(a.id)?.value == .string("7"))
        doc.undo()
        #expect(doc.root.node(a.id)?.value == .integer(7))
        doc.redo()
        #expect(doc.root.node(a.id)?.value == .string("7"))
        doc.undo(); doc.undo(); doc.undo()
        #expect(doc.root.node(a.id)?.key == "a" && !doc.isDirty)
    }

    @Test @MainActor func documentAddsDuplicatesDeletesAndMoves() throws {
        let doc = PlistDocument(root: PlistNode.from(["list": ["x"]] as [String: Any]))
        let list = try #require(doc.root.children?.first)
        doc.add(near: list.id)
        #expect(doc.root.node(list.id)?.children?.count == 2)
        doc.add(near: nil)
        #expect(doc.root.children?.map(\.key) == ["list", "New Item"])
        let newItem = try #require(doc.root.children?.last)
        doc.duplicate(newItem.id)
        #expect(doc.root.children?.map(\.key) == ["list", "New Item", "New Item copy"])
        doc.move(newItem.id, by: -1)
        #expect(doc.root.children?.map(\.key) == ["New Item", "list", "New Item copy"])
        doc.delete(newItem.id)
        #expect(doc.root.children?.map(\.key) == ["list", "New Item copy"])
        doc.delete(doc.root.id)
        #expect(doc.root.children?.count == 2, "the root can't be deleted")
    }

    @Test @MainActor func readOnlyDocumentsIgnoreEdits() throws {
        let doc = PlistDocument(root: PlistNode.from(["a": 1] as [String: Any]), domain: "com.example")
        doc.readOnly = true
        let a = try #require(doc.root.children?.first)
        doc.setValue(a.id, .integer(9))
        #expect(doc.root.node(a.id)?.value == .integer(1))
    }

    @Test @MainActor func savesInTheOriginalFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.plist")
        try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0).write(to: url)
        let doc = try PlistDocument.open(url)
        #expect(doc.format == .binary)
        let k = try #require(doc.root.children?.first)
        doc.setValue(k.id, text: "w")
        try doc.save()
        #expect(!doc.isDirty)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("bplist".utf8)))
        try doc.compareWithSource()
        #expect(doc.differences == [])
        doc.setValue(k.id, text: "z")
        try doc.compareWithSource()
        #expect(doc.differences?.count == 1)
    }

    @Test @MainActor func guessesDefaultsDomains() {
        let home = NSHomeDirectory()
        #expect(PlistDocument.domainGuess(for: URL(fileURLWithPath: home + "/Library/Preferences/com.apple.dock.plist")) == "com.apple.dock")
        #expect(PlistDocument.domainGuess(for: URL(fileURLWithPath: home + "/Library/Preferences/.GlobalPreferences.plist")) == "NSGlobalDomain")
        #expect(PlistDocument.domainGuess(for: URL(fileURLWithPath: home + "/Library/Preferences/ByHost/com.apple.x.0A1B2C3D-0000.plist")) == "com.apple.x")
        #expect(PlistDocument.domainGuess(for: URL(fileURLWithPath: "/tmp/com.apple.dock.plist")) == nil)
    }
}
