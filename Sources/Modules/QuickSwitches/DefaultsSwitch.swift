import Foundation

/// A Boolean in another app's preferences, read and written through CFPreferences (the same
/// store `defaults` uses), e.g. Finder's `CreateDesktop`.
struct DefaultsBool: Sendable, Equatable {
    /// Application id ("com.apple.finder"), or nil for the global domain (NSGlobalDomain).
    let domain: String?
    let key: String
    /// The value macOS assumes when the key isn't set.
    let defaultValue: Bool

    private var appID: CFString { (domain as CFString?) ?? kCFPreferencesAnyApplication }

    /// The current value, re-read from disk.
    func read() -> Bool {
        CFPreferencesAppSynchronize(appID)
        guard let raw = CFPreferencesCopyAppValue(key as CFString, appID) else { return defaultValue }
        return Self.bool(raw) ?? defaultValue
    }

    /// Writes the value; returns false if the preferences couldn't be saved.
    @discardableResult
    func write(_ value: Bool) -> Bool {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, appID)
        return CFPreferencesAppSynchronize(appID)
    }

    /// Removes the key so the default applies again.
    @discardableResult
    func remove() -> Bool {
        CFPreferencesSetAppValue(key as CFString, nil, appID)
        return CFPreferencesAppSynchronize(appID)
    }

    /// `defaults` writes booleans as booleans, but `-int 1`, `-string YES` and `-string true` occur too.
    static func bool(_ raw: CFPropertyList) -> Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.lowercased() {
            case "1", "yes", "true", "on": return true
            case "0", "no", "false", "off": return false
            default: return nil
            }
        }
        return nil
    }
}

/// A switch backed by one preference: on when the preference equals `onValue`.
struct DefaultsSwitch: Sendable, Equatable {
    let pref: DefaultsBool
    /// The preference value that means the switch is on (Hide Desktop Icons is on when `CreateDesktop` is false).
    let onValue: Bool

    var isOn: Bool { pref.read() == onValue }

    /// The preference value for a switch state.
    func value(forOn on: Bool) -> Bool { on ? onValue : !onValue }

    @discardableResult
    func set(on: Bool) -> Bool { pref.write(value(forOn: on)) }

    static let hideDesktopIcons = DefaultsSwitch(pref: DefaultsBool(domain: "com.apple.finder", key: "CreateDesktop", defaultValue: true),
                                                 onValue: false)
    static let showHiddenFiles = DefaultsSwitch(pref: DefaultsBool(domain: "com.apple.finder", key: "AppleShowAllFiles", defaultValue: false),
                                                onValue: true)
    static let autohideDock = DefaultsSwitch(pref: DefaultsBool(domain: "com.apple.dock", key: "autohide", defaultValue: false),
                                             onValue: true)
    static let autohideMenuBar = DefaultsSwitch(pref: DefaultsBool(domain: nil, key: "_HIHideMenuBar", defaultValue: false),
                                                onValue: true)
}
