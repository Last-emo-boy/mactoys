import AppKit
import CoreGraphics
import Foundation
import MacToysCore

/// Hands off to the real macOS lock screen.
///
/// macOS has no public API that locks the session. `SACLockScreenImmediate` in the private
/// login.framework is what the ⌃⌘Q shortcut and the Lock Screen menu item use; it is present on
/// macOS 26 (resolved with dlsym, so a missing symbol degrades instead of crashing). When it can't
/// be loaded, `pmset displaysleepnow` turns the displays off, which locks the session only when
/// "Require password after screen saver begins or display is turned off" is set to Immediately.
public enum SystemLock {
    private typealias LockFn = @convention(c) () -> Int32
    nonisolated(unsafe) private static var cached: LockFn?
    private static let lock = NSLock()

    /// Loads the lock function ahead of time, so locking later is a single call (the guard does
    /// this at launch so it can react in milliseconds).
    @discardableResult
    public static func prepare() -> Bool { lockFunction() != nil }

    private static func lockFunction() -> LockFn? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let paths = ["/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                     "/System/Library/PrivateFrameworks/login.framework/login"]
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, "SACLockScreenImmediate") else { continue }
            let fn = unsafeBitCast(sym, to: LockFn.self)
            cached = fn
            return fn
        }
        return nil
    }

    /// Locks the session now. Returns how it was done.
    @discardableResult
    public static func lockNow() -> String {
        if let fn = lockFunction() {
            let status = fn()
            if status == 0 { return "login.framework" }
            Log.for("privacyscreen").error("SACLockScreenImmediate returned \(status)")
        }
        let result = Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        return result.ok ? "pmset" : "failed"
    }

    /// Whether the login window covers the session right now (from the window server's session
    /// dictionary, which other processes can't fake, unlike the distributed notifications).
    public static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = info["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
}
