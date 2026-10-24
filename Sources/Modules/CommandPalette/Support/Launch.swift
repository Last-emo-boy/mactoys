import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Opening, copying, pasting and running things on behalf of launcher items.
@MainActor
enum Launch {
    nonisolated static let log = Log.for("cmdpal")

    /// Opens a URL (or file) in its default app, or in `bundleID` when given.
    static func open(_ url: URL, bundleID: String? = nil, arguments: [String] = []) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if !arguments.isEmpty { config.arguments = arguments }
        if let bundleID, !bundleID.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
                if let error { log.error("Open \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
            return
        }
        if url.isFileURL, url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { log.error("Launch \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
            return
        }
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error { log.error("Open \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func open(_ url: URL, withApplicationAt app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("Open with: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// Copies text and pastes it into the app that was in front of the launcher.
    static func pasteOutcome(_ text: String) -> ActionOutcome {
        copy(text)
        return pasteCurrentClipboard()
    }

    /// Pastes whatever is on the clipboard into the previous app (needs Accessibility to post ⌘V).
    static func pasteCurrentClipboard() -> ActionOutcome {
        .dismissThen {
            guard AXIsProcessTrusted() else {
                HUD.show("Copied · Accessibility permission needed to paste", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.accessibility)
                return
            }
            KeySynth.paste()
        }
    }

    static func quickLook(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log.error("Quick Look: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens a terminal window running `command` (a self-deleting `.command` file, so no
    /// Automation permission is needed).
    static func runInTerminal(_ command: String, app: TerminalApp, keepOpen: Bool, directory: URL? = nil) {
        let dir = directory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        if app == .ghostty, let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            let script = "cd \(Shell.quote(dir)); \(command)" + (keepOpen ? "; exec /bin/zsh -l" : "")
            config.arguments = ["-e", "/bin/zsh", "-lc", script]
            NSWorkspace.shared.openApplication(at: ghostty, configuration: config) { _, error in
                if let error { log.error("Ghostty: \(error.localizedDescription, privacy: .public)") }
            }
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-\(UUID().uuidString).command")
        var script = "#!/bin/zsh -l\nrm -f \"$0\"\ncd \(Shell.quote(dir))\nclear\n\(command)\n"
        if keepOpen { script += "exec /bin/zsh -l\n" }
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            log.error("Terminal script: \(error.localizedDescription, privacy: .public)")
            HUD.show("Could not open a terminal", symbol: "exclamationmark.triangle")
            return
        }
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil ? app.bundleID
            : TerminalApp.terminal.bundleID
        open(file, bundleID: bundle)
    }

    /// Opens a terminal window in a folder.
    static func openTerminal(at folder: URL, app: TerminalApp) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            open(folder, withApplicationAt: appURL)
        } else if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.terminal.bundleID) {
            open(folder, withApplicationAt: terminal)
        }
    }

    /// Search URL for the configured engine.
    static func searchURL(_ query: String, template: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let t = template.contains("%s") ? template : (template.contains("{query}") ? template : template + "%s")
        return URL(string: t.replacingOccurrences(of: "%s", with: encoded).replacingOccurrences(of: "{query}", with: encoded))
    }
}

/// Common action shortcuts, shown in the actions menu and active while an item is selected.
enum ActionKeys {
    static let secondary = Shortcut.cmd(kVK_Return)
    static let copy = Shortcut.cmd(kVK_ANSI_C)
    static let copyPath = Shortcut.cmd(kVK_ANSI_C, shift: true)
    static let openWith = Shortcut.cmd(kVK_ANSI_O)
    static let quickLook = Shortcut.cmd(kVK_ANSI_Y)
    static let trash = Shortcut.cmd(kVK_Delete)
    static let pin = Shortcut.cmd(kVK_ANSI_P, shift: true)
    static let terminal = Shortcut.cmd(kVK_ANSI_T)
    static let paste = Shortcut.cmd(kVK_ANSI_V, shift: true)
    static let close = Shortcut.cmd(kVK_ANSI_W)
    static let quit = Shortcut.cmd(kVK_ANSI_Q, option: true)
    static let info = Shortcut.cmd(kVK_ANSI_I)
    static let refresh = Shortcut.cmd(kVK_ANSI_R)
}
