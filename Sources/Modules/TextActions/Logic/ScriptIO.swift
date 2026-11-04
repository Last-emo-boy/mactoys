import Foundation

/// The input/output contract of script actions (shell, AppleScript, Shortcuts), free of
/// processes so it can be tested.
///
/// Shell scripts run with `zsh -l -c <script>`. The selection arrives on standard input and in
/// `MACTOYS_TEXT`; `MACTOYS_APP_NAME` and `MACTOYS_APP_BUNDLE_ID` name the app it came from.
/// Standard output (one trailing newline removed) is the result; a non-zero exit status is
/// a failure whose message is the end of standard error.
public enum ScriptIO {
    /// What a finished process produced.
    public struct Outcome: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    public enum Result: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    /// What to do with a successful result.
    public enum Effect: Equatable, Sendable {
        case replace(String)
        case copy(String)
        case show(String)
        case nothing
    }

    /// Longest selection passed in the environment (the full text always goes to stdin).
    static let environmentLimit = 64 * 1024

    /// The script's environment: the inherited one plus the selection and its app.
    public static func environment(text: String, appName: String?, bundleID: String?,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["MACTOYS_TEXT"] = text.utf8.count <= environmentLimit ? text : String(text.prefix(environmentLimit / 4))
        env["MACTOYS_APP_NAME"] = appName ?? ""
        env["MACTOYS_APP_BUNDLE_ID"] = bundleID ?? ""
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    /// Arguments for `/bin/zsh`: a login shell so the user's PATH applies.
    public static func shellArguments(_ script: String) -> [String] {
        ["-l", "-c", script]
    }

    /// Arguments for `/usr/bin/shortcuts` with the selection written to `input`.
    public static func shortcutArguments(name: String, input: URL, output: URL) -> [String] {
        ["run", name, "--input-path", input.path, "--output-path", output.path, "--output-type", "public.plain-text"]
    }

    /// `{text}` replaced by the selection as an AppleScript string expression.
    public static func appleScriptSource(_ script: String, text: String) -> String {
        script.replacingOccurrences(of: URLTemplate.placeholder, with: appleScriptLiteral(text))
    }

    /// A quoted AppleScript string; line breaks become `linefeed`/`return` so the literal stays
    /// on one line.
    public static func appleScriptLiteral(_ text: String) -> String {
        var parts: [String] = []
        var current = ""
        func flush() {
            let escaped = current.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"" + escaped + "\"")
            current = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                flush()
                parts.append("linefeed")
            case "\r":
                flush()
                parts.append("return")
            case "\t":
                flush()
                parts.append("tab")
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        // Drop empty string pieces between line breaks, but keep one if everything is empty.
        let trimmed = parts.filter { $0 != "\"\"" }
        if trimmed.isEmpty { return "\"\"" }
        return trimmed.count == 1 ? trimmed[0] : "(" + trimmed.joined(separator: " & ") + ")"
    }

    /// Success with stdout minus one trailing newline, or failure with a short message.
    public static func interpret(_ outcome: Outcome) -> Result {
        if outcome.timedOut {
            return .failure(String(localized: "The action took too long and was stopped."))
        }
        guard outcome.status == 0 else {
            let lines = outcome.stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.isEmpty {
                return .failure(String(localized: "The action failed with exit status \(Int(outcome.status)).",
                                       comment: "%lld is the process exit status"))
            }
            return .failure(lines.suffix(3).joined(separator: "\n"))
        }
        return .success(trimmingOneNewline(outcome.stdout))
    }

    /// `"\r\n"` is a single Character, so dropping the last one handles every line ending.
    static func trimmingOneNewline(_ s: String) -> String {
        s.last?.isNewline == true ? String(s.dropLast()) : s
    }

    /// Replace needs an editable selection (otherwise the result is copied); empty output
    /// never replaces or copies, so a script that prints nothing can't wipe the selection.
    public static func effect(of output: String, mode: CustomAction.Output, editable: Bool) -> Effect {
        switch mode {
        case .ignore: return .nothing
        case .show: return .show(output)
        case .copy: return output.isEmpty ? .nothing : .copy(output)
        case .replace:
            if output.isEmpty { return .nothing }
            return editable ? .replace(output) : .copy(output)
        }
    }
}
