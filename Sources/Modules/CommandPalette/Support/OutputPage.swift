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
        return ListPage(id: id, title: title, placeholder: String(localized: "Filter output lines…"), icon: icon) { text in
            let output = await runner.task.value
            let full = output.stdout + (output.stderr.isEmpty ? "" : (output.stdout.isEmpty ? "" : "\n") + output.stderr)
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = output.timedOut ? String(localized: "Timed out", comment: "The command took too long and was stopped")
                : String(localized: "Exit \(output.status)", comment: "A command or script ended; %d is its exit status")
            let duration = Duration.seconds(output.duration)
                .formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 2)))
            let shown = String(trimmed.prefix(200_000))
            let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let noOutput = String(localized: "(no output)", comment: "The command printed nothing")
            let details = ItemDetails(icon: icon, title: title, subtitle: "\(status) · \(duration)", body: shown.isEmpty ? noOutput : shown,
                                      bodyMonospaced: true)
            let copyAll = PaletteAction(id: "copyall", title: String(localized: "Copy Output"), symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                Launch.copy(trimmed)
                HUD.show("Output copied", symbol: "doc.on.doc")
                return .dismiss
            }
            let summary = PaletteItem(
                id: "\(id):summary", title: lines.first(where: { !$0.isEmpty }) ?? noOutput,
                subtitle: "\(status) · \(duration) · \(String(localized: "\(lines.count) lines", comment: "How many lines a command printed"))",
                icon: output.ok ? icon : .symbol("exclamationmark.triangle.fill", .orange), providerID: providerID,
                section: String(localized: "Output", comment: "Section heading: a command's output"), accessory: output.ok ? nil : status,
                score: 1000, primary: copyAll,
                actions: [PaletteAction(id: "paste", title: String(localized: "Paste Output"), symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                    Launch.pasteOutcome(trimmed)
                }],
                details: details, isPinnable: false)
            let q = text.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return [summary] }
            // Filtering shows the matching lines, each copyable.
            return lines.enumerated().filter { $0.element.localizedCaseInsensitiveContains(q) }.prefix(500).map { i, line in
                PaletteItem(id: "\(id):line:\(i)", title: line, subtitle: String(localized: "Line \(i + 1)", comment: "Line number in a command's output"),
                            icon: .symbol("text.alignleft", .graphite),
                            providerID: providerID, section: String(localized: "Matching lines", comment: "Section heading: output lines that match the filter"),
                            score: 900 - Double(i) / 1000,
                            primary: PaletteAction(id: "copy", title: String(localized: "Copy Line"), symbol: "doc.on.doc") {
                                Launch.copy(line)
                                return .dismiss
                            },
                            actions: [copyAll], details: details, isPinnable: false)
            }
        }
    }
}
