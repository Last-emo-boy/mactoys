import AppKit
import MacToysCore
import UniformTypeIdentifiers

/// One script in the Script Commands folder.
struct ScriptCommand: Sendable, Hashable {
    let url: URL
    let meta: ScriptMetadata
}

enum ScriptLibrary {
    static let example = """
    #!/bin/zsh
    # A MacToys Script Command. Executable scripts in this folder become commands in
    # Command Palette and Run. Metadata lines near the top look like the ones below
    # (Raycast's "@raycast." keys work too).
    #
    # @mactoys.title Say Hello
    # @mactoys.subtitle Example script command · edit or delete me
    # @mactoys.icon hand.wave.fill
    # @mactoys.mode output
    # @mactoys.argument Name (optional)
    # @mactoys.keywords greet example
    #
    # Modes: silent (a HUD shows the last line), output (shows the full output), inline (the first
    # line becomes the subtitle; refresh with @mactoys.refresh 1m), terminal (runs in a terminal).
    # The argument arrives as $1. The icon is an SF Symbol name or an emoji.

    name="${1:-there}"
    echo "Hello, $name!"
    echo ""
    echo "It is $(date '+%A, %d %B %Y, %H:%M')."
    echo "This Mac: $(scutil --get ComputerName 2>/dev/null), macOS $(sw_vers -productVersion)."
    echo "Edit me: $0"

    """

    static let template = """
    #!/bin/zsh
    # @mactoys.title New Script
    # @mactoys.subtitle What it does
    # @mactoys.icon terminal.fill
    # @mactoys.mode silent
    # Optional: @mactoys.argument Placeholder

    echo "Done"

    """

