import Darwin
import Foundation
import MacToysCore

/// "Create shortcut": a file that launches a workspace through `mactoys://workspaces/launch?name=…`.
enum WorkspaceExport {
    enum Kind: String, CaseIterable, Identifiable {
        /// A tiny AppleScript app — can sit in the Dock like any app.
        case app
        /// A web location file: opens without a Terminal window.
        case webloc
        /// A shell script for scripts and automation.
        case command

        var id: String { rawValue }
        var fileExtension: String { rawValue }

        var title: String {
            switch self {
            case .app: "App (for the Dock)"
            case .webloc: "Web Location (.webloc)"
            case .command: "Shell Script (.command)"
            }
        }
    }

    enum ExportError: Error, LocalizedError {
        case compileFailed(String)
        var errorDescription: String? {
            switch self {
            case .compileFailed(let why): "Couldn't create the app: \(why)"
            }
        }
    }

    static func launchURL(for workspace: Workspace) -> URL {
        AppCommand(module: "workspaces", action: "launch", parameters: ["name": workspace.name]).url
    }

    static func weblocData(for url: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    static func commandScript(for url: URL) -> String {
        "#!/bin/sh\n# Launches a MacToys workspace.\nopen \(Shell.quote(url.absoluteString))\n"
    }

    static func appleScript(for url: URL) -> String {
        "open location \(AppleScript.literal(url.absoluteString))"
    }

    /// A file name without characters Finder or the shell would trip over.
    static func fileName(for name: String, kind: Kind) -> String {
        let cleaned = name.map { "/:".contains($0) ? "-" : $0 }
        let base = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "Workspace" : base).\(kind.fileExtension)"
    }

    /// Writes the shortcut to `destination` (replacing what's there).
    static func write(_ kind: Kind, for workspace: Workspace, to destination: URL) throws {
        let url = launchURL(for: workspace)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        switch kind {
        case .webloc:
            try weblocData(for: url).write(to: destination, options: .atomic)
        case .command:
            try commandScript(for: url).write(to: destination, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        case .app:
            let result = Shell.run("/usr/bin/osacompile", ["-o", destination.path, "-e", appleScript(for: url)])
            guard result.ok else { throw ExportError.compileFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

/// When the user logged in, to tell a launch at login from a later start of MacToys.
enum LoginSession {
    /// The most recent console login of `user` (from the utmpx database).
    static func consoleLoginDate(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent() {
            let e = entry.pointee
            guard e.ut_type == Int16(USER_PROCESS) else { continue }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }

    /// Whether an app launched at `appLaunch` was started as part of logging in at `login`.
    static func isLoginLaunch(appLaunch: Date, login: Date?, window: TimeInterval = 180) -> Bool {
        guard let login else { return false }
        let delay = appLaunch.timeIntervalSince(login)
        return delay >= -10 && delay <= window
    }
}
