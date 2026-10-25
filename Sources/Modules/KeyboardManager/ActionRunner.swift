import AppKit
import IOKit
import IOKit.hidsystem
import MacToysCore

/// Performs the non-key actions of remaps: typing text, launching programs and opening URLs.
@MainActor
enum ActionRunner {
    private static let log = Log.for("keyboardmanager")

    static func perform(_ action: RemapAction) {
        switch action.kind {
        case .text:
            if let text = action.text, !text.isEmpty { KeySynth.type(text) }
        case .openURL:
            if let url = action.url { open(url) }
        case .run:
            if let spec = action.run { run(spec) }
        case .send, .disable:
            break
        }
    }

    /// Opens a URL with a scheme (`https:`, `mailto:`, `x-apple.systempreferences:` …) or a path.
    static func open(_ string: String) {
        guard let url = resolveURL(string) else {
            log.error("Not a URL or path: \(string, privacy: .public)")
            HUD.show("Can’t open “\(string)”", symbol: "exclamationmark.triangle")
            return
        }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func resolveURL(_ string: String) -> URL? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let url = URL(string: s), let scheme = url.scheme, scheme.count > 1, !s.hasPrefix("/") { return url }
        return URL(fileURLWithPath: expand(s))
    }

    static func run(_ spec: RunSpec) {
        let path = expand(spec.path.trimmingCharacters(in: .whitespaces))
        let url = URL(fileURLWithPath: path)
        let args = splitArguments(spec.arguments)
        if path.hasSuffix(".app") || (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true {
            launchApp(at: url, spec: spec, arguments: args)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            // A document or folder: open it with its default app.
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(url) }
            else { HUD.show("“\(spec.path)” wasn’t found", symbol: "exclamationmark.triangle") }
            return
        }
        let directory = spec.workingDirectory.isEmpty ? nil : URL(fileURLWithPath: expand(spec.workingDirectory))
        if spec.elevation == .administrator {
            var command = ([path] + args).map(Shell.quote).joined(separator: " ")
            if let directory { command = "cd \(Shell.quote(directory.path)) && " + command }
            Task.detached {
                let prompt = String(localized: "Keyboard Manager wants to run \(url.lastPathComponent) as administrator.",
                                    comment: "Administrator password prompt; %@ is the program's file name")
                do { _ = try Privileged.run(command, prompt: prompt) }
                catch { await MainActor.run { log.error("Elevated run failed: \(error.localizedDescription, privacy: .public)") } }
            }
            return
        }
        let process = Process()
        process.executableURL = url
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log.error("Run \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            HUD.show("Couldn’t run \(url.lastPathComponent)", symbol: "exclamationmark.triangle")
        }
    }

    private static func launchApp(at url: URL, spec: RunSpec, arguments: [String]) {
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let running = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        if let app = running.first {
            switch spec.ifRunning {
            case .showWindow:
                app.unhide()
                app.activate()
                return
            case .doNothing:
                return
            case .close:
                for a in running { a.terminate() }
                return
            case .endTask:
                for a in running { a.forceTerminate() }
                return
            case .startAnother:
                break
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = spec.visibility == .normal
        config.hides = spec.visibility == .hidden
        config.createsNewApplicationInstance = !running.isEmpty && spec.ifRunning == .startAnother
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                Task { @MainActor in
                    log.error("Launch failed: \(error.localizedDescription, privacy: .public)")
                    HUD.show("Couldn’t open \(url.deletingPathExtension().lastPathComponent)", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    /// Expands `~` and `$NAME` / `${NAME}` environment variables.
    nonisolated static func expand(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var s = (path as NSString).expandingTildeInPath
        guard s.contains("$") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "$" else { out.append(c); i = s.index(after: i); continue }
            var j = s.index(after: i)
            let braced = j < s.endIndex && s[j] == "{"
            if braced { j = s.index(after: j) }
            let start = j
            while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { j = s.index(after: j) }
            let name = String(s[start..<j])
            if braced, j < s.endIndex, s[j] == "}" { j = s.index(after: j) }
            if name.isEmpty { out.append(c); i = s.index(after: i); continue }
            out += environment[name] ?? ""
            i = j
        }
        s = out
        return s
    }

    /// Splits a command line like a shell: spaces separate words, quotes group them, `\` escapes.
    nonisolated static func splitArguments(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        var escaping = false
        for c in line {
            if escaping { current.append(c); escaping = false; hasWord = true; continue }
            if c == "\\" && quote != "'" { escaping = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; hasWord = true; continue }
            if c.isWhitespace {
                if hasWord { args.append(current); current = ""; hasWord = false }
                continue
            }
            current.append(c)
            hasWord = true
        }
        if hasWord { args.append(current) }
        return args
    }
}

/// Caps Lock state through the HID system (posting a Caps Lock key event doesn't toggle it).
enum CapsLock {
    private static let log = Log.for("keyboardmanager")

    static func toggle() {
        withConnection { connect in
            var state = false
            IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
            IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
        }
    }

    private static func withConnection(_ body: (io_connect_t) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { log.error("IOHIDSystem not found"); return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard status == KERN_SUCCESS else {
            log.error("IOHIDSystem open failed: \(status)")
            return
        }
        defer { IOServiceClose(connect) }
        body(connect)
    }
}