    static func scan(_ folder: URL) -> [ScriptCommand] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url -> ScriptCommand? in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
            let executable = fm.isExecutableFile(atPath: url.path)
            guard executable || head.hasPrefix("#!") else { return nil }
            return ScriptCommand(url: url, meta: ScriptMetadata.parse(head, fileName: url.lastPathComponent))
        }
        .sorted { $0.meta.title.localizedCaseInsensitiveCompare($1.meta.title) == .orderedAscending }
    }

    /// Runs a script directly when executable, else through its `#!` interpreter.
    static func execute(_ s: ScriptCommand, argument: String?) async -> AsyncProcess.Output {
        let args = argument.map { [$0] } ?? []
        let dir = s.url.deletingLastPathComponent()
        if FileManager.default.isExecutableFile(atPath: s.url.path) {
            return await AsyncProcess.run(s.url.path, args, currentDirectory: dir, timeout: 120)
        }
        let first = (try? String(contentsOf: s.url, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        if first.hasPrefix("#!") {
            let parts = first.dropFirst(2).split(separator: " ").map(String.init)
            if let exe = parts.first {
                return await AsyncProcess.run(exe, Array(parts.dropFirst()) + [s.url.path] + args, currentDirectory: dir, timeout: 120)
            }
        }
        return await AsyncProcess.run("/bin/zsh", [s.url.path] + args, currentDirectory: dir, timeout: 120)
    }
}

/// Script Commands: executable scripts with a metadata header become commands
/// (the macOS counterpart of Command Palette extensions).
@MainActor
final class ScriptsProvider: SearchProvider {
    let id = "scripts"
    let name = "Script Commands"
    let summary = "Your own commands: executable scripts in the Script Commands folder"
    let icon = ItemIcon.symbol("scroll.fill", .green)
    let defaultKeyword = ":"
    let examples = [": say hello", ":  (all scripts)"]

    private let engine: LauncherEngine
    private var scripts: [ScriptCommand] = []
    private var scannedAt: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var inline: [URL: (text: String, date: Date)] = [:]
    private var refreshing: Set<URL> = []
    private let log = Log.for("cmdpal")

    init(engine: LauncherEngine) { self.engine = engine }

    var folder: URL { engine.options.value.resolvedScriptsFolder }

    func activate() {
        prepareFolder()
        rescan()
        watch()
    }

    func deactivate() {
        watcher?.cancel()
        watcher = nil
    }

    func launcherWillShow() {
        if scannedAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true { rescan() }
        refreshInlineScripts()
    }

    /// Creates the folder and, the first time, the example script.
    func prepareFolder() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !engine.options.value.exampleScriptCreated else { return }
            let example = folder.appendingPathComponent("say-hello.sh")
            if !fm.fileExists(atPath: example.path) {
                try ScriptLibrary.example.write(to: example, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: example.path)
            }
            engine.options.value.exampleScriptCreated = true
        } catch {
            log.error("Script folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    func rescan() {
        let dir = folder
        Task { [weak self] in
            let list = await background { ScriptLibrary.scan(dir) }
            guard let self else { return }
            let changed = list != self.scripts
            self.scripts = list
            self.scannedAt = Date()
            if changed { self.engine.notifyChange(self.id) }
            self.refreshInlineScripts()
        }
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.rescan() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func refreshInlineScripts() {
        for s in scripts where s.meta.mode == .inline && s.meta.argument == nil {
            let interval = s.meta.refreshInterval ?? 60
            if let cached = inline[s.url], Date().timeIntervalSince(cached.date) < interval { continue }
            refreshInline(s)
        }
    }

    private func refreshInline(_ s: ScriptCommand) {
        guard refreshing.insert(s.url).inserted else { return }
        Task { [weak self] in
            let out = await ScriptLibrary.execute(s, argument: nil)
            guard let self else { return }
            self.refreshing.remove(s.url)
            let line = out.text.split(separator: "\n").first.map(String.init) ?? (out.ok ? "" : "Exit \(out.status)")
            self.inline[s.url] = (line, Date())
            self.engine.notifyChange(self.id)
        }
    }

    var commands: [PaletteItem] {
        scripts.map { item($0, score: 0) } + [
            PaletteItem(id: "scripts:folder", title: "Open Script Commands Folder", subtitle: (folder.path as NSString).abbreviatingWithTildeInPath,
                        icon: .file(folder.path), providerID: id, section: "Commands", accessory: "Folder",
                        primary: PaletteAction(id: "open", title: "Open", symbol: "folder") {
                            self.prepareFolder()
                            Launch.open(self.folder)
                            return .dismiss
                        }, keywords: ["scripts", "extensions"]),
            PaletteItem(id: "scripts:new", title: "Create Script Command", subtitle: "Start a new script from a template",
                        icon: .symbol("plus.square.fill", .green), providerID: id, section: "Commands", accessory: "Command",
                        primary: PaletteAction(id: "create", title: "Create", symbol: "plus") { self.createScript() },
                        keywords: ["new script", "extension", "create extension"]),
        ]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return commands.enumerated().map { i, it in
                var c = it
                c.score = 500 - Double(i)
                return c
            }
        }
        // `say hello Ada`: a script title followed by its argument.
        var out: [PaletteItem] = []
        for s in scripts where s.meta.argument != nil {
            let lower = text.lowercased(), title = s.meta.title.lowercased()
            if lower.hasPrefix(title + " ") {
                let arg = String(text.dropFirst(title.count + 1))
                var it = item(s, score: 990, argument: arg)
                it.title = "\(s.meta.title) “\(arg)”"
                out.append(it)
            }
        }
        out += scripts.compactMap { s in
            FuzzyMatcher.best(text, title: s.meta.title, keywords: s.meta.keywords + (s.meta.subtitle.map { [$0] } ?? []))
                .map { item(s, score: $0) }
        }
        return out
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        return nil
    }

    func item(_ s: ScriptCommand, score: Double, argument: String? = nil) -> PaletteItem {
        let m = s.meta
        let icon: ItemIcon
        if let i = m.icon, !i.isEmpty {
            icon = NSImage(systemSymbolName: i, accessibilityDescription: nil) != nil ? .symbol(i, .green) : .emoji(i)
        } else {
            icon = self.icon
        }
        var subtitle = m.subtitle ?? m.mode.title
        if m.mode == .inline { subtitle = inline[s.url]?.text ?? "Loading…" }
        let path = s.url
        let o = engine.options.value
        return PaletteItem(
            id: "scripts:\(s.url.path)", title: m.title, subtitle: subtitle, icon: icon, providerID: id, section: name,
            accessory: m.argument != nil ? "Argument" : "Script", score: score,
            primary: PaletteAction(id: "run", title: "Run Script", symbol: "play.fill") { self.run(s, argument: argument) },
            actions: [
                PaletteAction(id: "terminal", title: "Run in \(o.terminal.title)", symbol: "terminal", shortcut: ActionKeys.terminal) {
                    let cmd = Shell.quote(path.path) + (argument.map { " " + Shell.quote($0) } ?? "")
                    Launch.runInTerminal(cmd, app: o.terminal, keepOpen: true, directory: path.deletingLastPathComponent())
                    return .dismiss
                },
                PaletteAction(id: "edit", title: "Edit Script", symbol: "pencil", shortcut: ActionKeys.openWith) {
                    Self.openInEditor(path)
                    return .dismiss
                },
                PaletteAction(id: "reveal", title: "Show in Finder", symbol: "folder", shortcut: ActionKeys.secondary) {
                    Launch.reveal(path)
                    return .dismiss
                },
                PaletteAction(id: "copypath", title: "Copy Path", symbol: "doc.on.doc", shortcut: ActionKeys.copyPath) {
                    Launch.copy(path.path)
                    return .dismiss
                },
            ],
            details: ItemDetails(icon: icon, title: m.title, subtitle: m.subtitle, rows: [
                DetailRow(label: "Mode", value: m.mode.title, monospaced: false),
                DetailRow(label: "Argument", value: m.argument.map { $0 + (m.argumentOptional ? " (optional)" : "") } ?? "None",
                          monospaced: false),
                DetailRow(label: "File", value: path.lastPathComponent),
            ]),
            keywords: m.keywords)
    }

    func run(_ s: ScriptCommand, argument: String?) -> ActionOutcome {
        if let placeholder = s.meta.argument, argument == nil {
            return .push(argumentPage(s, placeholder: placeholder))
        }
        if s.meta.needsConfirmation {
            return .confirm(Confirmation(title: "Run “\(s.meta.title)”?", message: s.url.lastPathComponent, confirmTitle: "Run",
                                         destructive: false) { self.execute(s, argument: argument) })
        }
        return execute(s, argument: argument)
    }

    private func execute(_ s: ScriptCommand, argument: String?) -> ActionOutcome {
        let o = engine.options.value
        switch s.meta.mode {
        case .silent:
            Task {
                let out = await ScriptLibrary.execute(s, argument: argument)
                let last = out.text.split(separator: "\n").last.map(String.init)
                if out.ok {
                    HUD.show(String((last ?? "\(s.meta.title) done").prefix(90)), symbol: "checkmark.circle")
                } else {
                    HUD.show(out.timedOut ? "\(s.meta.title) timed out" : String((last ?? "Exit \(out.status)").prefix(90)),
                             symbol: "exclamationmark.triangle", duration: 3)
                }
            }
            return .dismiss
        case .output:
            return .push(OutputPage.make(id: "scripts:output:\(s.url.path)", title: s.meta.title, icon: icon, providerID: id) {
                await ScriptLibrary.execute(s, argument: argument)
            })
        case .inline:
            inline[s.url] = nil
            refreshInline(s)
            return .stay
        case .terminal:
            let cmd = Shell.quote(s.url.path) + (argument.map { " " + Shell.quote($0) } ?? "")
            Launch.runInTerminal(cmd, app: o.terminal, keepOpen: true, directory: s.url.deletingLastPathComponent())
            return .dismiss
        }
    }

    private func argumentPage(_ s: ScriptCommand, placeholder: String) -> ListPage {
        ListPage(id: "scripts:argument:\(s.url.path)", title: s.meta.title, placeholder: placeholder, icon: icon) { [weak self] text in
            guard let self else { return [] }
            let arg = text.trimmingCharacters(in: .whitespaces)
            guard !arg.isEmpty || s.meta.argumentOptional else {
                return [PaletteItem(id: "scripts:argument:hint", title: "Type \(placeholder.lowercased())", subtitle: s.meta.title,
                                    icon: self.icon, providerID: self.id, score: 1,
                                    primary: PaletteAction(id: "none", title: "OK", symbol: "checkmark", recordsUsage: false) { .stay },
                                    isPinnable: false)]
            }
            var it = self.item(s, score: 1000, argument: arg)
            it.title = arg.isEmpty ? "Run \(s.meta.title)" : "Run \(s.meta.title) with “\(arg)”"
            it.isPinnable = false
            it.primary = PaletteAction(id: "run", title: "Run", symbol: "play.fill") {
                if s.meta.needsConfirmation {
                    return .confirm(Confirmation(title: "Run “\(s.meta.title)”?", message: arg, confirmTitle: "Run", destructive: false) {
                        self.execute(s, argument: arg)
                    })
                }
                return self.execute(s, argument: arg)
            }
            return [it]
        }
    }

    private func createScript() -> ActionOutcome {
        prepareFolder()
        var n = 1
        var url = folder.appendingPathComponent("new-script.sh")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("new-script-\(n).sh")
        }
        do {
            try ScriptLibrary.template.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            Self.openInEditor(url)
            rescan()
        } catch {
            HUD.show("Couldn’t create the script", symbol: "exclamationmark.triangle")
            log.error("Create script: \(error.localizedDescription, privacy: .public)")
        }
        return .dismiss
    }

    /// Opens a script in the user's text editor (never in Terminal, which would run it).
    static func openInEditor(_ url: URL) {
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            Launch.open(url, withApplicationAt: editor)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            Launch.open(url, withApplicationAt: textEdit)
        }
    }
}
