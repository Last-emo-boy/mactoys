import AppKit
import IOKit.pwr_mgt
import MacToysCore

/// The system changes behind each switch. Each reports failures to the caller instead of failing quietly.
@MainActor
enum SystemSwitches {
    static let log = Log.for("switches")

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Finder

    /// Writes a Finder preference, then restarts Finder so it applies.
    static func setFinder(_ s: DefaultsSwitch, on: Bool, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        guard s.set(on: on) else {
            completion(.failure(Failure(message: String(localized: "Couldn’t change Finder’s settings."))))
            return
        }
        relaunch("Finder", completion: completion)
    }

    /// Quits a system process that relaunches by itself (Finder, Dock).
    static func relaunch(_ process: String, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        Task.detached {
            let r = Shell.run("/usr/bin/killall", [process])
            await MainActor.run {
                if r.ok { completion(.success(())) }
                else {
                    log.error("killall \(process, privacy: .public): \(r.stderr, privacy: .public)")
                    completion(.failure(Failure(message: String(localized: "Couldn’t restart \(process).", comment: "The placeholder is Finder or Dock"))))
                }
            }
        }
    }

    // MARK: Dock and menu bar

    /// Through System Events (smooth, no restart); without Automation access, writes the preference and restarts the Dock.
    static func setDockAutohide(_ on: Bool, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        systemEvents("tell application \"System Events\" to tell dock preferences to set autohide to \(on)") { ok in
            if ok { completion(.success(())); return }
            guard DefaultsSwitch.autohideDock.set(on: on) else {
                completion(.failure(Failure(message: String(localized: "Couldn’t change the Dock’s settings."))))
                return
            }
            relaunch("Dock", completion: completion)
        }
    }

    /// Menu bar hiding only applies through System Events (the system re-reads the setting there).
    static func setMenuBarAutohide(_ on: Bool, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        systemEvents("tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(on)") { ok in
            if ok { completion(.success(())) }
            else {
                completion(.failure(Failure(message: String(localized: "Allow MacToys to control System Events in System Settings › Privacy & Security › Automation."))))
                PermissionCenter.shared.openSettings(.automation)
            }
        }
    }

    private static let scriptQueue = DispatchQueue(label: "com.w33d.mactoys.switches.applescript")

    /// Runs a System Events script off the main thread.
    static func systemEvents(_ source: String, completion: @escaping @MainActor (Bool) -> Void) {
        scriptQueue.async {
            var ok = true
            do { try AppleScript.run(source) } catch {
                ok = false
                Log.for("switches").error("System Events: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
    }

    // MARK: Appearance

    static var isDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style?.lowercased() == "dark"
    }

    /// Light Switch when it's on (it keeps its schedule and extras in step), else System Events.
    static func setDark(_ dark: Bool, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        if ModuleRegistry.shared.isEnabled("lightswitch"),
           ModuleRegistry.shared.dispatch(AppCommand(module: "lightswitch", action: dark ? "dark" : "light")) {
            completion(.success(()))
            return
        }
        systemEvents("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)") { ok in
            if ok { completion(.success(())) }
            else {
                completion(.failure(Failure(message: String(localized: "Allow MacToys to control System Events in System Settings › Privacy & Security › Automation."))))
                PermissionCenter.shared.openSettings(.automation)
            }
        }
    }

    // MARK: Keep awake (Awake)

    /// Whether this app holds a "prevent idle sleep" assertion, which is what Awake does while it is on.
    static var isKeptAwake: Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let mine = dict[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.contains { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleSystemSleep }
    }

    /// Turns Awake on (if needed) and asks it to keep the Mac awake, or turns it off.
    static func setKeepAwake(_ on: Bool) -> Result<Void, Failure> {
        let registry = ModuleRegistry.shared
        if on && !registry.isEnabled("awake") { registry.setEnabled("awake", true) }
        guard registry.module("awake") != nil, registry.dispatch(AppCommand(module: "awake", action: on ? "on" : "off")) else {
            return .failure(Failure(message: String(localized: "Awake isn’t available.")))
        }
        return .success(())
    }

    // MARK: Low Power Mode

    static var isLowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// `pmset -a lowpowermode` needs root: macOS asks for an administrator password.
    static func setLowPower(_ on: Bool, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let prompt = on ? String(localized: "Quick Switches wants to turn on Low Power Mode.")
                        : String(localized: "Quick Switches wants to turn off Low Power Mode.")
        Task.detached {
            do {
                _ = try Privileged.run("/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)", prompt: prompt)
                await MainActor.run { completion(.success(())) }
            } catch let failure as AppleScript.Failure where failure.code == -128 {
                await MainActor.run { completion(.failure(Failure(message: String(localized: "Low Power Mode wasn’t changed.")))) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    log.error("pmset lowpowermode: \(message, privacy: .public)")
                    completion(.failure(Failure(message: String(localized: "Couldn’t change Low Power Mode."))))
                }
            }
        }
    }

    // MARK: Actions

    static func startScreenSaver() -> Result<Void, Failure> {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(Failure(message: String(localized: "The screen saver isn’t available.")))
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return .success(())
    }

    /// Locks like the Lock Screen command in the Apple menu; falls back to ⌃⌘Q.
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        KeySynth.tap(12, flags: [.maskControl, .maskCommand])
    }

    /// Number of items in the Trash, through Finder, off the main thread (nil without Automation access).
    static func trashCount(completion: @escaping @MainActor (Int?) -> Void) {
        scriptQueue.async {
            let count = (try? AppleScript.run("tell application \"Finder\" to count items of trash")).map { Int($0.int32Value) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(count) } }
        }
    }

    /// Empties the Trash through Finder, off the main thread (a full Trash can take a while).
    static func emptyTrash(completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        scriptQueue.async {
            var failure: String?
            do {
                try AppleScript.run("tell application \"Finder\" to empty trash")
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let failure else { completion(.success(())); return }
                    log.error("Empty Trash: \(failure, privacy: .public)")
                    PermissionCenter.shared.request(.automation)
                    completion(.failure(Failure(message: String(localized: "Allow MacToys to control Finder to empty the Trash."))))
                }
            }
        }
    }
}
