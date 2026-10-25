import AppKit
import MacToysCore

/// Shell (`>`): runs a command in a terminal, silently, or shows its output.
@MainActor
final class ShellProvider: SearchProvider {
    let id = "shell"
    let name = String(localized: "Shell", comment: "Provider name: shell commands")
    let summary = String(localized: "Run shell commands in a terminal, silently, or show their output")
    let icon = ItemIcon.symbol("terminal.fill", .graphite)
    let defaultKeyword = ">"
    let globalByDefault = false
    let examples = ["> ping -c 3 apple.com", "> open ~/Downloads", "> brew upgrade"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Run Shell Command"),
                     subtitle: String(localized: "Run a command in \(engine.options.value.terminal.title) or silently",
                                      comment: "%@ is a terminal app such as Terminal or iTerm2"),
                     keywords: ["terminal", "command", "zsh", "bash"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let o = engine.options.value
        let history = o.shellRememberHistory ? engine.usage.shellHistory : []
        if text.isEmpty {
            guard query.scoped else { return [] }
            return history.prefix(30).enumerated().map { i, cmd in historyItem(cmd, score: 500 - Double(i)) }
        }
        var items: [PaletteItem] = []
        let modes = [o.shellMode] + ShellMode.allCases.filter { $0 != o.shellMode }
        for (i, mode) in modes.enumerated() {
            items.append(item(text, mode: mode, score: 990 - Double(i)))
        }
        items += history.filter { $0 != text }.compactMap { cmd in
            FuzzyMatcher.score(text, cmd).map { historyItem(cmd, score: min($0, 800)) }
        }.prefix(10)
        return items
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        // Commands are rebuilt only for history entries the user ran before; links can't inject new ones silently.
        guard id.hasPrefix("shell:history:") else { return nil }
        let cmd = String(id.dropFirst(14))
        return engine.usage.shellHistory.contains(cmd) ? historyItem(cmd, score: 0) : nil
    }

    private func historyItem(_ cmd: String, score: Double) -> PaletteItem {
        var it = item(cmd, mode: engine.options.value.shellMode, score: score)
        it.id = "shell:history:\(cmd)"
        it.title = cmd
        it.subtitle = String(localized: "From history · \(engine.options.value.shellMode.title)", comment: "%@ is how the command runs, e.g. “Run silently”")
        it.section = String(localized: "History", comment: "Provider name: results selected before")
        it.isPinnable = true
        it.actions.append(PaletteAction(id: "forget", title: Labels.removeFromHistory, symbol: "trash", recordsUsage: false) {
            self.engine.usage.removeShell(cmd)
            return .refresh
        })
        return it
    }

    func item(_ cmd: String, mode: ShellMode, score: Double) -> PaletteItem {
        let o = engine.options.value
        let title: String
        switch mode {
        case .terminal: title = String(localized: "Run “\(cmd)” in \(o.terminal.title)", comment: "%1$@ is a shell command, %2$@ a terminal app")
        case .silent: title = String(localized: "Run “\(cmd)” silently", comment: "%@ is a shell command")
        case .output: title = String(localized: "Run “\(cmd)” and show output", comment: "%@ is a shell command")
        }
        let actions = ShellMode.allCases.filter { $0 != mode }.map { other in
            PaletteAction(id: "mode.\(other.rawValue)", title: other.title, symbol: symbol(other),
                          shortcut: other == .terminal ? ActionKeys.terminal : nil) { self.run(cmd, mode: other) }
        } + [PaletteAction(id: "copy", title: String(localized: "Copy Command"), symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
            Launch.copy(cmd)
            return .dismiss
        }]
        return PaletteItem(
            id: "shell:run:\(mode.rawValue):\(cmd)", title: title, subtitle: "/bin/zsh -l · \(mode.title)",
            icon: .symbol(symbol(mode), .graphite), providerID: id, accessory: name, score: score,
            primary: PaletteAction(id: "run", title: Labels.run, symbol: symbol(mode)) { self.run(cmd, mode: mode) },
            actions: actions,
            details: ItemDetails(icon: .symbol("terminal.fill", .graphite), title: cmd, subtitle: mode.title, body: cmd,
                                 bodyMonospaced: true),
            isPinnable: false)
    }

    private func symbol(_ mode: ShellMode) -> String {
        switch mode {
        case .terminal: "terminal.fill"
        case .silent: "bolt.fill"
        case .output: "text.alignleft"
        }
    }

    func run(_ cmd: String, mode: ShellMode) -> ActionOutcome {
        let o = engine.options.value
        if o.shellRememberHistory { engine.usage.recordShell(cmd) }
        switch mode {
        case .terminal:
            Launch.runInTerminal(cmd, app: o.terminal, keepOpen: o.shellKeepOpen)
            return .dismiss
        case .silent:
            Task {
                let r = await AsyncProcess.shell(cmd, timeout: 600)
                if r.ok {
                    let last = r.text.split(separator: "\n").last.map(String.init)
                        ?? String(localized: "Done", comment: "HUD: a silent shell command finished without output")
                    HUD.show(String(last.prefix(80)), symbol: "checkmark.circle")
                } else if r.timedOut {
                    HUD.show("Timed out: \(cmd)", symbol: "exclamationmark.triangle", duration: 3)
                } else {
                    HUD.show("Exit \(r.status): \(String(r.text.prefix(70)))", symbol: "exclamationmark.triangle", duration: 3)
                }
            }
            return .dismiss
        case .output:
            return .push(OutputPage.make(id: "shell:output:\(cmd)", title: cmd, icon: .symbol("text.alignleft", .graphite),
                                         providerID: id) { await AsyncProcess.shell(cmd, timeout: 120) })
        }
    }
}
