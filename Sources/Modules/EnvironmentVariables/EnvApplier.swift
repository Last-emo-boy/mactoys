import Foundation
import MacToysCore

/// Writes the managed files and launchd state for a set of variables.
///
/// - `~/Library/Application Support/MacToys/envvars/env.zsh` holds the exports.
/// - `~/.zshenv` gets one managed block that sources it (every zsh: login, interactive, scripts).
/// - `~/.zprofile` optionally re-sources it after `/etc/zprofile`'s path_helper, which otherwise moves
///   system directories ahead of yours in login shells (Terminal's default).
/// - `launchctl setenv` updates apps started from now on, and a LaunchAgent repeats that at login.
///
/// Files are backed up once before MacToys first touches them; symlinked dotfiles are edited in place.
struct EnvApplier {
    var home: URL
    var dataDirectory: URL

    static var standard: EnvApplier {
        EnvApplier(home: FileManager.default.homeDirectoryForCurrentUser, dataDirectory: Paths.data(for: "envvars"))
    }

    var envFile: URL { dataDirectory.appendingPathComponent("env.zsh") }
    var backupDirectory: URL { dataDirectory.appendingPathComponent("Backups", isDirectory: true) }
    var zshenv: URL { home.appendingPathComponent(".zshenv") }
    var zprofile: URL { home.appendingPathComponent(".zprofile") }
    var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(EnvFiles.agentLabel).plist") }

    /// The path written into the startup files: `$HOME/…` keeps them portable across machines.
    var envFileReference: String {
        let path = envFile.path
        let homePath = home.path
        return path.hasPrefix(homePath + "/") ? "$HOME" + path.dropFirst(homePath.count) : path
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Applies `settings`; updates its bookkeeping. Returns non-fatal warnings.
    func apply(_ settings: inout EnvSettings, launchctl: Launchctl = .system) throws -> [String] {
        let vars = EnvComposer.effective(settings)
        let problems = EnvComposer.problems(vars)
        guard problems.isEmpty else { throw Failure(message: problems.joined(separator: "\n")) }
        var warnings: [String] = []

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try EnvFiles.zshFile(vars, profileName: settings.applied?.name)
            .write(to: envFile, atomically: true, encoding: .utf8)

        try updateStartupFile(zshenv, install: true, loginPhase: false, settings: &settings)
        try updateStartupFile(zprofile, install: settings.keepPathOrderInLoginShells && vars.contains { EnvNames.isPathLike($0.name) },
                              loginPhase: true, settings: &settings)

        if settings.applyToLaunchd {
            warnings += applyLaunchd(vars, settings: &settings, launchctl: launchctl)
        } else {
            warnings += restoreLaunchd(&settings, launchctl: launchctl)
        }
        settings.lastApplied = vars
        return warnings
    }

    /// Removes every trace: managed blocks, env.zsh, the LaunchAgent, and launchd variables (restored).
    func uninstall(_ settings: inout EnvSettings, launchctl: Launchctl = .system) throws -> [String] {
        try updateStartupFile(zshenv, install: false, loginPhase: false, settings: &settings)
        try updateStartupFile(zprofile, install: false, loginPhase: true, settings: &settings)
        try? FileManager.default.removeItem(at: envFile)
        let warnings = restoreLaunchd(&settings, launchctl: launchctl)
        settings.lastApplied = nil
        return warnings
    }

    var isInstalled: Bool {
        guard let text = try? String(contentsOf: zshenv.resolvingSymlinksInPath(), encoding: .utf8) else { return false }
        return EnvFiles.block.contains(text)
    }

    // MARK: - Startup files

    private func updateStartupFile(_ url: URL, install: Bool, loginPhase: Bool, settings: inout EnvSettings) throws {
        let target = url.resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: target.path)
        let original = exists ? try String(contentsOf: target, encoding: .utf8) : ""
        let updated = install
            ? EnvFiles.block.insert(EnvFiles.sourceLines(envFile: envFileReference, loginPhase: loginPhase), into: original)
            : EnvFiles.block.remove(from: original)
        guard updated != original else { return }
        if exists { try backupOnce(target, settings: &settings) }
        if !exists && !install { return }
        try write(updated, to: target)
    }

