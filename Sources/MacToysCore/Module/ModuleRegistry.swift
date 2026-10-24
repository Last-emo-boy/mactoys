import AppKit
import Observation

public struct GeneralSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

    /// Module id → enabled. Missing ids use `ModuleInfo.enabledByDefault`.
    public var enabled: [String: Bool] = [:]
    public var showMenuBarIcon = true
    public var appearance: Appearance = .system
    public var hasCompletedWelcome = false
    public var showWhatsNew = true

    public init() {}
}

/// Owns every module and its enabled state.
@MainActor
@Observable
public final class ModuleRegistry {
    public static let shared = ModuleRegistry()

    public private(set) var modules: [any ToyModule] = []
    public let general = Persisted("general", default: GeneralSettings())
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private let log = Log.for("registry")

    private init() {}

    public func register(_ list: [any ToyModule]) {
        modules = list
    }

    public func module(_ id: String) -> (any ToyModule)? { modules.first { $0.info.id == id } }

    public func modules(in category: ModuleCategory) -> [any ToyModule] {
        modules.filter { $0.info.category == category }.sorted { $0.info.name < $1.info.name }
    }

    public func isEnabled(_ id: String) -> Bool {
        if let v = general.value.enabled[id] { return v }
        return module(id)?.info.enabledByDefault ?? false
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        general.value.enabled[id] = on
        apply(id)
    }

    public var enabledCount: Int { modules.filter { isEnabled($0.info.id) }.count }

    /// Starts every enabled module. Call once at launch.
    public func startEnabled() {
        for m in modules { apply(m.info.id) }
    }

    /// Re-syncs running state with settings (after the CLI or a restore changed general.json).
    public func reloadFromDisk() {
        general.reload()
        startEnabled()
    }

    public func stopAll() {
        for m in modules where running.contains(m.info.id) {
            m.stop()
            running.remove(m.info.id)
        }
    }

    private func apply(_ id: String) {
        guard let m = module(id) else { return }
        let want = isEnabled(id)
        if want && !running.contains(id) {
            log.info("start \(id, privacy: .public)")
            m.start()
            running.insert(id)
        } else if !want && running.contains(id) {
            log.info("stop \(id, privacy: .public)")
            m.stop()
            running.remove(id)
        }
    }

    /// Routes a command to its module (enabling is not implied: disabled modules still get
    /// a chance to handle "open settings"-type actions).
    @discardableResult
    public func dispatch(_ command: AppCommand) -> Bool {
        guard let m = module(command.module) else {
            log.error("No module for \(command.description, privacy: .public)")
            return false
        }
        return m.handle(command)
    }

    /// All quick actions of enabled modules.
    public var quickActions: [QuickAction] {
        modules.filter { isEnabled($0.info.id) }.flatMap(\.quickActions)
    }

    /// Asks the app to show a module's settings page.
    public var showSettings: ((String?) -> Void)?
}

/// Small typed hub for features one module offers to another (e.g. Power Display profiles
/// used by Light Switch). Providers register at `start()` and clear at `stop()`.
@MainActor
public enum Services {
    public struct DisplayProfile: Identifiable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public init(id: Int, name: String) { self.id = id; self.name = name }
    }

    /// Set by Power Display.
    public static var displayProfiles: (() -> [DisplayProfile])?
    public static var applyDisplayProfile: ((Int) -> Void)?

    /// Set by FancyZones: snaps the focused window to zone index on the current display.
    public static var snapFocusedWindowToZone: ((Int) -> Void)?
}
