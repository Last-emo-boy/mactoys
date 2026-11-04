import Foundation
import MacToysCore

/// One app's remembered sound settings, keyed by the app's bundle identifier.
///
/// The defaults leave the app's sound untouched; only a value that differs from them makes
/// App Volume route the app through MacToys (see `TapPolicy`).
struct AppAudioSettings: Codable, Equatable, Sendable {
    /// The app's name when last seen, for the Remembered apps list while it isn't running.
    var name: String = ""
    /// 0…2, shown as 0–200 %. 1 leaves the level as the app plays it.
    var volume: Double = 1
    var muted = false
    /// -1 (left only) … 0 (centered) … 1 (right only).
    var balance: Double = 0
    /// Output device UID; nil plays where the app plays anyway (normally the system output).
    var outputUID: String?
    /// The name of `outputUID` when it was chosen, shown while that device is disconnected.
    var outputName: String?
    var eq = EQSettings()

    init(name: String = "", volume: Double = 1, muted: Bool = false, balance: Double = 0,
         outputUID: String? = nil, outputName: String? = nil, eq: EQSettings = EQSettings()) {
        self.name = name
        self.volume = volume
        self.muted = muted
        self.balance = balance
        self.outputUID = outputUID
        self.outputName = outputName
        self.eq = eq
    }

    // Field by field, so entries saved by an older version keep loading after fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppAudioSettings()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? d.muted
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? d.balance
        outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
        outputName = try c.decodeIfPresent(String.self, forKey: .outputName)
        eq = try c.decodeIfPresent(EQSettings.self, forKey: .eq) ?? d.eq
    }

    /// Whether anything differs from "as the app plays it" (name aside).
    var isAdjusted: Bool {
        volume != 1 || muted || balance != 0 || outputUID != nil || eq.isEffective
    }

    /// Whether these are the settings a new app starts with (so there is nothing to remember).
    /// A tuned curve counts as something to remember even while the equalizer is off.
    func matchesNewApp(volume newVolume: Double) -> Bool {
        volume == newVolume && !muted && balance == 0 && outputUID == nil
            && !eq.isOn && eq.preamp == 0 && eq.gains.allSatisfy { $0 == 0 }
    }
}

/// Equalizer settings of one app. `gains` follow the global band layout (`EQLayout`).
struct EQSettings: Codable, Equatable, Sendable {
    var isOn = false
    /// The built-in preset id or a custom preset's id the gains came from; nil when tuned by hand.
    var preset: String?
    /// dB per band, low to high.
    var gains: [Double] = []
    /// dB applied before the bands.
    var preamp: Double = 0

    init(isOn: Bool = false, preset: String? = nil, gains: [Double] = [], preamp: Double = 0) {
        self.isOn = isOn
        self.preset = preset
        self.gains = gains
        self.preamp = preamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        gains = try c.decodeIfPresent([Double].self, forKey: .gains) ?? []
        preamp = try c.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
    }

    /// On and changing the sound (a flat curve with no preamp changes nothing).
    var isEffective: Bool { isOn && (preamp != 0 || gains.contains { $0 != 0 }) }
}

/// An equalizer curve the user saved under a name.
struct CustomEQPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String = "custom-" + UUID().uuidString
    var name: String
    /// Band centers the gains were saved with; gains are resampled for other layouts.
    var frequencies: [Double]
    var gains: [Double]
    var preamp: Double = 0
}

enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case mixer, speaker, outputDevice

    var title: String {
        switch self {
        case .mixer: String(localized: "Mixer", comment: "App Volume menu bar icon style: sliders")
        case .speaker: String(localized: "Speaker", comment: "App Volume menu bar icon style: a speaker")
        case .outputDevice: String(localized: "Output device", comment: "App Volume menu bar icon style: the icon of the current output device")
        }
    }
}

struct AppVolumeSettings: Codable, Equatable, Sendable {
    /// Remembered apps, by bundle identifier.
    var apps: [String: AppAudioSettings] = [:]
    /// Apps always listed in the flyout, in this order.
    var pinnedApps: [String] = []
    var showMenuBarIcon = true
    var menuBarIcon: MenuBarIcon = .mixer
    var flyoutShortcut: Shortcut?
    var muteFrontmostShortcut: Shortcut?
    /// Live level meters in the flyout (listens to each playing app while the flyout is open).
    var showMeters = true
    var showInputDevice = true
    /// How long an app stays listed after it stops playing.
    var lingerSeconds = 60
    /// Highest volume the sliders offer: 1 (no boost), 1.5 or 2.
    var maxVolume: Double = 2
    /// Where apps without remembered settings start.
    var newAppVolume: Double = 1
    /// Keep settings after an app quits; otherwise they're cleared when it does (pinned apps keep theirs).
    var rememberApps = true
    /// Equalizer bands, 3…10.
    var eqBandCount = 10
    var customPresets: [CustomEQPreset] = []
    /// App names or bundle ids App Volume never touches.
    var excludedApps: [String] = []

    static let maxVolumeChoices: [Double] = [1, 1.5, 2]
    static let lingerChoices: [Int] = [10, 30, 60, 300]

    /// The settings App Volume uses for an app: remembered ones, or the defaults for new apps.
    func settings(for key: String) -> AppAudioSettings {
        apps[key] ?? AppAudioSettings(volume: newAppVolume)
    }

    func isPinned(_ key: String) -> Bool { pinnedApps.contains(key) }

    func isExcluded(_ identity: AppIdentity) -> Bool {
        let key = identity.key.lowercased()
        let name = identity.name.lowercased()
        return excludedApps.contains { entry in
            let e = entry.trimmingCharacters(in: .whitespaces).lowercased()
            return !e.isEmpty && (e == key || (!name.isEmpty && name.contains(e)))
        }
    }

    /// Changes one app's settings. The entry is dropped once it matches the defaults for new apps
    /// again, unless the app is pinned (so its name stays known while it isn't running).
    mutating func update(_ key: String, name: String, _ change: (inout AppAudioSettings) -> Void) {
        var s = settings(for: key)
        if !name.isEmpty { s.name = name }
        change(&s)
        s.volume = min(max(0, s.volume), maxVolume)
        s.balance = min(max(-1, s.balance), 1)
        apps[key] = s.matchesNewApp(volume: newAppVolume) && !isPinned(key) ? nil : s
    }

    /// Resamples every stored equalizer and custom preset to a new band count.
    mutating func setBandCount(_ count: Int) {
        let n = min(max(count, EQLayout.bandRange.lowerBound), EQLayout.bandRange.upperBound)
        guard n != eqBandCount else { return }
        let from = eqBandCount
        eqBandCount = n
        for (key, var s) in apps where !s.eq.gains.isEmpty {
            s.eq = EQCurve.resample(s.eq, from: from, to: n, customPresets: customPresets)
            apps[key] = s
        }
    }
}
