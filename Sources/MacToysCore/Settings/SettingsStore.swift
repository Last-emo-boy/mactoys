import Foundation
import Observation

/// Reads and writes module settings as JSON in `Paths.settings`.
///
/// Loading overlays the stored JSON on top of the encoded defaults, so adding a field
/// to a settings struct never discards what the user already saved.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore(directory: Paths.settings)

    /// Posted (distributed) when another process — the CLI — changed settings on disk.
    public static let externalChangeNotification = Notification.Name("com.w33d.mactoys.settings-changed")

    public let directory: URL
    private let log = Log.for("settings")

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public func load<T: Codable>(_ id: String, default defaultValue: T) -> T {
        guard let stored = try? Data(contentsOf: url(for: id)) else { return defaultValue }
        do {
            let defaults = try JSONEncoder().encode(defaultValue)
            if var base = try JSONSerialization.jsonObject(with: defaults) as? [String: Any],
               let overlay = try JSONSerialization.jsonObject(with: stored) as? [String: Any] {
                Self.merge(&base, overlay)
                let merged = try JSONSerialization.data(withJSONObject: base)
                return try JSONDecoder().decode(T.self, from: merged)
            }
            return try JSONDecoder().decode(T.self, from: stored)
        } catch {
            log.error("Could not decode \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (try? JSONDecoder().decode(T.self, from: stored)) ?? defaultValue
        }
    }

    /// Saves `value`. Pass `defaults` so optionals the user cleared are written as explicit
    /// `null`s — JSONEncoder omits nil, and `load` would otherwise bring the default back.
    public func save<T: Encodable>(_ value: T, id: String, defaults: T? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            var data = try encoder.encode(value)
            if let defaults,
               var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let base = try JSONSerialization.jsonObject(with: encoder.encode(defaults)) as? [String: Any] {
                Self.fillNulls(&object, from: base)
                data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            }
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            log.error("Could not save \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies every settings file into `folder/MacToys Settings <date>`; returns the backup folder.
    @discardableResult
    public func backup(to folder: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = folder.appendingPathComponent("MacToys Settings \(stamp)", isDirectory: true)
        try FileManager.default.copyItem(at: directory, to: target)
        return target
    }

    /// Replaces current settings with the JSON files found in `folder`.
    public func restore(from folder: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for file in files {
            let dest = directory.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
        }
    }

    /// Adds `NSNull` for every key the defaults have but `object` lacks (recursively).
    private static func fillNulls(_ object: inout [String: Any], from defaults: [String: Any]) {
        for (key, defaultValue) in defaults {
            if let present = object[key] {
                if var nested = present as? [String: Any], let nestedDefault = defaultValue as? [String: Any] {
                    fillNulls(&nested, from: nestedDefault)
                    object[key] = nested
                }
            } else {
                object[key] = NSNull()
            }
        }
    }

    private static func merge(_ base: inout [String: Any], _ overlay: [String: Any]) {
        for (key, value) in overlay {
            if var nested = base[key] as? [String: Any], let overlayNested = value as? [String: Any] {
                merge(&nested, overlayNested)
                base[key] = nested
            } else {
                base[key] = value
            }
        }
    }
}

/// An observable, auto-saving settings value. Modules keep one and bind SwiftUI to `value`:
///
///     let settings = Persisted("fancyzones", default: FancyZonesSettings())
///     Toggle("Show zone number", isOn: $settings.value.showNumber)   // with @Bindable
@MainActor
@Observable
public final class Persisted<Value: Codable & Equatable> {
    /// Writing an equal value is a no-op: no observation change, no save. Without this,
    /// SwiftUI bindings that write back on every update (e.g. `MenuBarExtra(isInserted:)`)
    /// invalidate their own view graph forever.
    public var value: Value {
        get {
            access(keyPath: \.value)
            return storage
        }
        set {
            guard newValue != storage else { return }
            withMutation(keyPath: \.value) { storage = newValue }
            scheduleSave()
            for observer in observers { observer(newValue) }
        }
    }

    @ObservationIgnored private var storage: Value
    @ObservationIgnored public let id: String
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let defaultValue: Value
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var observers: [(Value) -> Void] = []

    public init(_ id: String, default defaultValue: Value, store: SettingsStore = .shared) {
        self.id = id
        self.store = store
        self.defaultValue = defaultValue
        self.storage = store.load(id, default: defaultValue)
    }

    /// Called after every change, on the main actor.
    public func onChange(_ observer: @escaping (Value) -> Void) {
        observers.append(observer)
    }

    public func update(_ mutate: (inout Value) -> Void) {
        var copy = value
        mutate(&copy)
        value = copy
    }

    /// Re-reads from disk, e.g. after a restore or a change made by the CLI.
    public func reload() {
        let fresh = store.load(id, default: defaultValue)
        if fresh != value {
            pendingSave?.cancel()
            value = fresh
            pendingSave?.cancel()
        }
    }

    public func resetToDefaults() { value = defaultValue }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(value, id: id, defaults: defaultValue)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = value
        let defaults = defaultValue
        let work = DispatchWorkItem { [store, id] in store.save(snapshot, id: id, defaults: defaults) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
