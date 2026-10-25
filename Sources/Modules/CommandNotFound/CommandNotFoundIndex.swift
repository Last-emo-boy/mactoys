import AppKit
import Foundation
import MacToysCore

/// Homebrew's executables database (`executables.txt`): one formula per line,
/// `formula:exe exe…` or the older `formula(version):exe exe…`.
enum CNFIndex {
    /// Executable → formulae that install it, in file order.
    static func parse(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (formula, exes) = entry(line) else { continue }
            for exe in exes where out[exe]?.contains(formula) != true { out[exe, default: []].append(formula) }
        }
        return out
    }

    /// One line → (formula, executables); nil for blank or malformed lines.
    static func entry(_ line: Substring) -> (String, [String])? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var formula = line[..<colon].trimmingCharacters(in: .whitespaces)
        if let paren = formula.firstIndex(of: "(") { formula = String(formula[..<paren]) }
        guard !formula.isEmpty else { return nil }
        let rest: Substring = line[line.index(after: colon)...]
        let exes = rest.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        return exes.isEmpty ? nil : (formula, exes)
    }

    /// Formulae providing `command`, scanning the text (fast enough for every miss in a shell).
    static func formulae(for command: String, in text: String) -> [String] {
        guard !command.isEmpty, !command.contains(" "), !command.contains("/") else { return [] }
        var out: [String] = []
        let needle = " " + command + " "
        for line in text.split(whereSeparator: \.isNewline) where line.contains(command) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let list = " " + line[line.index(after: colon)...] + " "
            guard list.contains(needle), let (formula, _) = entry(line), !out.contains(formula) else { continue }
            out.append(formula)
        }
        return out
    }

    /// Whether downloaded text looks like the database (guards against error pages).
    static func looksValid(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).prefix(200)
        return lines.count >= 50 && lines.filter { entry($0) != nil }.count >= lines.count * 9 / 10
    }

    static func formulaCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).count { entry($0) != nil }
    }
}

/// The managed `command_not_found_handler` in `~/.zshrc`.
enum CNFShell {
    /// For a damaged block (no end marker), only lines that are exactly ours are removed with it.
    static let block = ManagedBlock(name: "Command Not Found") { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("local helper=") || handlerLines(helper: "").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("local helper=") }.contains(t)
    }

    static func singleQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The handler: asks MacToys for suggestions when the helper exists and stderr is a terminal,
    /// otherwise prints zsh's usual message. Always returns 127 like zsh.
    static func handlerLines(helper: String) -> [String] {
        [
            "# Managed by MacToys › Command Not Found. Remove it from there.",
            "command_not_found_handler() {",
            "  local helper=\(singleQuoted(helper))",
            "  if [[ -t 2 && -x \"$helper\" ]]; then",
            "    \"$helper\" cnf \"$1\"",
            "  else",
            "    print -u2 -r -- \"zsh: command not found: $1\"",
            "  fi",
            "  return 127",
            "}",
        ]
    }

    /// The helper path written in an installed block.
    static func installedHelper(in text: String) -> String? {
        guard let body = block.body(in: text),
              let line = body.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("local helper=") }) else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces).dropFirst("local helper=".count)
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 { value = value.dropFirst().dropLast() }
        return String(value).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Other handlers (Homebrew's `brew command-not-found-init`, oh-my-zsh plugins…) outside our block.
    static func otherHandlers(in text: String) -> Bool {
        let outside = block.remove(from: text)
        return outside.components(separatedBy: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#") else { return false }
            return l.contains("command_not_found_handler") || l.contains("command-not-found")
        }
    }
}

/// Where things live.
enum CNFPaths {
    static var index: URL { Paths.data(for: "cmdnotfound").appendingPathComponent("executables.txt") }

    /// `$ZDOTDIR/.zshrc` when zsh's environment sets ZDOTDIR, else `~/.zshrc`.
    static func zshrc() -> URL {
        let r = Shell.run("/bin/zsh", ["-c", "print -r -- ${ZDOTDIR:-$HOME}"])
        let dir = r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : NSHomeDirectory()
        return URL(fileURLWithPath: dir.isEmpty ? NSHomeDirectory() : dir).appendingPathComponent(".zshrc")
    }

