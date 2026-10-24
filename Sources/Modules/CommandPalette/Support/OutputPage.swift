import AppKit
import MacToysCore

/// A page that runs a command once and shows its output in the detail pane.
@MainActor
enum OutputPage {
    private final class Runner {
        let task: Task<AsyncProcess.Output, Never>
        init(_ run: @escaping @MainActor () async -> AsyncProcess.Output) { task = Task { await run() } }
    }

    static func make(id: String, title: String, icon: ItemIcon, providerID: String,
                     run: @escaping @MainActor () async -> AsyncProcess.Output) -> ListPage {
        let runner = Runner(run)
        return ListPage(id: id, title: title, placeholder: "Filter output lines…", icon: icon) { text in
            let output = await runner.task.value
            let full = output.stdout + (output.stderr.isEmpty ? "" : (output.stdout.isEmpty ? "" : "\n") + output.stderr)
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = output.timedOut ? "Timed out" : "Exit \(output.status)"
            let duration = String(format: "%.2f s", output.duration)
            let shown = String(trimmed.prefix(200_000))
            let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let details = ItemDetails(icon: icon, title: title, subtitle: "\(status) · \(duration)", body: shown.isEmpty ? "(no output)" : shown,
                                      bodyMonospaced: true)
            let copyAll = PaletteAction(id: "copyall", title: "Copy Output", symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                Launch.copy(trimmed)
                HUD.show("Output copied", symbol: "doc.on.doc")
                return .dismiss
            }
            let summary = PaletteItem(
                id: "\(id):summary", title: lines.first(where: { !$0.isEmpty }) ?? "(no output)",
                subtitle: "\(status) · \(duration) · \(lines.count) line\(lines.count == 1 ? "" : "s")",
                icon: output.ok ? icon : .symbol("exclamationmark.triangle.fill", .orange), providerID: providerID,
                section: "Output", accessory: output.ok ? nil : status, score: 1000, primary: copyAll,
                actions: [PaletteAction(id: "paste", title: "Paste Output", symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                    Launch.pasteOutcome(trimmed)
                }],
                details: details, isPinnable: false)
            let q = text.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return [summary] }
            // Filtering shows the matching lines, each copyable.
            return lines.enumerated().filter { $0.element.localizedCaseInsensitiveContains(q) }.prefix(500).map { i, line in
                PaletteItem(id: "\(id):line:\(i)", title: line, subtitle: "Line \(i + 1)", icon: .symbol("text.alignleft", .graphite),
                            providerID: providerID, section: "Matching lines", score: 900 - Double(i) / 1000,
                            primary: PaletteAction(id: "copy", title: "Copy Line", symbol: "doc.on.doc") {
                                Launch.copy(line)
                                return .dismiss
                            },
                            actions: [copyAll], details: details, isPinnable: false)
            }
        }
    }
}
