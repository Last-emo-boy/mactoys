import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Hides and shows the system pointer from the background.
///
/// `CGDisplayHideCursor` only works for the frontmost app unless the window server connection
/// has the private "SetsCursorInBackground" property, set through `CGSSetConnectionProperty`
/// (looked up with dlsym so a missing symbol degrades to foreground-only hiding).
@MainActor
enum CursorVisibility {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var prepared = false
    private static var hidden = false
    private static let log = Log.for("mouseutils")

    static var isHidden: Bool { hidden }

    static func hide() {
        guard !hidden else { return }
        prepare()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    private static func prepare() {
        guard !prepared else { return }
        prepared = true
        let handle = dlopen(nil, RTLD_NOW)
        guard let mainSym = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else {
            log.notice("CGS connection functions unavailable; the pointer hides only while MacToys is frontmost")
            return
        }
        let main = unsafeBitCast(mainSym, to: MainConnection.self)
        let set = unsafeBitCast(setSym, to: SetProperty.self)
        let cid = main()
        let status = set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if status != 0 { log.error("SetsCursorInBackground failed: \(status)") }
    }
}

/// Closes an open context menu (macOS opens them on mouse-down, so a locked right button
/// would otherwise leave one tracking the pointer, and its release would pick an item).
@MainActor
enum ContextMenuDismisser {
    static func dismissSoon(after delay: TimeInterval = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if menuIsOpen() { KeySynth.tap(kVK_Escape) }
            }
        }
    }

    static func menuIsOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            (info[kCGWindowLayer as String] as? Int) == level && (info[kCGWindowOwnerPID as String] as? pid_t) != own
        }
    }
}

enum FrontmostApp {
    /// Whether the frontmost app has a window covering a whole display (full-screen games and videos).
    @MainActor
    static func isFullScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let screens = NSScreen.screens.map(\.axFrame)
        return WindowInfo.onScreen().contains { w in
            w.pid == pid && w.layer == 0 && screens.contains { $0.insetBy(dx: -1, dy: -1).contains(w.frame) && w.frame.width >= $0.width - 1 && w.frame.height >= $0.height - 1 }
        }
    }
}

extension CGEventType {
    var isMouseDown: Bool { self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown }
    var isMouseUp: Bool { self == .leftMouseUp || self == .rightMouseUp || self == .otherMouseUp }
    var isMouseMoveOrDrag: Bool {
        self == .mouseMoved || self == .leftMouseDragged || self == .rightMouseDragged || self == .otherMouseDragged
    }
}

enum MouseEvents {
    /// The button of a mouse event: 0 left, 1 right, 2 middle, higher for extra buttons.
    static func button(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.mouseEventButtonNumber) }

    static func type(down: Bool, button: ButtonLockMachine.Button) -> CGEventType {
        switch button {
        case .left: down ? .leftMouseDown : .leftMouseUp
        case .right: down ? .rightMouseDown : .rightMouseUp
        case .middle: down ? .otherMouseDown : .otherMouseUp
        }
    }

    static func dragType(_ button: ButtonLockMachine.Button) -> CGEventType {
        switch button {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
    }

    static func cgButton(_ button: ButtonLockMachine.Button) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }
}
