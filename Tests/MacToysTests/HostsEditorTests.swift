import Foundation
import Testing
@testable import HostsEditor

@Suite struct HostsEditorTests {
    static let macDefault = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    static let messy = "  # indented comment\n\n10.0.0.5   build.local\tci.local  # CI box\n#0.0.0.0 ads.example.com\n# 10.1.1.1 is the router\nnot an entry\n\t\nfe80::1%lo0\tlocalhost\n300.1.1.1 typo.local"

    // MARK: Round trips

    @Test(arguments: [macDefault, messy, "", "\n", "127.0.0.1 a", "# only a comment\n",
                      "127.0.0.1 a\r\n# c\r\n::1 b\r\n", "\u{FEFF}127.0.0.1 bom.local\n", "a\n\n\n"])
    func unchangedFilesRoundTripByteForByte(_ text: String) {
        #expect(HostsDocument.parse(text).serialize() == text)
    }

    @Test func thisMacsHostsFileRoundTrips() throws {
        let text = try String(contentsOfFile: "/private/etc/hosts", encoding: .utf8)
        #expect(HostsDocument.parse(text).serialize() == text)
    }

    @Test func parsesEntriesCommentsAndDisabledLines() {
        let doc = HostsDocument.parse(Self.messy)
        let entries = doc.entries
        #expect(entries.map(\.address) == ["10.0.0.5", "0.0.0.0", "fe80::1%lo0", "300.1.1.1"])
        #expect(entries[0].hosts == ["build.local", "ci.local"])
        #expect(entries[0].comment == "CI box")
        #expect(entries[0].active)
        #expect(!entries[1].active && entries[1].hosts == ["ads.example.com"])
        #expect(entries[3].active, "invalid addresses still show as entries so they can be fixed")
        // Prose that starts with an address stays a comment.
        let raws = doc.lines.compactMap { line -> String? in
            if case .raw(let s) = line { return s } else { return nil }
        }
        #expect(raws.contains("not an entry"))
        #expect(raws.contains("# 10.1.1.1 is the router"))
        #expect(raws.contains("  # indented comment"))
    }

    @Test func defaultFileHasThreeEntriesAndAHeader() {
        let doc = HostsDocument.parse(Self.macDefault)
        #expect(doc.entries.count == 3)
        #expect(doc.header.count == 6)
        #expect(doc.header.first == "##")
        #expect(doc.entries.allSatisfy { $0.active })
    }

    // MARK: Editing

    @Test func togglingCommentsTheLineOut() {
        var doc = HostsDocument.parse(Self.macDefault)
        let id = doc.entries[1].id
        doc.setActive(id, false)
        #expect(doc.serialize().contains("\n# 255.255.255.255\tbroadcasthost\n"))
        doc.setActive(id, true)
        #expect(doc.serialize().contains("\n255.255.255.255\tbroadcasthost\n"))
        // Other lines keep their original spacing.
        #expect(doc.serialize().contains("::1             localhost"))
    }

    @Test func enablingADisabledEntry() {
        var doc = HostsDocument.parse("#0.0.0.0 ads.example.com # Blocked\n")
        doc.setActive(doc.entries[0].id, true)
        #expect(doc.serialize() == "0.0.0.0\tads.example.com\t# Blocked\n")
    }

    @Test func unchangedUpdateKeepsOriginalText() {
        var doc = HostsDocument.parse("10.0.0.5   build.local  # CI\n")
        doc.update(doc.entries[0])
        #expect(doc.serialize() == "10.0.0.5   build.local  # CI\n")
        var e = doc.entries[0]
        e.hosts.append("ci.local")
        doc.update(e)
        #expect(doc.serialize() == "10.0.0.5\tbuild.local ci.local\t# CI\n")
    }

    @Test func crlfFilesStayCRLFWhenEdited() {
        var doc = HostsDocument.parse("127.0.0.1 a\r\n::1 b\r\n")
        var e = doc.entries[0]
        e.comment = "x"
        doc.update(e)
        #expect(doc.serialize() == "127.0.0.1\ta\t# x\r\n::1 b\r\n")
    }

    @Test func addsAtTopOrBottom() {
        var doc = HostsDocument.parse(Self.macDefault)
        doc.add(HostsEntry(address: "10.0.0.1", hosts: ["top.local"]), placement: .top)
        doc.add(HostsEntry(address: "10.0.0.2", hosts: ["bottom.local"]), placement: .bottom)
        let lines = doc.serialize().components(separatedBy: "\n")
        #expect(lines[6] == "10.0.0.1\ttop.local", "right after the header")
        #expect(lines[10] == "10.0.0.2\tbottom.local", "after the last entry, before the trailing newline")
        #expect(doc.serialize().hasSuffix("bottom.local\n"))

        var empty = HostsDocument.parse("")
        empty.add(HostsEntry(address: "::1", hosts: ["x"]), placement: .bottom)
        #expect(empty.serialize() == "::1\tx\n")
    }

    @Test func duplicatesAndRemovesEntries() {
        var doc = HostsDocument.parse(Self.macDefault)
        let id = doc.entries[0].id
        let copy = doc.duplicate(id)
        #expect(copy != nil && copy?.id != id)
        #expect(doc.entries.count == 4)
        #expect(doc.entries[1].address == "127.0.0.1")
        doc.remove(id)
        #expect(doc.entries.count == 3)
        #expect(doc.entries[0].id == copy?.id)
    }

    @Test func movesEntriesPastRawLines() {
        var doc = HostsDocument.parse("10.0.0.1 a\n# note\n10.0.0.2 b\n")
        doc.move(doc.entries[1].id, by: -1)
        #expect(doc.serialize() == "10.0.0.2 b\n# note\n10.0.0.1 a\n")
    }

