import AppKit
import MacToysCore
import SQLite3

/// Code editors built on VS Code whose recent workspaces can be read.
enum CodeEditor: String, CaseIterable, Sendable, Identifiable {
    case vscode, insiders, cursor, windsurf, vscodium
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .insiders: "VS Code Insiders"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .vscodium: "VSCodium"
        }
    }

    var bundleID: String {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .insiders: "com.microsoft.VSCodeInsiders"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .windsurf: "com.exafunction.windsurf"
        case .vscodium: "com.vscodium"
        }
    }

    /// Folder under Application Support holding `User/globalStorage/state.vscdb`.
    var supportFolder: String {
        switch self {
        case .vscode: "Code"
        case .insiders: "Code - Insiders"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .vscodium: "VSCodium"
        }
    }

    /// The bundled command-line launcher, used for remote workspaces.
    func cli(app: URL) -> URL {
        let name = self == .vscodium ? "codium" : self == .cursor ? "cursor" : self == .windsurf ? "windsurf"
            : self == .insiders ? "code-insiders" : "code"
        return app.appendingPathComponent("Contents/Resources/app/bin/\(name)")
    }
}

/// One recently opened folder, file or workspace.
struct EditorWorkspace: Sendable, Hashable {
    enum Kind: String, Sendable { case folder, file, workspace }
    let editor: CodeEditor
    let uri: String
    let kind: Kind
    /// Remote authority (`ssh-remote+host`, `wsl+Ubuntu`, `dev-container+…`), nil for local paths.
    let remote: String?

    var url: URL? { URL(string: uri) }
    var name: String {
        let last = url.map { $0.lastPathComponent } ?? uri
        return last.isEmpty ? uri : (last.removingPercentEncoding ?? last)
    }
    var displayPath: String {
        guard let url else { return uri }
        if url.isFileURL { return (url.path as NSString).abbreviatingWithTildeInPath }
        return url.path
    }
}

enum EditorHistory {
    /// Reads `history.recentlyOpenedPathsList` from the editor's state database.
    static func read(_ editor: CodeEditor) -> [EditorWorkspace] {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(editor.supportFolder)/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        let bytes = sqlite3_column_blob(stmt, 0)
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard let bytes, count > 0 else { return [] }
        return parse(Data(bytes: bytes, count: count), editor: editor)
    }

    static func parse(_ data: Data, editor: CodeEditor) -> [EditorWorkspace] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            let remote = e["remoteAuthority"] as? String
            if let folder = e["folderUri"] as? String { return EditorWorkspace(editor: editor, uri: folder, kind: .folder, remote: remote) }
            if let file = e["fileUri"] as? String { return EditorWorkspace(editor: editor, uri: file, kind: .file, remote: remote) }
            if let ws = e["workspace"] as? [String: Any], let config = ws["configPath"] as? String {
                return EditorWorkspace(editor: editor, uri: config, kind: .workspace, remote: remote)
            }
            return nil
        }
    }
}

/// VS Code workspaces (`{`): reopen recent folders, files and remote workspaces of VS Code-based editors.
@MainActor
final class EditorsProvider: SearchProvider {
    let id = "editors"
    let name = "Code Workspaces"
    let summary = "Reopen recent VS Code, Cursor, Windsurf and VSCodium folders and workspaces"
    let icon = ItemIcon.symbol("chevron.left.forwardslash.chevron.right", .blue)
    let defaultKeyword = "{"
    let examples = ["{ mactoys", "{  (every recent workspace)"]

    private let engine: LauncherEngine
    private var workspaces: [EditorWorkspace] = []
    private var loadedAt: Date?

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        installed.isEmpty ? [] : [pageCommand(title: "Code Workspaces", subtitle: "Recent folders in \(installed.map(\.title).joined(separator: ", "))",
                                              keywords: ["vscode", "code", "cursor", "projects", "recent"])]
    }

    private var installed: [CodeEditor] {
        CodeEditor.allCases.filter {
            (engine.options.value.editors[$0.rawValue] ?? true) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    func launcherWillShow() { loadedAt = nil }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard query.scoped || text.count >= 2 else { return [] }
        if loadedAt == nil {
            let editors = installed
            workspaces = await background { editors.flatMap(EditorHistory.read) }
            loadedAt = Date()
        }
        guard !Task.isCancelled else { return [] }
        if text.isEmpty { return workspaces.prefix(200).enumerated().map { i, w in item(w, score: 1000 - Double(i)) } }
        return workspaces.enumerated().compactMap { i, w in
            guard let s = FuzzyMatcher.best(text, title: w.name, keywords: [w.displayPath, w.remote ?? ""]) else { return nil }
            return item(w, score: (query.scoped ? s : s * 0.8) - Double(i) * 0.01)
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("editors:") else { return nil }
        let rest = id.dropFirst(8)
        guard let colon = rest.firstIndex(of: ":"), let editor = CodeEditor(rawValue: String(rest[..<colon])) else { return nil }
        let uri = String(rest[rest.index(after: colon)...])
        let kind: EditorWorkspace.Kind = uri.hasSuffix(".code-workspace") ? .workspace : .folder
        return item(EditorWorkspace(editor: editor, uri: uri, kind: kind, remote: nil), score: 0)
    }

    func item(_ w: EditorWorkspace, score: Double) -> PaletteItem {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: w.editor.bundleID)
        let symbol = w.kind == .file ? "doc.text" : w.kind == .workspace ? "square.stack.3d.up.fill" : "folder.fill"
        let where_ = w.remote.map { "Remote · \($0)" } ?? w.displayPath
        var actions: [PaletteAction] = []
        if let url = w.url, url.isFileURL {
            actions.append(PaletteAction(id: "reveal", title: "Show in Finder", symbol: "folder", shortcut: ActionKeys.secondary) {
                Launch.reveal(url)
                return .dismiss
            })
            actions.append(PaletteAction(id: "terminal", title: "Open in \(engine.options.value.terminal.title)", symbol: "terminal",
                                         shortcut: ActionKeys.terminal) {
                Launch.openTerminal(at: w.kind == .folder ? url : url.deletingLastPathComponent(), app: self.engine.options.value.terminal)
                return .dismiss
            })
        }
        actions.append(PaletteAction(id: "copy", title: "Copy Path", symbol: "doc.on.doc", shortcut: ActionKeys.copyPath) {
            Launch.copy(w.url?.isFileURL == true ? (w.url?.path ?? w.uri) : w.uri)
            return .dismiss
        })
        return PaletteItem(
            id: "editors:\(w.editor.rawValue):\(w.uri)", title: w.name, subtitle: "\(where_) · \(w.editor.title)",
            icon: app.map { .file($0.path) } ?? .symbol(symbol, .blue), providerID: id,
            accessory: w.kind == .workspace ? "Workspace" : w.kind == .file ? "File" : "Folder", score: score,
            primary: PaletteAction(id: "open", title: "Open in \(w.editor.title)", symbol: "chevron.left.forwardslash.chevron.right") {
                self.open(w, app: app)
                return .dismiss
            },
            actions: actions)
    }

    private func open(_ w: EditorWorkspace, app: URL?) {
        guard let app else { return }
        if let url = w.url, url.isFileURL {
            Launch.open(url, withApplicationAt: app)
            return
        }
        // Remote workspaces go through the editor's CLI: `code --folder-uri vscode-remote://…`.
        let cli = w.editor.cli(app: app)
        let flag = w.kind == .file ? "--file-uri" : "--folder-uri"
        Task { _ = await AsyncProcess.run(cli.path, [flag, w.uri], timeout: 20) }
    }
}
