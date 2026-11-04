import Foundation
import MacToysCore

/// Do Not Disturb through the Shortcuts app: macOS gives apps no switch for Focus, but a shortcut
/// with the Set Focus action can turn it on or off, and `shortcuts run` runs it.
enum FocusShortcuts {
    static let tool = "/usr/bin/shortcuts"

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    /// The names of the user's shortcuts, sorted.
    static func list() async -> [String] {
        guard isAvailable else { return [] }
        let r = await Shell.runAsync(tool, ["list"])
        guard r.ok else { return [] }
        return parseList(r.stdout)
    }

    static func parseList(_ output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Runs a shortcut by name; returns an error message on failure.
    static func run(_ name: String) async -> String? {
        guard isAvailable else { return String(localized: "The Shortcuts app isn’t available.") }
        let r = await Shell.runAsync(tool, ["run", name])
        if r.ok { return nil }
        let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.for("switches").error("shortcuts run \(name, privacy: .public): \(detail, privacy: .public)")
        return detail.isEmpty ? String(localized: "The shortcut “\(name)” didn’t run.", comment: "The placeholder is a Shortcuts shortcut name") : detail
    }

    /// Which shortcut turns the Focus to `on`: the off shortcut when there is one, else the same one (a toggle).
    static func shortcut(toTurnOn on: Bool, onShortcut: String?, offShortcut: String?) -> String? {
        if on { return onShortcut }
        return offShortcut ?? onShortcut
    }

    /// Whether any Focus is on, from the Do Not Disturb database when MacToys may read it
    /// (it needs Full Disk Access); nil when it can't tell.
    static func readFocusState() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseAssertions(data)
    }

    /// `{"data":[{"storeAssertionRecords":[…]}]}`: any record means a Focus is active.
    static func parseAssertions(_ data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return nil }
        return entries.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }
}
