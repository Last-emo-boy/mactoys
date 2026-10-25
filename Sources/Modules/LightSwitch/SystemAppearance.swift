import AppKit
import Foundation
import MacToysCore
import ObjectiveC

/// Reads and sets the macOS appearance. Setting goes through System Events
/// (`tell appearance preferences to set dark mode to …`), which needs Automation permission.
enum SystemAppearance {
    static let systemEventsID = "com.apple.systemevents"

    enum Failure: Error, Equatable, LocalizedError {
        /// The user declined (or revoked) Automation access to System Events.
        case notPermitted
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                String(localized: "MacToys isn't allowed to control System Events. Turn it on in System Settings › Privacy & Security › Automation › MacToys.")
            case .scriptFailed(let message):
                String(localized: "Couldn't change the appearance: \(message)",
                       comment: "Light Switch error; the placeholder is the AppleScript error message")
            }
        }
    }

    /// The current system appearance, read from the global preferences (no permission needed).
    static var current: Appearance {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style?.lowercased() == "dark" ? .dark : .light
    }

    /// True when "Appearance: Auto" is selected in System Settings; setting a mode turns it off.
    static var isAutomatic: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("AppleInterfaceStyleSwitchesAutomatically" as CFString,
                                          kCFPreferencesAnyApplication) as? Bool) ?? false
    }

    private static let queue = DispatchQueue(label: "com.w33d.mactoys.lightswitch.applescript")

    /// Switches the appearance off the main thread; `completion` runs on the main actor.
    static func set(_ appearance: Appearance, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(appearance == .dark)"
        queue.async {
            let result: Result<Void, Failure>
            do {
                try AppleScript.run(script)
                result = .success(())
            } catch let failure as AppleScript.Failure {
                // -1743 errAEEventNotPermitted, -1744 errAEEventWouldRequireUserConsent
                result = (failure.code == -1743 || failure.code == -1744)
                    ? .failure(.notPermitted) : .failure(.scriptFailed(failure.message))
            } catch {
                result = .failure(.scriptFailed(error.localizedDescription))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    enum AutomationStatus { case granted, denied, notAsked, unknown }

    /// Automation access to System Events, without prompting. `unknown` while System Events isn't running.
    static var automationStatus: AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsID)
        guard let desc = target.aeDesc else { return .unknown }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }

    /// Shows the Automation consent prompt by asking System Events for the current mode.
    static func requestAutomation(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let ok = (try? AppleScript.run("tell application \"System Events\" to get dark mode of appearance preferences")) != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
    }

    /// Sets the desktop picture of every display.
    @MainActor
    static func setWallpaper(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.for("lightswitch").error("Wallpaper missing: \(url.path, privacy: .public)")
            return
        }
        for screen in NSScreen.screens {
            do {
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                Log.for("lightswitch").error("Wallpaper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Night Shift's schedule, read through CoreBrightness' `CBBlueLightClient` (private; absent → nil).
enum NightShiftSchedule: Equatable {
    case off
    case sunsetToSunrise
    /// Night Shift turns on at `from` and off at `to`.
    case custom(from: TimeOfDay, to: TimeOfDay)

    static var isAvailable: Bool { client != nil }

    nonisolated(unsafe) private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        let object = cls.init()
        return object.responds(to: NSSelectorFromString("getBlueLightStatus:")) ? object : nil
    }()

    /// Reads the schedule. The status struct is `{BOOL active, enabled, sunSchedulePermitted; int mode;
    /// {int hour, minute} from, to; uint64 disableFlags; BOOL available}`; offsets are read explicitly.
    static func current() -> NightShiftSchedule? {
        guard let client else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let method = class_getInstanceMethod(type(of: client), selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard getter(client, selector, buffer) else { return nil }
        let mode = buffer.load(fromByteOffset: 4, as: Int32.self)
        let from = TimeOfDay(Int(buffer.load(fromByteOffset: 8, as: Int32.self)), Int(buffer.load(fromByteOffset: 12, as: Int32.self)))
        let to = TimeOfDay(Int(buffer.load(fromByteOffset: 16, as: Int32.self)), Int(buffer.load(fromByteOffset: 20, as: Int32.self)))
        switch mode {
        case 1: return .sunsetToSunrise
        case 2: return from == to ? .off : .custom(from: from, to: to)
        default: return .off
        }
    }
}
