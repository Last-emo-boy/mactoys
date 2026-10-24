import AppKit
import MacToysCore

/// `mactoys://app/debug-screenshot` and `mactoys://app/debug-state`, active only when MacToys was
/// launched with `--debug`. Writes into /tmp/mactoys-debug: one PNG per display (MacToys' own
/// overlays included) and state.json with permissions, enabled modules and hotkey failures.
@MainActor
enum DebugDump {
    static let folder = URL(fileURLWithPath: "/tmp/mactoys-debug", isDirectory: true)

    static func run(screenshot: Bool) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writeState()
        guard screenshot else { return }
        for (i, screen) in NSScreen.screens.enumerated() {
            do {
                let image = try await ScreenCapture.image(of: screen, includeOwnWindows: true)
                let url = folder.appendingPathComponent("screen-\(i + 1).png")
                try image.pngData?.write(to: url)
            } catch {
                Log.for("debug").error("screenshot \(i): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writeState() {
        let registry = ModuleRegistry.shared
        let hotkeys = HotkeyCenter.shared
        let state: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "permissions": Permission.allCases.reduce(into: [String: Bool]()) {
                $0[$1.rawValue] = PermissionCenter.shared.isGranted($1)
            },
            "eventTapRunning": InputTap.shared.isRunning,
            "enabled": registry.modules.filter { registry.isEnabled($0.info.id) }.map(\.info.id).sorted(),
            "hotkeys": hotkeys.bindings.mapValues(\.description),
            "hotkeysFailed": hotkeys.failed.sorted(),
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "screens": NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))×\(Int($0.frame.height))" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("state.json"))
        }
    }
}