    @Test func replacesHeader() {
        var doc = HostsDocument.parse(Self.macDefault)
        doc.setHeader(["# Mine"])
        #expect(doc.serialize().hasPrefix("# Mine\n127.0.0.1\tlocalhost\n"))
        #expect(doc.entries.count == 3)
    }

    // MARK: Validation

    @Test func validatesAddresses() {
        for a in ["127.0.0.1", "0.0.0.0", "255.255.255.255", "::1", "fe80::1%lo0", "2001:db8::42"] {
            #expect(HostsValidator.isValidAddress(a), "\(a)")
        }
        for a in ["300.1.1.1", "1.2.3", "localhost", "::g", "", "1.2.3.4.5"] {
            #expect(!HostsValidator.isValidAddress(a), "\(a)")
        }
        #expect(HostsValidator.isLoopback("127.0.0.1") && HostsValidator.isLoopback("127.5.5.5") && HostsValidator.isLoopback("::1"))
        #expect(!HostsValidator.isLoopback("10.0.0.1") && !HostsValidator.isLoopback("::2"))
    }

    @Test func validatesHostnames() {
        for h in ["localhost", "api.dev.local", "my_service.internal", "a-b.c", "x.", "xn--bcher-kva.example"] {
            #expect(HostsValidator.isValidHostname(h), "\(h)")
        }
        for h in ["-bad.local", "bad-.local", "a..b", "", "spa ce", "émoji.local", "10.0.0.1",
                  String(repeating: "a", count: 64) + ".local"] {
            #expect(!HostsValidator.isValidHostname(h), "\(h)")
        }
    }

    @Test func warnsAboutLocalhost() {
        #expect(HostsValidator.issues(HostsEntry(address: "10.0.0.1", hosts: ["localhost"])).contains(.localhostElsewhere))
        #expect(HostsValidator.issues(HostsEntry(active: false, address: "127.0.0.1", hosts: ["localhost"])).contains(.localhostDisabled))
        #expect(HostsValidator.issues(HostsEntry(address: "127.0.0.1", hosts: ["localhost"])).isEmpty)
        #expect(HostsValidator.issues(HostsEntry(address: "1.2.3", hosts: ["-x"])) == [.invalidAddress, .invalidHost("-x")])
        #expect(HostsValidator.issues(HostsEntry(address: "1.2.3.4", hosts: [])) == [.noHosts])
    }

    @Test func findsDuplicates() {
        let a = HostsEntry(address: "127.0.0.1", hosts: ["localhost"])
        let b = HostsEntry(address: "::1", hosts: ["localhost"])
        let c = HostsEntry(address: "10.0.0.1", hosts: ["API.local", "x.local"])
        let d = HostsEntry(address: "10.0.0.2", hosts: ["api.local"])
        let off = HostsEntry(active: false, address: "10.0.0.3", hosts: ["x.local"])
        let without = HostsValidator.duplicates([a, b, c, d, off], loopbackDuplicates: false)
        #expect(without[a.id] == nil && without[b.id] == nil)
        #expect(without[c.id] == ["api.local"] && without[d.id] == ["api.local"])
        #expect(without[off.id] == nil, "disabled entries don't clash")
        let with = HostsValidator.duplicates([a, b], loopbackDuplicates: true)
        #expect(with[a.id] == ["localhost"] && with[b.id] == ["localhost"])
        let same = HostsValidator.duplicates([a, HostsEntry(address: "127.0.0.1", hosts: ["localhost"])], loopbackDuplicates: false)
        #expect(same.count == 2, "the same loopback address twice is a duplicate")
    }

    // MARK: Backups, ping, ids

    @Test func backupRetention() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let files = (0..<8).map { ("hosts-\($0)", now.addingTimeInterval(-Double($0) * 86400 * 4)) } + [("notes.txt", now)]
        #expect(HostsBackups.toDelete(files, retention: .never, keep: 5, days: 15, now: now).isEmpty)
        #expect(Set(HostsBackups.toDelete(files, retention: .count, keep: 5, days: 15, now: now)) == ["hosts-5", "hosts-6", "hosts-7"])
        // Older than 15 days: 4…7 (16, 20, 24, 28 days); the newest five are always kept.
        #expect(Set(HostsBackups.toDelete(files, retention: .ageAndCount, keep: 5, days: 15, now: now)) == ["hosts-5", "hosts-6", "hosts-7"])
        #expect(Set(HostsBackups.toDelete(files, retention: .ageAndCount, keep: 2, days: 15, now: now)) == ["hosts-4", "hosts-5", "hosts-6", "hosts-7"])
        #expect(HostsBackups.name(for: Date(timeIntervalSince1970: 0)).hasPrefix("hosts-19"))
    }

    @Test func parsesPingOutput() {
        let out = "PING 10.0.4.12 (10.0.4.12): 56 data bytes\n64 bytes from 10.0.4.12: icmp_seq=0 ttl=64 time=12.345 ms\n"
        #expect(PingParser.milliseconds(out) == 12.345)
        #expect(PingParser.milliseconds("Request timeout for icmp_seq 0") == nil)
    }

    @Test @MainActor func savedFileKeepsEntryIDs() {
        let old = HostsDocument.parse(Self.macDefault)
        var edited = old
        edited.setActive(edited.entries[1].id, false)
        let reread = HostsDocument.parse(edited.serialize())
        let carried = HostsEditorModel.carryIDs(from: edited, to: reread)
        #expect(carried.entries.map(\.id) == old.entries.map(\.id))
        #expect(carried.entries.allSatisfy { $0.original != nil })
    }
}
