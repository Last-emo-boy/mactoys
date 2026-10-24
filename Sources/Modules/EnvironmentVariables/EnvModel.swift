import Foundation
import MacToysCore

/// One `NAME=value` pair.
struct EnvVariable: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var value: String

    /// Colon-separated lists edited as a list (PATH, MANPATH, PYTHONPATH…).
    var isPathLike: Bool { EnvNames.isPathLike(name) }
}

/// A named set of variables. At most one profile is applied at a time; its variables take
/// precedence over User variables of the same name (Profile > User > System, as in PowerToys).
struct EnvProfile: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var variables: [EnvVariable] = []
}

struct EnvSettings: Codable, Equatable {
    var profiles: [EnvProfile] = []
    var userVariables: [EnvVariable] = []
    var appliedProfile: UUID?
    /// Also set the variables for apps started from the Dock and Finder (`launchctl setenv`).
    var applyToLaunchd = true
    /// Re-apply PATH-like variables from `~/.zprofile`, after macOS's path_helper reorders PATH in login shells.
    var keepPathOrderInLoginShells = true

    // Bookkeeping for what MacToys changed.
    /// launchd variables MacToys set, with their value before it first did (nil: unset).
    var launchdOriginals: [String: String?] = [:]
    /// Files already backed up before their first modification.
    var backedUpFiles: [String] = []
    /// What was last written, to tell whether there are unapplied edits.
    var lastApplied: [EffectiveVariable]?

    var applied: EnvProfile? { profiles.first { $0.id == appliedProfile } }
}

/// Where an effective variable comes from.
enum EnvSource: String, Codable, Equatable {
    case user, profile
}

struct EffectiveVariable: Codable, Equatable, Hashable {
    var name: String
    var value: String
    var source: EnvSource
}

enum EnvNames {
    static let pathLikeNames: Set<String> = [
        "PATH", "MANPATH", "INFOPATH", "FPATH", "CDPATH", "PYTHONPATH", "PERL5LIB", "CLASSPATH", "GOPATH",
        "NODE_PATH", "PKG_CONFIG_PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
        "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS",
        "RUBYLIB", "GEM_PATH", "JULIA_LOAD_PATH", "R_LIBS", "ERL_LIBS", "LUA_PATH", "LUA_CPATH",
    ]

    /// Variables the shell or the system manage; MacToys refuses to set them.
    static let reserved: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "SHLVL", "_", "TMPDIR",
                                        "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK", "TERM", "ZDOTDIR"]

    static func isPathLike(_ name: String) -> Bool {
        pathLikeNames.contains(name) || name.hasSuffix("_PATH") || name.hasSuffix("PATHS")
    }

    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// Why a name can't be used, or nil when it's fine.
    static func problem(_ name: String) -> String? {
        if name.isEmpty { return "Name is empty" }
        if !isValid(name) { return "Use letters, digits and underscores, not starting with a digit" }
        if reserved.contains(name) { return "\(name) is managed by the system" }
        return nil
    }
}

/// Composes the variables to export, in the order they're evaluated.
enum EnvComposer {
    /// User variables first (in order) unless the applied profile defines the same name, then the profile's.
    static func effective(user: [EnvVariable], profile: EnvProfile?) -> [EffectiveVariable] {
        let profileVars = (profile?.variables ?? []).filter { !$0.name.isEmpty }
        let overridden = Set(profileVars.map(\.name))
        var out: [EffectiveVariable] = []
        var seen = Set<String>()
        for v in user where !v.name.isEmpty && !overridden.contains(v.name) && seen.insert(v.name).inserted {
            out.append(EffectiveVariable(name: v.name, value: v.value, source: .user))
        }
        var seenProfile = Set<String>()
        for v in profileVars where seenProfile.insert(v.name).inserted {
            out.append(EffectiveVariable(name: v.name, value: v.value, source: .profile))
        }
        return out
    }

    static func effective(_ s: EnvSettings) -> [EffectiveVariable] {
        effective(user: s.userVariables, profile: s.applied)
    }

    /// Problems that block applying.
    static func problems(_ vars: [EffectiveVariable]) -> [String] {
        vars.compactMap { v in EnvNames.problem(v.name).map { "\(v.name.isEmpty ? "(unnamed)" : v.name): \($0)" } }
    }
}

/// zsh quoting for values: double quotes, with `$NAME` / `${NAME}` references kept live,
/// everything else (`$(…)`, backticks, quotes, backslashes) literal; a leading `~/` (or one after
/// `:` in PATH-like values) becomes `$HOME/`.
enum ZshQuote {
    static func quote(_ value: String, pathLike: Bool) -> String {
        var out = "\""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let atSegmentStart = i == 0 || (pathLike && chars[i - 1] == ":")
            if c == "~" && atSegmentStart && (i + 1 == chars.count || chars[i + 1] == "/" || (pathLike && chars[i + 1] == ":")) {
                out += "$HOME"
            } else if c == "$" {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, n == "{" || n == "_" || (n.isASCII && n.isLetter) { out.append("$") } else { out += "\\$" }
            } else if c == "\\" || c == "\"" || c == "`" {
                out += "\\\(c)"
            } else {
                out.append(c)
            }
            i += 1
        }
        return out + "\""
    }

    /// POSIX single quotes for /bin/sh command lines.
    static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// PATH-style lists.
