import Foundation
import MacToysCore

/// Web search engines.
enum SearchEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case google, duckduckgo, bing, kagi, brave, ecosia, startpage, perplexity, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        case .perplexity: "Perplexity"
        case .custom: String(localized: "Custom", comment: "Search engine: a URL the user enters")
        }
    }

    /// URL template; `%s` is replaced by the encoded query.
    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .perplexity: "https://www.perplexity.ai/search?q=%s"
        case .custom: ""
        }
    }
}

/// Terminal apps commands can run in.
enum TerminalApp: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal, iterm, ghostty
    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: String(localized: "Terminal", comment: "The macOS Terminal app; use the name it has in this language")
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        }
    }
}

/// How the Shell provider runs a command by default.
enum ShellMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal, silent, output
    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: String(localized: "Run in terminal")
        case .silent: String(localized: "Run silently")
        case .output: String(localized: "Run and show output")
        }
    }
}

/// Where file search looks.
enum FileScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case home, computer
    var id: String { rawValue }
    var title: String { self == .home ? String(localized: "Home folder") : String(localized: "Whole computer") }
}

/// Provider options shared by Command Palette and Run (stored in `cmdpal-providers.json`).
struct ProviderOptions: Codable, Equatable, Sendable {
    // Apps
    var appExtraFolders: [String] = []
    var appIncludeCoreServices = true
    var appShowRunningIndicator = true
    // Files
    var fileScope: FileScope = .home
    var fileMaxResults = 20
    var fileMatchContents = false
    var fileShowHidden = false
    // Calculator
    var angleUnit: AngleUnit = .radians
    var calcShowBases = true
    var calcShowScientific = true
    // Units
    var unitsCopyWithUnit = false
    // Time & Date
    var worldClocks: [String] = ["Europe/London", "America/New_York", "Asia/Tokyo"]
    var timeCustomFormats = ""
    var timeShowSeconds = true
    // Web search and URLs
    var searchEngine: SearchEngine = .google
    var customSearchURL = "https://www.google.com/search?q=%s"
    /// Bundle id of the browser for searches and URLs; empty for the default browser.
    var browserBundleID = ""
    // Shell
    var terminal: TerminalApp = .terminal
    var shellMode: ShellMode = .terminal
    var shellKeepOpen = true
    var shellRememberHistory = true
    // Windows
    var windowsIncludeMinimized = true
    var windowsIncludeHidden = false
    // System commands
    var confirmSystemCommands = true
    // Clipboard
    var clipboardPasteOnEnter = true
    // Bookmarks: browser id → enabled
    var bookmarkBrowsers: [String: Bool] = [:]
    // Processes
    var processesConfirmKill = true
    // Script Commands
    var scriptsFolder = ""
    var exampleScriptCreated = false
    // Homebrew
    var brewIncludeCasks = true
    // Editors (VS Code workspaces): editor id → enabled
    var editors: [String: Bool] = [:]

    /// The script folder, defaulting to ~/Library/Application Support/MacToys/cmdpal/scripts.
    var resolvedScriptsFolder: URL {
        let trimmed = scriptsFolder.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true) }
        return Paths.data(for: "cmdpal").appendingPathComponent("scripts", isDirectory: true)
    }

    /// The search URL template in effect.
    var searchTemplate: String {
        searchEngine == .custom ? customSearchURL : searchEngine.template
    }
}
