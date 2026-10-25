import AppKit
import SwiftUI

public enum ModuleCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case systemTools, windowing, inputOutput, fileManagement, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .systemTools: String(localized: "System Tools")
        case .windowing: String(localized: "Windowing & Layouts")
        case .inputOutput: String(localized: "Input / Output")
        case .fileManagement: String(localized: "File Management")
        case .advanced: String(localized: "Advanced")
        }
    }
}

/// Static description of a utility.
public struct ModuleInfo: Identifiable, Sendable {
    /// Stable id used for settings files and URLs: "fancyzones".
    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol name.
    public let symbol: String
    public let tint: Tint
    public let category: ModuleCategory
    /// Permissions the module needs to work; shown as a banner when missing.
    public let permissions: [Permission]
    public let enabledByDefault: Bool
    /// Extra search terms for the Settings search field.
    public let keywords: [String]

    /// `name` and `summary` are localized (string literals are extracted into the catalog).
    public init(id: String, name: String.LocalizationValue, summary: String.LocalizationValue, symbol: String,
                tint: Tint, category: ModuleCategory, permissions: [Permission] = [], enabledByDefault: Bool = true,
                keywords: [String] = []) {
        self.init(id: id, name: String(localized: name) as String, summary: String(localized: summary), symbol: symbol,
                  tint: tint, category: category, permissions: permissions, enabledByDefault: enabledByDefault,
                  keywords: keywords)
    }

    /// Already-localized or runtime text. (Generic so that string literals prefer the
    /// `LocalizationValue` initializer — a plain `String` overload would win even when disfavored.)
    @_disfavoredOverload
    public init<S: StringProtocol>(id: String, name: S, summary: S, symbol: String, tint: Tint,
                                   category: ModuleCategory, permissions: [Permission] = [],
                                   enabledByDefault: Bool = true, keywords: [String] = []) {
        self.id = id
        self.name = String(name)
        self.summary = String(summary)
        self.symbol = symbol
        self.tint = tint
        self.category = category
        self.permissions = permissions
        self.enabledByDefault = enabledByDefault
        self.keywords = keywords
    }
}

/// A button-like action exposed on the dashboard, the menu bar flyout and the Command Palette.
public struct QuickAction: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let tint: Tint
    public let shortcut: Shortcut?
    /// Set for on/off actions (shown as switches in the menu bar flyout); `perform` toggles.
    public let isOn: (@MainActor () -> Bool)?
    /// Secondary line for switches, e.g. "Indefinitely · screen stays on".
    public let detail: (@MainActor () -> String)?
    public let perform: @MainActor () -> Void

    public init(id: String, title: String.LocalizationValue, symbol: String, tint: Tint = .blue,
                shortcut: Shortcut? = nil, isOn: (@MainActor () -> Bool)? = nil,
                detail: (@MainActor () -> String)? = nil, perform: @escaping @MainActor () -> Void) {
        self.init(id: id, title: String(localized: title) as String, symbol: symbol, tint: tint, shortcut: shortcut,
                  isOn: isOn, detail: detail, perform: perform)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(id: String, title: S, symbol: String, tint: Tint = .blue,
                                   shortcut: Shortcut? = nil, isOn: (@MainActor () -> Bool)? = nil,
                                   detail: (@MainActor () -> String)? = nil,
                                   perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = String(title)
        self.symbol = symbol
        self.tint = tint
        self.shortcut = shortcut
        self.isOn = isOn
        self.detail = detail
        self.perform = perform
    }
}

/// A shortcut a module has bound, for the dashboard, conflict checks and the Shortcut Guide.
public struct ShortcutBinding: Identifiable {
    public var id: String { title }
    public let title: String
    /// Keycaps, e.g. `["⌃", "⌥", "C"]`, or descriptive keys like `["Hold", "⌘"]`.
    public let keys: [String]

    public init(_ title: String.LocalizationValue, _ shortcut: Shortcut?) {
        self.init(String(localized: title) as String, shortcut)
    }

    public init(_ title: String.LocalizationValue, keys: [String]) {
        self.init(String(localized: title) as String, keys: keys)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, _ shortcut: Shortcut?) {
        self.title = String(title)
        self.keys = shortcut?.keys ?? []
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, keys: [String]) {
        self.title = String(title)
        self.keys = keys
    }
}

/// Every utility implements this. The app owns one instance of each for its lifetime.
///
/// `start()` runs when the module becomes enabled (at launch or when toggled on) and must
/// install everything it needs (hotkeys, taps, observers); `stop()` must remove all of it.
@MainActor
public protocol ToyModule: AnyObject {
    var info: ModuleInfo { get }
    func start()
    func stop()
    /// The page shown in Settings. Wrap it in `SettingsPage(module: self) { … }`.
    func settingsView() -> AnyView
    var quickActions: [QuickAction] { get }
    var shortcutBindings: [ShortcutBinding] { get }
    /// Handles `mactoys://<module-id>/<action>?…` URLs, Finder extension calls and CLI requests.
    /// Return false for unknown actions.
    func handle(_ command: AppCommand) -> Bool
    /// Overlays and windows rendered with sample data by `MacToys --snapshot <dir> --only <module-id>`,
    /// so UI can be checked without Screen Recording permission or a live screen.
    var previewScenes: [PreviewScene] { get }
}

extension ToyModule {
    public var quickActions: [QuickAction] { [] }
    public var shortcutBindings: [ShortcutBinding] { [] }
    public func handle(_ command: AppCommand) -> Bool { false }
    public var previewScenes: [PreviewScene] { [] }
    public var isEnabled: Bool { ModuleRegistry.shared.isEnabled(info.id) }
}

/// A named view rendered offscreen for visual checks (see `ToyModule.previewScenes`).
public struct PreviewScene {
    public let name: String
    public let size: CGSize
    /// Draw a wallpaper-like gradient behind the view (for glass overlays).
    public let wallpaper: Bool
    public let view: @MainActor () -> AnyView

    public init(_ name: String, size: CGSize, wallpaper: Bool = true, view: @escaping @MainActor () -> AnyView) {
        self.name = name
        self.size = size
        self.wallpaper = wallpaper
        self.view = view
    }
}

/// A request addressed to one module: `mactoys://powerrename/open?file=/a&file=/b`.
public struct AppCommand: Sendable, CustomStringConvertible {
    public var module: String
    public var action: String
    public var parameters: [String: String]
    public var files: [URL]

    public init(module: String, action: String, parameters: [String: String] = [:], files: [URL] = []) {
        self.module = module
        self.action = action
        self.parameters = parameters
        self.files = files
    }

    public init?(url: URL) {
        guard url.scheme == Paths.urlScheme, let host = url.host() else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var params: [String: String] = [:]
        var files: [URL] = []
        for item in comps?.queryItems ?? [] {
            if item.name == "file", let v = item.value { files.append(URL(fileURLWithPath: v)) }
            else { params[item.name] = item.value ?? "" }
        }
        let action = url.pathComponents.dropFirst().first ?? "open"
        self.init(module: host, action: action, parameters: params, files: files)
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Paths.urlScheme
        c.host = module
        c.path = "/" + action
        var items = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += files.map { URLQueryItem(name: "file", value: $0.path) }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }

    public var description: String { url.absoluteString }
}
