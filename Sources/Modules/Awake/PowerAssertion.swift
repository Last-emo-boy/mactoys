import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import MacToysCore

/// One IOKit power assertion that can be held and released repeatedly.
final class PowerAssertion {
    private let type: String
    private let reason: String
    private var id: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private let log = Log.for("awake")

    var isHeld: Bool { id != IOPMAssertionID(kIOPMNullAssertionID) }

    init(type: String, reason: String) {
        self.type = type
        self.reason = reason
    }

    deinit { release() }

    func hold() {
        guard !isHeld else { return }
        var newID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &newID)
        if result == kIOReturnSuccess {
            id = newID
        } else {
            log.error("IOPMAssertionCreateWithName(\(self.type, privacy: .public)) failed: \(result)")
        }
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(kIOPMNullAssertionID)
    }

    static func system() -> PowerAssertion {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                       reason: "MacToys Awake is keeping this Mac awake")
    }

    static func display() -> PowerAssertion {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                       reason: "MacToys Awake is keeping the screen on")
    }
}

enum ScreenLock {
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// Whether the login window is covering the session right now.
    static var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? ((info["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}
