import Foundation
import MacToysCore

/// Global key → key remaps through `hidutil property --set UserKeyMapping`.
///
/// The mapping lives in the HID event system, below every app and the event tap, so it is the
/// most robust way to remap Caps Lock and modifiers. It is not persistent: it lasts until the next
/// login or until replaced. The mapping found before MacToys changed it is restored on `restore()`;
/// it is also kept on disk so a crash doesn't make MacToys' mapping look like the user's own.
final class SystemKeyMapping: @unchecked Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var src: UInt64
        var dst: UInt64
    }

    private struct State: Codable {
        var original: [Entry]
        var applied: [Entry]
    }

    private let queue = DispatchQueue(label: "com.w33d.mactoys.keyboardmanager.hidutil")
    private let stateURL: URL
    private let log = Log.for("keyboardmanager")
    static let tool = "/usr/bin/hidutil"

    init(stateURL: URL = Paths.data(for: "keyboardmanager").appendingPathComponent("hidutil-state.json")) {
        self.stateURL = stateURL
    }

    /// Installs `entries` on top of the user's own mapping (entries for other source keys are kept).
    /// An empty list restores the original mapping.
    func apply(_ entries: [Entry]) {
        queue.async { [self] in
            if entries.isEmpty { restoreNow(); return }
            let current = read()
            let original: [Entry]
            if let state = loadState(), state.applied == current { original = state.original }
            else { original = current }
            let ours = Set(entries.map(\.src))
            let merged = original.filter { !ours.contains($0.src) } + entries
            guard merged != current else {
                saveState(State(original: original, applied: merged))
                return
            }
            if write(merged) { saveState(State(original: original, applied: merged)) }
        }
    }

    /// Puts back the mapping that was active before MacToys changed it.
    func restore() {
        queue.async { [self] in restoreNow() }
    }

    /// Blocks until queued work is done (used when the app quits).
    func waitUntilIdle() {
        queue.sync {}
    }

    private func restoreNow() {
        guard let state = loadState() else { return }
        let current = read()
        // If someone else changed the mapping since, leave theirs alone.
        if current == state.applied { _ = write(state.original) }
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func read() -> [Entry] {
        let r = Shell.run(Self.tool, ["property", "--matching", "keyboard", "--get", "UserKeyMapping"])
        guard r.ok else {
            log.error("hidutil get failed: \(r.stderr, privacy: .public)")
            return []
        }
        return Self.parse(r.stdout)
    }

    private func write(_ entries: [Entry]) -> Bool {
        let r = Shell.run(Self.tool, ["property", "--set", Self.json(entries)])
        if !r.ok { log.error("hidutil set failed: \(r.stderr, privacy: .public)") }
        return r.ok
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        do { return try JSONDecoder().decode(State.self, from: data) } catch {
            log.error("Bad hidutil state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveState(_ state: State) {
        do { try JSONEncoder().encode(state).write(to: stateURL, options: .atomic) } catch {
            log.error("Could not save hidutil state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The `--set` argument: `{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":…,"…Dst":…}]}`.
    static func json(_ entries: [Entry]) -> String {
        let items = entries.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }
        return "{\"UserKeyMapping\":[" + items.joined(separator: ",") + "]}"
    }

    /// Parses `hidutil property --get UserKeyMapping` output: a table with one row per service whose
    /// value is `(null)` or an old-style plist array of dictionaries. The first service that has a
    /// mapping wins (they are all set together).
    static func parse(_ output: String) -> [Entry] {
        var blocks: [[Entry]] = []
        var current: [Entry] = []
        var src: UInt64?
        var dst: UInt64?
        func number(after key: String, in line: Substring) -> UInt64? {
            guard let r = line.range(of: key) else { return nil }
            let rest = line[r.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" }
            let digits = rest.prefix { $0.isHexDigit || $0 == "x" || $0 == "X" }
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") { return UInt64(digits.dropFirst(2), radix: 16) }
            return UInt64(digits)
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)[...]
            if line.contains("UserKeyMapping") {
                if !current.isEmpty { blocks.append(current) }
                current = []
                src = nil
                dst = nil
            }
            if let v = number(after: "HIDKeyboardModifierMappingSrc", in: line) { src = v }
            if let v = number(after: "HIDKeyboardModifierMappingDst", in: line) { dst = v }
            if line.hasPrefix("}") || line.hasSuffix("}") || line.hasSuffix("},") {
                if let s = src, let d = dst { current.append(Entry(src: s, dst: d)) }
                src = nil
                dst = nil
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks.first ?? []
    }
}
