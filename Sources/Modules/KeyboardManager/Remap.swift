import Foundation
import MacToysCore

/// What a remap does when its trigger fires.
public struct RemapAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Send a key or a shortcut (`combo`).
        case send
        /// Type `text`.
        case text
        /// Launch an app or run a program (`run`).
        case run
        /// Open a URL, URI or file (`url`).
        case openURL
        /// Swallow the key.
        case disable
    }

    public var kind: Kind
    public var combo: KeyCombo?
    public var text: String?
    public var run: RunSpec?
    public var url: String?

    public init(kind: Kind, combo: KeyCombo? = nil, text: String? = nil, run: RunSpec? = nil, url: String? = nil) {
        self.kind = kind
        self.combo = combo
        self.text = text
        self.run = run
        self.url = url
    }

    public static func send(_ combo: KeyCombo) -> RemapAction { RemapAction(kind: .send, combo: combo) }
    public static func send(_ key: Key) -> RemapAction { RemapAction(kind: .send, combo: KeyCombo([], key)) }
    public static func type(_ text: String) -> RemapAction { RemapAction(kind: .text, text: text) }
    public static func open(_ url: String) -> RemapAction { RemapAction(kind: .openURL, url: url) }
    public static func launch(_ spec: RunSpec) -> RemapAction { RemapAction(kind: .run, run: spec) }
    public static let disable = RemapAction(kind: .disable)

    /// True when the action produces a single key with no modifiers.
    public var isPlainKey: Bool { kind == .send && combo?.modifiers.isEmpty == true }

    /// Whether the action has everything it needs to run.
    public var isComplete: Bool {
        switch kind {
        case .send: combo != nil
        case .text: !(text ?? "").isEmpty
        case .run: !(run?.path ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .openURL: !(url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .disable: true
        }
    }
}

/// Options for launching a program from a shortcut.
public struct RunSpec: Codable, Hashable, Sendable {
    public enum IfRunning: String, Codable, Sendable, CaseIterable {
        case showWindow, startAnother, doNothing, close, endTask
        public var title: String {
            switch self {
            case .showWindow: String(localized: "Show window", comment: "If the app is already running: bring its window forward")
            case .startAnother: String(localized: "Start another instance", comment: "If the app is already running")
            case .doNothing: String(localized: "Do nothing", comment: "If the app is already running")
            case .close: String(localized: "Quit", comment: "If the app is already running: quit it")
            case .endTask: String(localized: "Force quit", comment: "If the app is already running: force quit it")
            }
        }
    }

    public enum Visibility: String, Codable, Sendable, CaseIterable {
        case normal, hidden
        public var title: String {
            self == .normal ? String(localized: "Normal", comment: "Program visibility (shown normally) and Run as (the current user, no administrator rights)")
                : String(localized: "Hidden (in the background)", comment: "Program visibility")
        }
    }

    public enum Elevation: String, Codable, Sendable, CaseIterable {
        case normal, administrator
        public var title: String {
            self == .normal ? String(localized: "Normal", comment: "Program visibility (shown normally) and Run as (the current user, no administrator rights)")
                : String(localized: "Administrator (asks for your password)", comment: "Run as")
        }
    }

    /// An `.app` bundle or an executable; `~` and `$VARIABLES` are expanded.
    public var path: String
    /// Command-line arguments, split like a shell does (quotes group words).
    public var arguments: String
    public var workingDirectory: String
    public var ifRunning: IfRunning
    public var visibility: Visibility
    /// Programs (not apps) can run as root after the administrator prompt.
    public var elevation: Elevation

    public init(path: String, arguments: String = "", workingDirectory: String = "", ifRunning: IfRunning = .showWindow,
                visibility: Visibility = .normal, elevation: Elevation = .normal) {
        self.path = path
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.ifRunning = ifRunning
        self.visibility = visibility
        self.elevation = elevation
    }

    private enum CodingKeys: String, CodingKey { case path, arguments, workingDirectory, ifRunning, visibility, elevation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        ifRunning = try c.decodeIfPresent(IfRunning.self, forKey: .ifRunning) ?? .showWindow
        visibility = try c.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .normal
        elevation = try c.decodeIfPresent(Elevation.self, forKey: .elevation) ?? .normal
    }
}

/// One row of the Keyboard Manager editor.
public struct Remap: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A single key (including modifier keys and media keys).
        case key
        /// Modifiers plus a key, optionally followed by a second key (a chord).
        case shortcut
    }

    public var id: UUID
    public var isEnabled: Bool
    public var kind: Kind
    /// For key remaps only `trigger.key` is used.
    public var trigger: KeyCombo
    /// Second key of a chord (`⌃⇧V`, then `U`). Shortcut remaps only.
    public var chord: Key?
    public var action: RemapAction
    /// Key remaps: the action runs only when the key is tapped on its own. Held or combined
    /// with other keys it acts as `holdKey`, or as itself when `holdKey` is nil.
    public var tapAlone: Bool
    /// Modifier key the trigger acts as while held (tap-alone remaps).
    public var holdKey: Key?
    /// Shortcut remaps: match only when no other modifiers are held.
    public var exactMatch: Bool
    /// Bundle identifiers of the apps the remap is limited to; empty means every app.
    public var apps: [String]

    public init(id: UUID = UUID(), isEnabled: Bool = true, kind: Kind, trigger: KeyCombo, chord: Key? = nil,
                action: RemapAction, tapAlone: Bool = false, holdKey: Key? = nil, exactMatch: Bool = false,
                apps: [String] = []) {
        self.id = id
        self.isEnabled = isEnabled
        self.kind = kind
        self.trigger = trigger
        self.chord = chord
        self.action = action
        self.tapAlone = tapAlone
        self.holdKey = holdKey
        self.exactMatch = exactMatch
        self.apps = apps
    }

    /// A key → anything remap.
    public static func key(_ key: Key, to action: RemapAction, apps: [String] = []) -> Remap {
        Remap(kind: .key, trigger: KeyCombo([], key), action: action, apps: apps)
    }

    /// A shortcut → anything remap.
    public static func shortcut(_ combo: KeyCombo, to action: RemapAction, apps: [String] = [],
                                exactMatch: Bool = false) -> Remap {
        Remap(kind: .shortcut, trigger: combo, action: action, exactMatch: exactMatch, apps: apps)
    }

    public var isGlobal: Bool { apps.isEmpty }

    /// Whether the remap applies in the app with this bundle identifier.
    public func applies(to bundleID: String?) -> Bool {
        if apps.isEmpty { return true }
        guard let bundleID else { return false }
        return apps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// The trigger as keycaps; chords as `⌃ ⇧ V , U`.
    public var triggerKeycaps: [String] {
        switch kind {
        case .key: trigger.key.keycaps
        case .shortcut: trigger.keycaps + (chord.map { [","] + $0.keycaps } ?? [])
        }
    }

    /// Why the remap can't be saved, or nil.
    public var validationError: String? {
        switch kind {
        case .key:
            if tapAlone {
                if let holdKey, !holdKey.isModifier { return String(localized: "“When held” must be a modifier key.") }
                if holdKey == nil && !trigger.key.isModifier && trigger.key != .capsLock {
                    return String(localized: "Tap-alone keys that aren’t modifiers need a modifier to act as when held.")
                }
                if action.kind == .disable { return String(localized: "Choose what tapping the key does.") }
            }
        case .shortcut:
            if trigger.modifiers.isEmpty { return String(localized: "Shortcuts must include at least one modifier (⌃ ⌥ ⇧ ⌘ fn).") }
            if trigger.key.isModifier || trigger.key == .capsLock { return String(localized: "Shortcuts must end with a non-modifier key.") }
            if let chord, chord.isModifier { return String(localized: "The chord’s second key can’t be a modifier.") }
        }
        if !action.isComplete { return String(localized: "Finish choosing what the remap does.") }
        if case .send = action.kind, let combo = action.combo, kind == .key, !tapAlone,
           combo == KeyCombo([], trigger.key) {
            return String(localized: "A key can’t be remapped to itself.")
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, kind, trigger, chord, action, tapAlone, holdKey, exactMatch, apps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        kind = try c.decode(Kind.self, forKey: .kind)
        trigger = try c.decode(KeyCombo.self, forKey: .trigger)
        chord = try c.decodeIfPresent(Key.self, forKey: .chord)
        action = try c.decode(RemapAction.self, forKey: .action)
        tapAlone = try c.decodeIfPresent(Bool.self, forKey: .tapAlone) ?? false
        holdKey = try c.decodeIfPresent(Key.self, forKey: .holdKey)
        exactMatch = try c.decodeIfPresent(Bool.self, forKey: .exactMatch) ?? false
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
    }
}

/// A named set of remaps. One profile is active at a time.
public struct RemapProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var remaps: [Remap]

    public init(id: UUID = UUID(), name: String, remaps: [Remap] = []) {
        self.id = id
        self.name = name
        self.remaps = remaps
    }

    /// Name of the first profile.
    public static var defaultName: String { String(localized: "Default", comment: "Name of the first keyboard profile") }
    /// Name of a profile imported from a file that doesn't name it.
    public static var importedName: String { String(localized: "Imported", comment: "Name of a keyboard profile imported from a file that has none") }

    private enum CodingKeys: String, CodingKey { case id, name, remaps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? RemapProfile.importedName
        remaps = try c.decodeIfPresent([Remap].self, forKey: .remaps) ?? []
    }
}

