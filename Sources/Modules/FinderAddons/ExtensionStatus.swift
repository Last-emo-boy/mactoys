import AppKit
import MacToysCore

/// What macOS knows about one of the MacToys app extensions (`pluginkit -m -v -i <id>`).
struct ExtensionStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unknown
        case notRegistered
        case enabled
        case disabled
    }

    var identifier: String
    var state: State = .unknown
    var version: String?
    /// Registered copies (more than one means several builds compete).
    var paths: [String] = []

    var title: String {
        switch state {
        case .unknown: String(localized: "Checking…", comment: "Quick Look extension status")
        case .notRegistered: String(localized: "Not registered", comment: "Quick Look extension status: macOS doesn't know the extension")
        case .enabled: String(localized: "Enabled", comment: "Quick Look extension status")
        case .disabled: String(localized: "Turned off in System Settings", comment: "Quick Look extension status")
        }
    }

    /// Parses `pluginkit -m -v` output: `+    com.x.y(1.0.0)\t<uuid>\t<date>\t/path/X.appex`.
    /// The first column is `+` (on), `-` (off), `=` / `!` / space (on by default).
    static func parse(_ output: String, identifier: String) -> ExtensionStatus {
        var status = ExtensionStatus(identifier: identifier, state: .notRegistered)
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard let idRange = line.range(of: identifier + "(") else { continue }
            let flag = line[line.startIndex..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let afterID = line[idRange.upperBound...]
            if status.version == nil, let close = afterID.firstIndex(of: ")") { status.version = String(afterID[..<close]) }
            if let path = line.split(separator: "\t").last.map(String.init), path.hasPrefix("/") { status.paths.append(path) }
            let on = flag != "-"
            if status.state == .notRegistered || on { status.state = on ? .enabled : .disabled }
        }
        return status
    }

    static func query(_ identifier: String) async -> ExtensionStatus {
        let result = await Shell.runAsync("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier])
        guard result.ok || !result.stdout.isEmpty else { return ExtensionStatus(identifier: identifier, state: .unknown) }
        return parse(result.stdout, identifier: identifier)
    }
}

/// Talking to Quick Look and PlugInKit.
enum QuickLookControl {
    static let previewID = "com.w33d.mactoys.quicklook"
    static let thumbnailID = "com.w33d.mactoys.thumbnails"
    private static let log = Log.for("finderaddons")

    /// `qlmanage -r` (reload generators) and `qlmanage -r cache` (drop cached thumbnails).
    static func resetCache() async {
        let a = await Shell.runAsync("/usr/bin/qlmanage", ["-r"])
        let b = await Shell.runAsync("/usr/bin/qlmanage", ["-r", "cache"])
        if !a.ok || !b.ok { log.error("qlmanage failed: \(a.stderr + b.stderr, privacy: .public)") }
    }

    /// Registers the extensions bundled in this copy of MacToys and turns them on.
    static func register() async {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
            log.error("No PlugIns folder in \(Bundle.main.bundlePath, privacy: .public)")
            return
        }
        for appex in items where appex.pathExtension == "appex" {
            let r = await Shell.runAsync("/usr/bin/pluginkit", ["-a", appex.path])
            if !r.ok { log.error("pluginkit -a \(appex.lastPathComponent, privacy: .public): \(r.stderr, privacy: .public)") }
        }
        await enable()
    }

    static func enable() async {
        for id in [previewID, thumbnailID] {
            let r = await Shell.runAsync("/usr/bin/pluginkit", ["-e", "use", "-i", id])
            if !r.ok { log.error("pluginkit -e use \(id, privacy: .public): \(r.stderr, privacy: .public)") }
        }
    }

    /// System Settings › General › Login Items & Extensions › Quick Look.
    @MainActor
    static func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