    /// Writes in place so permissions, ownership and hard links survive.
    private func write(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    private func backupOnce(_ url: URL, settings: inout EnvSettings) throws {
        guard !settings.backedUpFiles.contains(url.path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "-" + f.string(from: Date())
        let dest = backupDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        settings.backedUpFiles.append(url.path)
    }

    // MARK: - launchd

    private func applyLaunchd(_ vars: [EffectiveVariable], settings: inout EnvSettings, launchctl: Launchctl) -> [String] {
        var warnings: [String] = []
        // Expand against launchd's environment as it was before MacToys changed anything.
        var base = ProcessInfo.processInfo.environment
        for (name, original) in settings.launchdOriginals { base[name] = original }
        let originalPath: String? = settings.launchdOriginals.keys.contains("PATH")
            ? (settings.launchdOriginals["PATH"] ?? nil) : launchctl.get("PATH")
        base["PATH"] = originalPath ?? Launchctl.defaultPath
        let values = EnvFiles.launchdValues(vars, base: base, home: home.path)
        let names = Set(values.map(\.0))
        for (name, value) in values {
            if settings.launchdOriginals[name] == nil {
                settings.launchdOriginals[name] = .some(launchctl.get(name))
            }
            if launchctl.get(name) != value && !launchctl.set(name, value) {
                warnings.append("launchctl setenv \(name) failed")
            }
        }
        // Names MacToys set before but that are gone now: put back what was there.
        var unset: [String] = []
        for (name, original) in settings.launchdOriginals where !names.contains(name) {
            if let original { _ = launchctl.set(name, original) } else { _ = launchctl.unset(name); unset.append(name) }
            settings.launchdOriginals[name] = nil
        }
        do {
            if values.isEmpty {
                try? FileManager.default.removeItem(at: launchAgent)
            } else {
                try FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist = EnvFiles.launchAgentPlist(script: EnvFiles.launchdScript(set: values, unset: []))
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchAgent, options: .atomic)
            }
        } catch {
            warnings.append("Couldn't write the login agent: \(error.localizedDescription)")
        }
        return warnings
    }

    private func restoreLaunchd(_ settings: inout EnvSettings, launchctl: Launchctl) -> [String] {
        var warnings: [String] = []
        for (name, original) in settings.launchdOriginals {
            let ok = original.map { launchctl.set(name, $0) } ?? launchctl.unset(name)
            if !ok { warnings.append("Couldn't restore \(name) in launchd") }
        }
        settings.launchdOriginals = [:]
        if FileManager.default.fileExists(atPath: launchAgent.path) {
            launchctl.bootout(EnvFiles.agentLabel)
            try? FileManager.default.removeItem(at: launchAgent)
        }
        return warnings
    }
}

/// `launchctl` for the user's GUI domain; injectable for tests.
struct Launchctl {
    static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    var get: (String) -> String?
    var set: (String, String) -> Bool
    var unset: (String) -> Bool
    var bootout: (String) -> Void

    static let system = Launchctl(
        get: { name in
            let r = Shell.run("/bin/launchctl", ["getenv", name])
            let v = r.stdout.trimmingCharacters(in: .newlines)
            return r.ok && !v.isEmpty ? v : nil
        },
        set: { Shell.run("/bin/launchctl", ["setenv", $0, $1]).ok },
        unset: { Shell.run("/bin/launchctl", ["unsetenv", $0]).ok },
        bootout: { _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\($0)"]) })

    /// Reads the environment of the GUI domain (what `launchctl setenv` changed).
    static func domainEnvironment() -> [String: String] {
        EnvFiles.parseLaunchctlPrint(Shell.run("/bin/launchctl", ["print", "gui/\(getuid())"]).stdout)
    }
}