    /// The `mactoys` helper inside the running app (or an installed copy).
    static func helper() -> String? {
        var candidates: [URL] = []
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { candidates.append(bundle) }
        candidates += [URL(fileURLWithPath: "/Applications/MacToys.app"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MacToys.app")]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.bundleIdentifier) { candidates.append(url) }
        for app in candidates {
            let helper = app.appendingPathComponent("Contents/Helpers/mactoys").path
            if FileManager.default.isExecutableFile(atPath: helper) { return helper }
        }
        return nil
    }

    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"]

    static var brew: String? { brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Homebrew's own copy of the database, kept current by `brew update`.
    static var homebrewCache: URL {
        let cache = ProcessInfo.processInfo.environment["HOMEBREW_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew")
        return cache.appendingPathComponent("api/internal/executables.txt")
    }

    /// Whether a formula is installed (its executables may just not be linked).
    static func isInstalled(_ formula: String) -> Bool {
        let name = formula.split(separator: "/").last.map(String.init) ?? formula
        return ["/opt/homebrew/Cellar", "/usr/local/Cellar", "/home/linuxbrew/.linuxbrew/Cellar"].contains {
            FileManager.default.fileExists(atPath: "\($0)/\(name)")
        }
    }
}

/// Downloads the database Homebrew publishes on GitHub Packages (the successor of the
/// homebrew-command-not-found tap's executables.txt), falling back to Homebrew's local cache.
enum CNFUpdater {
    static let registry = "https://ghcr.io/v2/homebrew/command-not-found/executables"
    /// GitHub Packages' anonymous token, as Homebrew uses it.
    static let anonymousAuth = "Bearer QQ=="

    struct Result: Sendable {
        var formulae: Int
        var source: String
        var digest: String?
        var unchanged: Bool
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `Result.source` (kept in English in the settings file) as shown in the UI.
    static func sourceTitle(_ source: String) -> String {
        source == "Homebrew cache" ? String(localized: "Homebrew cache", comment: "Where the Homebrew database was read from") : source
    }

    static func update(knownDigest: String?, destination: URL = CNFPaths.index) async throws -> Result {
        do {
            return try await download(knownDigest: knownDigest, destination: destination)
        } catch {
            let cache = CNFPaths.homebrewCache
            if let text = try? String(contentsOf: cache, encoding: .utf8), CNFIndex.looksValid(text) {
                try write(text, to: destination)
                return Result(formulae: CNFIndex.formulaCount(text), source: "Homebrew cache", digest: nil, unchanged: false)
            }
            throw Failure(message: String(localized: "Couldn't download the Homebrew database (\(error.localizedDescription)) and there's no local Homebrew copy.",
                                          comment: "The placeholder is why the download failed"))
        }
    }

    private static func download(knownDigest: String?, destination: URL) async throws -> Result {
        var manifestRequest = URLRequest(url: URL(string: "\(registry)/manifests/latest")!, timeoutInterval: 20)
        manifestRequest.setValue("application/vnd.oci.image.manifest.v1+json", forHTTPHeaderField: "Accept")
        manifestRequest.setValue(anonymousAuth, forHTTPHeaderField: "Authorization")
        let (manifestData, manifestResponse) = try await URLSession.shared.data(for: manifestRequest)
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: String(localized: "manifest request failed", comment: "Homebrew database download error; a manifest describes the download")) }
        guard let digest = layerDigest(manifestData) else { throw Failure(message: String(localized: "unexpected manifest", comment: "Homebrew database download error; a manifest describes the download")) }
        if digest == knownDigest, let text = try? String(contentsOf: destination, encoding: .utf8), CNFIndex.looksValid(text) {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return Result(formulae: CNFIndex.formulaCount(text), source: "GitHub Packages", digest: digest, unchanged: true)
        }
        var blobRequest = URLRequest(url: URL(string: "\(registry)/blobs/\(digest)")!, timeoutInterval: 60)
        blobRequest.setValue(anonymousAuth, forHTTPHeaderField: "Authorization")
        let (blob, blobResponse) = try await URLSession.shared.data(for: blobRequest)
        guard (blobResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: String(localized: "download failed", comment: "Homebrew database download error")) }
        let text = String(decoding: blob, as: UTF8.self)
        guard CNFIndex.looksValid(text) else { throw Failure(message: String(localized: "the download doesn't look like executables.txt", comment: "executables.txt is a file name")) }
        try write(text, to: destination)
        return Result(formulae: CNFIndex.formulaCount(text), source: "GitHub Packages", digest: digest, unchanged: false)
    }

    /// The digest of the `executables.txt` layer in an OCI manifest.
    static func layerDigest(_ manifest: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]] else { return nil }
        let layer = layers.first { (($0["annotations"] as? [String: Any])?["org.opencontainers.image.title"] as? String) == "executables.txt" }
            ?? layers.first
        return layer?["digest"] as? String
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Lookups and the message the shell prints (used by `mactoys cnf`).
public enum CommandNotFound {
    /// A Homebrew formula that provides a missing command.
    public struct Suggestion: Codable, Equatable, Sendable {
        public var formula: String
        /// `brew install <formula>`.
        public var installCommand: String
        /// Installed but its executables aren't on PATH (keg-only or unlinked).
        public var isInstalled: Bool
    }

