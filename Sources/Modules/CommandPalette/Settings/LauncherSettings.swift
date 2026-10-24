import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Which screen a launcher opens on.
enum LauncherScreen: String, Codable, CaseIterable, Sendable, Identifiable {
    case mouse, primary, focusedWindow, lastPosition
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: "Screen with mouse pointer"
        case .primary: "Primary screen"
        case .focusedWindow: "Screen with focused window"
        case .lastPosition: "Last position"
        }
    }
}

/// A command pinned to the quick access shelf. Title and icon are cached for when the
/// command can't be rebuilt (an app was deleted).
struct PinnedCommand: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var icon: ItemIcon
}

/// A short name that jumps to a command or page: "cb" → Clipboard History.
struct CommandAlias: Codable, Equatable, Hashable, Identifiable, Sendable {
    var alias: String
    /// Item id of the target command (`clipboard:page`, `apps:/Applications/Safari.app`).
    var target: String
    var title: String
    /// Direct aliases apply as soon as they are typed, without a space.
    var direct: Bool
    var id: String { alias.lowercased() }
}

/// A global shortcut that runs one command.
struct CommandHotkey: Codable, Equatable, Hashable, Identifiable, Sendable {
    var target: String
    var title: String
    var icon: ItemIcon
    var shortcut: Shortcut?
    var id: String { target }
}

/// Per-provider switches in Command Palette.
struct ProviderToggle: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Results appear in the main search; otherwise only through its alias, filter or page.
    var global: Bool
}

struct CommandPaletteSettings: Codable, Equatable, Sendable {
    enum OpenMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case full, compact
        var id: String { rawValue }
        var title: String { self == .full ? "Full palette" : "Compact search box" }
    }

    enum RecentPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
        case hidden, afterPinned
        var id: String { rawValue }
        var title: String { self == .hidden ? "Don’t show" : "After pinned" }
    }

    enum EscapeBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
        case clearThenBack, back, dismiss
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clearThenBack: "Clear search first, then go back"
            case .back: "Always go back"
            case .dismiss: "Always close"
            }
        }
    }

    enum NumberKeys: String, Codable, CaseIterable, Sendable, Identifiable {
        case run, select
        var id: String { rawValue }
        var title: String { self == .run ? "Run item" : "Select item" }
    }

    // Activation
    var activation: Shortcut? = Shortcut(kVK_Space, [.option])
    var ignoreInFullScreen = false
    // Behavior
    var keepQuery = false
    var selectQueryOnOpen = true
    /// Seconds after closing before reopening starts at Home again; 0 = always, -1 = never.
    var returnHomeAfter = 0
    var rememberFilter = true
    var lastFilter: String?
    var screen: LauncherScreen = .mouse
    var lastOrigin: [Double]?
    var escapeBehavior: EscapeBehavior = .clearThenBack
    var backspaceGoesBack = true
    var singleClickActivates = false
    var numberKeys: NumberKeys = .run
    var showDetails = true
    var resultsPerSection = 3
    var hideOnResign = true
    // Layout
    var openMode: OpenMode = .full
    var showShelf = true
    var maxPins = 9
    var shelfRecents: RecentPlacement = .hidden
    var homeRecents: RecentPlacement = .afterPinned
    var maxRecents = 5
    var backgroundOpacity = 0.55
    // Commands
    var pins: [PinnedCommand] = CommandPaletteSettings.defaultPins
    var aliases: [CommandAlias] = CommandPaletteSettings.defaultAliases
    var hotkeys: [CommandHotkey] = []
    var providers: [String: ProviderToggle] = [:]
    // Command links
    var enableCommandLinks = true
    var allowedLinks: [String] = []

    static let defaultPins: [PinnedCommand] = [
        PinnedCommand(id: "mactoys:open:colorpicker", title: "Color Picker", icon: .symbol("eyedropper.halffull", .pink)),
        PinnedCommand(id: "clipboard:page", title: "Clipboard", icon: .symbol("doc.on.clipboard.fill", .purple)),
        PinnedCommand(id: "calc:page", title: "Calculator", icon: .symbol("plus.forwardslash.minus", .graphite)),
        PinnedCommand(id: "apps:/System/Applications/Utilities/Terminal.app", title: "Terminal",
                      icon: .file("/System/Applications/Utilities/Terminal.app")),
        PinnedCommand(id: "mactoys:open:fancyzones", title: "Zones", icon: .symbol("square.grid.2x2.fill", .blue)),
    ]

    static let defaultAliases: [CommandAlias] = [
        CommandAlias(alias: "cb", target: "clipboard:page", title: "Clipboard History", direct: false),
        CommandAlias(alias: ">", target: "shell:page", title: "Shell", direct: true),
        CommandAlias(alias: "=", target: "calc:page", title: "Calculator", direct: true),
        CommandAlias(alias: "$", target: "settings:page", title: "System Settings", direct: true),
        CommandAlias(alias: "??", target: "web:page", title: "Web Search", direct: true),
        CommandAlias(alias: "<", target: "windows:page", title: "Windows", direct: true),
        CommandAlias(alias: "%%", target: "units:page", title: "Unit Converter", direct: true),
        CommandAlias(alias: "#", target: "values:page", title: "Value Generator", direct: true),
        CommandAlias(alias: "!!", target: "history:page", title: "History", direct: true),
        CommandAlias(alias: "@", target: "mactoys:page", title: "MacToys", direct: true),
        CommandAlias(alias: "{", target: "editors:page", title: "Code Workspaces", direct: true),
        CommandAlias(alias: "file", target: "files:page", title: "Search Files", direct: false),
        CommandAlias(alias: "bm", target: "bookmarks:page", title: "Bookmarks", direct: false),
        CommandAlias(alias: "kill", target: "processes:page", title: "Processes", direct: false),
        CommandAlias(alias: "brew", target: "brew:page", title: "Homebrew", direct: false),
        CommandAlias(alias: "sc", target: "scripts:page", title: "Script Commands", direct: false),
    ]

    @MainActor func toggle(for p: any SearchProvider) -> ProviderToggle {
        providers[p.id] ?? ProviderToggle(enabled: p.enabledByDefault, global: p.globalByDefault)
    }
}

/// Per-plugin settings in Run.
struct PluginSetting: Codable, Equatable, Sendable {
    var enabled: Bool
    var keyword: String
    var global: Bool
}

struct RunSettings: Codable, Equatable, Sendable {
    var activation: Shortcut? = Shortcut(kVK_Space, [.control, .option])
    var ignoreInFullScreen = false
    var clearOnOpen = false
    var clearOnLaunch = true
    var maxResults = 4
    var screen: LauncherScreen = .mouse
    /// Delay before searching while typing, in milliseconds.
    var searchDelay = 60.0
    /// How strongly often-used results rise (0 off … 10).
    var usageWeight = 5.0
    var showPluginHints = true
    var plugins: [String: PluginSetting] = [:]

    @MainActor func plugin(for p: any SearchProvider) -> PluginSetting {
        plugins[p.id] ?? PluginSetting(enabled: p.enabledByDefault, keyword: p.defaultKeyword, global: p.globalByDefault)
    }
}