/// The JSON file written by Export and read by Import.
public struct RemapProfileFile: Codable, Sendable {
    public static let currentVersion = 1

    public var format = "mactoys.keyboardmanager"
    public var version = RemapProfileFile.currentVersion
    public var profile: RemapProfile

    public init(profile: RemapProfile) { self.profile = profile }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public enum ImportError: LocalizedError {
        case notAProfile
        case newerVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .notAProfile: String(localized: "The file isn’t a Keyboard Manager profile.")
            case .newerVersion(let v):
                String(localized: "The profile was written by a newer version of MacToys (format \(v)).", comment: "%lld is the file format version")
            }
        }
    }

    /// Reads an exported profile. Accepts a bare profile object or a bare remap array too.
    public static func decode(_ data: Data) throws -> RemapProfile {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(RemapProfileFile.self, from: data) {
            guard file.format == "mactoys.keyboardmanager" else { throw ImportError.notAProfile }
            guard file.version <= currentVersion else { throw ImportError.newerVersion(file.version) }
            return file.profile
        }
        if let remaps = try? decoder.decode([Remap].self, from: data) {
            return RemapProfile(name: RemapProfile.importedName, remaps: remaps)
        }
        do {
            return try decoder.decode(RemapProfile.self, from: data)
        } catch {
            throw ImportError.notAProfile
        }
    }
}