    /// Formulae that provide `command`, from the cached index (empty when the index is missing).
    public static func suggestions(for command: String) -> [Suggestion] {
        guard let text = try? String(contentsOf: CNFPaths.index, encoding: .utf8) else { return [] }
        return suggestions(for: command, index: text, installed: CNFPaths.isInstalled)
    }

    static func suggestions(for command: String, index: String, installed: (String) -> Bool) -> [Suggestion] {
        CNFIndex.formulae(for: command, in: index).map {
            Suggestion(formula: $0, installCommand: "brew install \($0)", isInstalled: installed($0))
        }
    }

    /// What the shell shows: zsh's own line, then the formulae to install.
    public static func message(for command: String, suggestions: [Suggestion], brewInstalled: Bool) -> String {
        var lines = ["zsh: command not found: \(command)"]
        guard !suggestions.isEmpty else { return lines.joined(separator: "\n") }
        let installed = suggestions.filter(\.isInstalled)
        if let first = installed.first {
            lines.append("'\(command)' comes with \(first.formula), which is installed but not linked into your PATH. Try:")
            lines.append("  brew link \(first.formula)")
            lines.append("  (or for keg-only formulae: export PATH=\"$(brew --prefix \(first.formula))/bin:$PATH\")")
            return lines.joined(separator: "\n")
        }
        lines.append(suggestions.count == 1
                     ? "The command '\(command)' is provided by this Homebrew formula:"
                     : "The command '\(command)' is provided by these Homebrew formulae:")
        lines += suggestions.prefix(8).map { "  \($0.installCommand)" }
        if suggestions.count > 8 { lines.append("  … and \(suggestions.count - 8) more") }
        if !brewInstalled { lines.append("Homebrew isn't installed; get it at https://brew.sh") }
        return lines.joined(separator: "\n")
    }

    /// `mactoys cnf <command>`: prints to stderr and returns 127; `--json` prints suggestions to stdout.
    public static func run(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        guard let command = arguments.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write(Data("usage: mactoys cnf [--json] <command>\n".utf8))
            return 2
        }
        let enabled = SettingsStore.shared.load("general", default: GeneralSettings()).enabled["cmdnotfound"] ?? false
        let found = enabled ? suggestions(for: command) : []
        if json {
            let data = (try? JSONEncoder().encode(found)) ?? Data("[]".utf8)
            print(String(decoding: data, as: UTF8.self))
            return found.isEmpty ? 1 : 0
        }
        let text = message(for: command, suggestions: found, brewInstalled: CNFPaths.brew != nil)
        FileHandle.standardError.write(Data((text + "\n").utf8))
        return 127
    }
}