enum PathList {
    static func split(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: ":")
    }

    static func join(_ entries: [String]) -> String {
        entries.joined(separator: ":")
    }

    /// A comparison key: `~` and `$HOME` expanded, repeated and trailing slashes dropped, case folded
    /// (APFS volumes are case-insensitive by default).
    static func key(_ entry: String, home: String) -> String {
        var s = entry.trimmingCharacters(in: .whitespaces)
        if s == "~" || s.hasPrefix("~/") { s = home + s.dropFirst() }
        for token in ["${HOME}", "$HOME"] where s.hasPrefix(token) { s = home + s.dropFirst(token.count) }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// Indices of entries that repeat an earlier one.
    static func duplicateIndices(_ entries: [String], home: String = NSHomeDirectory()) -> Set<Int> {
        var seen = Set<String>()
        var dupes = Set<Int>()
        for (i, e) in entries.enumerated() {
            let k = key(e, home: home)
            if k.isEmpty { continue }
            if !seen.insert(k).inserted { dupes.insert(i) }
        }
        return dupes
    }

    /// Keeps the first occurrence of each entry with its original spelling; order is unchanged.
    static func removeDuplicates(_ entries: [String], home: String = NSHomeDirectory()) -> [String] {
        let dupes = duplicateIndices(entries, home: home)
        return entries.enumerated().filter { !dupes.contains($0.offset) && !$0.element.isEmpty }.map(\.element)
    }
}

/// What the files MacToys writes contain.
enum EnvFiles {
    static let block = ManagedBlock(name: "Environment Variables") { $0.contains("MacToys/envvars/env.zsh") || $0.hasPrefix("# Managed by MacToys") }
    static let agentLabel = "com.w33d.mactoys.envvars"

    /// The `source` line for `~/.zshenv` (and the login-shell re-apply for `~/.zprofile`).
    static func sourceLines(envFile: String, loginPhase: Bool) -> [String] {
        let path = ZshQuote.quote(envFile, pathLike: false)
        return [
            "# Managed by MacToys › Environment Variables. Edit variables there, not here.",
            loginPhase
                ? "[[ -r \(path) ]] && MACTOYS_ENV_PHASE=login source \(path)"
                : "[[ -r \(path) ]] && source \(path)",
        ]
    }

    /// `env.zsh`: one export per variable, in evaluation order; PATH-like lists are de-duplicated
    /// after export because nested shells source the file again.
    static func zshFile(_ vars: [EffectiveVariable], profileName: String?) -> String {
        var lines = [
            "# Generated by MacToys Environment Variables. Changes here are overwritten on Apply.",
            "# Profile: \(profileName ?? "none")",
        ]
        for v in vars {
            let pathLike = EnvNames.isPathLike(v.name)
            lines.append("export \(v.name)=\(ZshQuote.quote(v.value, pathLike: pathLike))")
            if pathLike {
                lines.append("export \(v.name)=\"${(j.:.)${(@u)${(s.:.)\(v.name)}}}\"")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Expands `$NAME`, `${NAME}` and leading `~` the way zsh would, for `launchctl setenv` (launchd doesn't expand).
    static func expand(_ value: String, environment: [String: String], home: String, pathLike: Bool) -> String {
        var out = ""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let atSegmentStart = i == 0 || (pathLike && chars[i - 1] == ":")
            if c == "~" && atSegmentStart && (i + 1 == chars.count || chars[i + 1] == "/" || (pathLike && chars[i + 1] == ":")) {
                out += home
                i += 1
                continue
            }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{", let close = chars[(i + 2)...].firstIndex(of: "}") {
                    let name = String(chars[(i + 2)..<close])
                    if EnvNames.isValid(name) {
                        out += name == "HOME" ? home : (environment[name] ?? "")
                        i = close + 1
                        continue
                    }
                } else if chars[i + 1] == "_" || (chars[i + 1].isASCII && chars[i + 1].isLetter) {
                    var j = i + 1
                    while j < chars.count, chars[j] == "_" || (chars[j].isASCII && (chars[j].isLetter || chars[j].isNumber)) { j += 1 }
                    let name = String(chars[(i + 1)..<j])
                    out += name == "HOME" ? home : (environment[name] ?? "")
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Values for launchd: each variable expanded against the base environment plus the ones before it.
    static func launchdValues(_ vars: [EffectiveVariable], base: [String: String], home: String) -> [(String, String)] {
        var env = base
        var out: [(String, String)] = []
        for v in vars {
            let pathLike = EnvNames.isPathLike(v.name)
            var value = expand(v.value, environment: env, home: home, pathLike: pathLike)
            if pathLike { value = PathList.join(PathList.removeDuplicates(PathList.split(value), home: home)) }
            env[v.name] = value
            out.append((v.name, value))
        }
        return out
    }

    /// The `/bin/sh -c` script the login LaunchAgent runs.
    static func launchdScript(set: [(String, String)], unset: [String]) -> String {
        var cmds = set.map { "/bin/launchctl setenv \($0.0) \(ZshQuote.single($0.1))" }
        cmds += unset.map { "/bin/launchctl unsetenv \($0)" }
        return cmds.joined(separator: "; ")
    }

    static func launchAgentPlist(script: String) -> [String: Any] {
        ["Label": agentLabel, "ProgramArguments": ["/bin/sh", "-c", script], "RunAtLoad": true,
         "ProcessType": "Background"]
    }

    /// Parses `env -0` output.
    static func parseEnv0(_ text: String) -> [(String, String)] {
        text.split(separator: "\0", omittingEmptySubsequences: true).compactMap { (entry: Substring) -> (String, String)? in
            guard let eq = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
        }
    }

    /// Parses the `environment = { NAME => value }` block of `launchctl print gui/<uid>`.
    static func parseLaunchctlPrint(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var inside = false
        var depth = 0
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line == "environment = {" { inside = true; depth = 1 }
                continue
            }
            if line.hasSuffix("{") { depth += 1; continue }
            if line == "}" { depth -= 1; if depth == 0 { break }; continue }
            guard depth == 1, let r = line.range(of: " => ") else { continue }
            out[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
        }
        return out
    }
}