/// Settings stored in `keyboardmanager.json`.
public struct KeyboardManagerSettings: Codable, Equatable, Sendable {
    public var profiles: [RemapProfile] = [RemapProfile(name: RemapProfile.defaultName)]
    /// Missing or unknown: the first profile.
    public var activeProfileID: UUID?
    /// Remapping is temporarily off (the module stays enabled).
    public var paused = false
    /// Apply global key → key remaps with `hidutil` (system key mapping) instead of the event tap.
    public var useSystemKeyMapping = true
    /// Longest press, in seconds, that still counts as a tap for tap-alone remaps.
    public var tapTimeout: Double = 0.4
    /// How long a chord waits for its second key, in seconds.
    public var chordTimeout: Double = 1.0
    @NullCodable public var openEditorShortcut: Shortcut? = nil
    @NullCodable public var toggleShortcut: Shortcut? = nil

    public init() {}

    public var activeProfileIndex: Int {
        profiles.firstIndex { $0.id == activeProfileID } ?? 0
    }

    /// The remaps of the active profile.
    public var remaps: [Remap] {
        get { profiles.isEmpty ? [] : profiles[activeProfileIndex].remaps }
        set {
            if profiles.isEmpty { profiles = [RemapProfile(name: RemapProfile.defaultName)] }
            profiles[activeProfileIndex].remaps = newValue
        }
    }
}
