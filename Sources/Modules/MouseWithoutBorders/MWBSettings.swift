import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import MacToysCore
import SystemConfiguration

/// Settings stored in `mwb.json`. The security key lives in the Keychain, not here.
public struct MWBSettings: Codable, Equatable, Sendable {
    public enum EasyMouseModifier: String, Codable, CaseIterable, Sendable {
        case none, control, shift
        public var title: String {
            switch self {
            case .none: "Just move the pointer"
            case .control: "While holding ⌃"
            case .shift: "While holding ⇧"
            }
        }
    }

    /// This Mac's identity in the group; created on first start.
    public var machineID = ""
    public var layout = MachineLayout()
    public var wrapMouse = false
    public var shareClipboard = true
    public var transferFiles = true
    public var maxFileSizeMB: Double = 100
    /// Hide this Mac's pointer while controlling another (otherwise it waits at the edge).
    public var hidePointerAtEdge = true
    public var easyMouse = true
    public var easyMouseModifier: EasyMouseModifier = .none
    public var blockCorners = false
    public var disableEasyMouseInFullScreen = true
    public var fullScreenIgnoredApps: [String] = []
    public var blockScreenSaver = true
    public var sameSubnetOnly = false
    public var showStatusMessages = true
    /// Add Macs that connect with the right key to free slots automatically.
    public var autoAddMachines = true
    public var manualHosts: [String] = []
    public var port: Int = Int(MWBProtocol.defaultPort)
    @NullCodable public var machine1Shortcut: Shortcut? = Shortcut(kVK_F1, [.control, .option, .shift])
    @NullCodable public var machine2Shortcut: Shortcut? = Shortcut(kVK_F2, [.control, .option, .shift])
    @NullCodable public var machine3Shortcut: Shortcut? = Shortcut(kVK_F3, [.control, .option, .shift])
    @NullCodable public var machine4Shortcut: Shortcut? = Shortcut(kVK_F4, [.control, .option, .shift])
    @NullCodable public var easyMouseShortcut: Shortcut? = Shortcut(kVK_ANSI_E, [.control, .option, .shift])
    @NullCodable public var lockShortcut: Shortcut? = Shortcut(kVK_ANSI_L, [.control, .option, .shift])
    @NullCodable public var reconnectShortcut: Shortcut? = Shortcut(kVK_ANSI_K, [.control, .option, .shift])

    public init() {}

    public var machineShortcuts: [Shortcut?] { [machine1Shortcut, machine2Shortcut, machine3Shortcut, machine4Shortcut] }

    public var maxFileBytes: UInt64 { UInt64(max(1, maxFileSizeMB) * 1_000_000) }
}

/// System services Mouse Without Borders needs.
@MainActor
enum MWBSystem {
    private static let log = Log.for("mwb")

    /// The computer name from Sharing settings.
    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    /// Display frames, primary first, in global top-left coordinates.
    static var displays: [CGRect] { NSScreen.screens.map(\.axFrame) }

    /// Locks the screen (like ⌃⌘Q).
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        log.notice("SACLockScreenImmediate unavailable; sleeping the display instead")
        Shell.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Tells macOS the user is active, so the screen saver and display sleep wait.
    static func declareUserActivity() {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionDeclareUserActivity("MacToys Mouse Without Borders" as CFString, kIOPMUserActiveLocal, &id)
        if status != kIOReturnSuccess { log.error("User activity assertion failed: \(status)") }
    }

    /// Whether the frontmost app (not in the ignore list) has a full-screen window.
    static func frontmostIsFullScreen(ignoring ignored: [String]) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        if ignored.matches(app: front) { return false }
        guard let pid = front?.processIdentifier else { return false }
        let screens = displays
        return WindowInfo.onScreen().contains { w in
            w.pid == pid && w.layer == 0
                && screens.contains { w.frame.width >= $0.width - 1 && w.frame.height >= $0.height - 1 && $0.insetBy(dx: -1, dy: -1).contains(w.frame) }
        }
    }
}

/// Hides this Mac's pointer while it controls another Mac. Needs the window server's
/// "SetsCursorInBackground" connection property (private, looked up at runtime).
@MainActor
enum MWBCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var prepared = false
    private(set) static var hidden = false

    static func hide() {
        guard !hidden else { return }
        if !prepared {
            prepared = true
            let handle = dlopen(nil, RTLD_NOW)
            if let m = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
               let s = dlsym(handle, "CGSSetConnectionProperty") {
                let cid = unsafeBitCast(m, to: MainConnection.self)()
                _ = unsafeBitCast(s, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            }
        }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}
