import AppKit
import MacToysCore

/// System Settings panes (`$`): opens any pane or privacy section by name or location.
@MainActor
final class SystemSettingsProvider: SearchProvider {
    let id = "settings"
    let name = String(localized: "System Settings", comment: "Provider name: the macOS System Settings app")
    let summary = String(localized: "Open any System Settings pane: Wi‑Fi, Displays, Privacy & Security…")
    let icon = ItemIcon.symbol("gearshape.fill", .graphite)
    let defaultKeyword = "$"
    var examples: [String] {
        ["$ displays", String(localized: "\("$ general:")  (everything under General)",
                              comment: "Run help example: %@ is what to type, the parentheses explain it"), "$ privacy>camera"]
    }

    struct Pane {
        let id: String
        let title: Phrase
        /// Where it lives, e.g. General for Date & Time; nil for top-level panes.
        let area: Phrase?
        let symbol: String
        let tint: Tint
        let anchor: String
        let keywords: [String]

        var url: URL? { URL(string: "x-apple.systempreferences:\(anchor)") }
        var subtitle: String {
            area.map { "\($0.text) › \(title.text)" } ?? String(localized: "Settings pane", comment: "Subtitle of a top-level System Settings pane")
        }
        /// Title, English title, area and keywords, for matching.
        var terms: [String] { title.englishTerms + keywords + (area.map { [$0.text] + $0.englishTerms } ?? []) }
    }

    static let panes: [Pane] = {
        func p(_ id: String, _ title: LocalizedStringResource, _ area: Phrase?, _ symbol: String, _ tint: Tint, _ anchor: String,
               _ keywords: [String] = []) -> Pane {
            Pane(id: id, title: Phrase(title), area: area, symbol: symbol, tint: tint, anchor: anchor, keywords: keywords)
        }
        let general = Phrase(.init("General", comment: "System Settings pane; use the name macOS shows"))
        let network = Phrase(.init("Network", comment: "System Settings pane; use the name macOS shows"))
        let privacySecurity = Phrase(.init("Privacy & Security", comment: "System Settings pane; use the name macOS shows"))
        let privacy = "com.apple.settings.PrivacySecurity.extension"
        return [
            p("appleaccount", "Apple Account", nil, "person.crop.circle.fill", .blue, "com.apple.systempreferences.AppleIDSettings",
              ["apple id", "icloud", "account"]),
            p("family", .init("Family", comment: "System Settings pane; use the name macOS shows"), nil, "person.2.fill", .blue, "com.apple.Family-Settings.extension", ["family sharing"]),
            p("wifi", "Wi‑Fi", nil, "wifi", .blue, "com.apple.wifi-settings-extension", ["wifi", "wireless", "network"]),
            p("bluetooth", "Bluetooth", nil, "dot.radiowaves.left.and.right", .blue, "com.apple.BluetoothSettings", ["bluetooth"]),
            p("network", .init("Network", comment: "System Settings pane; use the name macOS shows"), nil, "network", .blue, "com.apple.Network-Settings.extension", ["ethernet", "dns", "proxy", "firewall"]),
            p("vpn", "VPN", network, "network.badge.shield.half.filled", .blue, "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", ["vpn"]),
            p("battery", .init("Battery", comment: "System Settings pane; use the name macOS shows"), nil, "battery.100percent", .green, "com.apple.Battery-Settings.extension", ["energy", "power", "low power"]),
            p("general", .init("General", comment: "System Settings pane; use the name macOS shows"), nil, "gearshape.fill", .graphite, "com.apple.systempreferences.GeneralSettings"),
            p("about", .init("About", comment: "System Settings pane; use the name macOS shows"), general, "info.circle", .graphite, "com.apple.SystemProfiler.AboutExtension", ["serial", "model", "this mac"]),
            p("softwareupdate", "Software Update", general, "arrow.down.circle.fill", .graphite,
              "com.apple.Software-Update-Settings.extension", ["update", "upgrade", "macos"]),
            p("storage", .init("Storage", comment: "System Settings pane; use the name macOS shows"), general, "internaldrive", .graphite, "com.apple.settings.Storage", ["disk space", "free space"]),
            p("airdrop", "AirDrop & Handoff", general, "dot.radiowaves.left.and.right", .graphite,
              "com.apple.AirDrop-Handoff-Settings.extension", ["airdrop", "handoff", "airplay receiver"]),
            p("loginitems", "Login Items & Extensions", general, "list.bullet", .graphite, "com.apple.LoginItems-Settings.extension",
              ["startup", "login items", "extensions", "background"]),
            p("language", "Language & Region", general, "globe", .graphite, "com.apple.Localization-Settings.extension",
              ["language", "region", "locale", "translation"]),
            p("datetime", "Date & Time", general, "calendar.badge.clock", .graphite, "com.apple.Date-Time-Settings.extension",
              ["clock", "time zone", "date", "time"]),
            p("sharing", .init("Sharing", comment: "System Settings pane; use the name macOS shows"), general, "square.and.arrow.up", .graphite, "com.apple.Sharing-Settings.extension",
              ["file sharing", "screen sharing", "remote login", "ssh", "computer name", "hostname"]),
            p("timemachine", "Time Machine", general, "clock.arrow.circlepath", .graphite, "com.apple.Time-Machine-Settings.extension",
              ["backup"]),
            p("transfer", "Transfer or Reset", general, "arrow.triangle.2.circlepath", .graphite,
              "com.apple.Transfer-Reset-Settings.extension", ["erase", "reset", "migration"]),
            p("startupdisk", "Startup Disk", general, "internaldrive", .graphite, "com.apple.Startup-Disk-Settings.extension", ["boot"]),
            p("devicemanagement", "Device Management", general, "gearshape.2.fill", .graphite, "com.apple.Profiles-Settings.extension",
              ["profiles", "mdm"]),
            p("accessibility", .init("Accessibility", comment: "System Settings pane; use the name macOS shows"), nil, "accessibility", .blue, "com.apple.Accessibility-Settings.extension",
              ["voiceover", "zoom", "display", "pointer"]),
            p("appearance", .init("Appearance", comment: "System Settings pane; use the name macOS shows"), nil, "circle.lefthalf.filled", .graphite, "com.apple.Appearance-Settings.extension",
              ["dark mode", "light mode", "accent color", "theme"]),
            p("intelligence", "Apple Intelligence & Siri", nil, "sparkles", .purple, "com.apple.Siri-Settings.extension", ["siri", "ai"]),
            p("controlcenter", "Control Center", nil, "switch.2", .graphite, "com.apple.ControlCenter-Settings.extension",
              ["menu bar", "menu bar icons"]),
            p("desktopdock", "Desktop & Dock", nil, "menubar.dock.rectangle", .graphite, "com.apple.Desktop-Settings.extension",
              ["dock", "stage manager", "hot corners", "mission control", "widgets"]),
            p("displays", .init("Displays", comment: "System Settings pane; use the name macOS shows"), nil, "display", .blue, "com.apple.Displays-Settings.extension",
              ["resolution", "night shift", "brightness", "monitor", "scaling"]),
            p("screensaver", "Screen Saver", nil, "sparkles.tv", .cyan, "com.apple.ScreenSaver-Settings.extension"),
            p("spotlight", "Spotlight", nil, "magnifyingglass", .graphite, "com.apple.Spotlight-Settings.extension", ["search", "index"]),
            p("wallpaper", .init("Wallpaper", comment: "System Settings pane; use the name macOS shows"), nil, "photo.fill", .cyan, "com.apple.Wallpaper-Settings.extension", ["background", "desktop picture"]),
            p("notifications", .init("Notifications", comment: "System Settings pane; use the name macOS shows"), nil, "bell.badge.fill", .red, "com.apple.Notifications-Settings.extension", ["alerts", "banners"]),
            p("sound", .init("Sound", comment: "System Settings pane; use the name macOS shows"), nil, "speaker.wave.2.fill", .pink, "com.apple.Sound-Settings.extension",
              ["volume", "output", "input", "microphone", "alert sound"]),
            p("focus", .init("Focus", comment: "System Settings pane; use the name macOS shows"), nil, "moon.fill", .indigo, "com.apple.Focus-Settings.extension", ["do not disturb", "dnd"]),
            p("screentime", "Screen Time", nil, "hourglass", .purple, "com.apple.Screen-Time-Settings.extension", ["downtime", "app limits"]),
            p("lockscreen", .init("Lock Screen", comment: "System Settings pane; use the name macOS shows"), nil, "lock.fill", .graphite, "com.apple.Lock-Screen-Settings.extension",
              ["screen saver delay", "require password"]),
            p("privacy", "Privacy & Security", nil, "hand.raised.fill", .blue, privacy, ["security", "filevault", "gatekeeper"]),
            p("privacy.accessibility", .init("Accessibility", comment: "System Settings pane; use the name macOS shows"), privacySecurity, "accessibility", .blue,
              "com.apple.preference.security?Privacy_Accessibility", ["permission"]),
            p("privacy.screen", "Screen & System Audio Recording", privacySecurity, "rectangle.dashed.badge.record", .red,
              "com.apple.preference.security?Privacy_ScreenCapture", ["screen recording", "permission"]),
            p("privacy.input", "Input Monitoring", privacySecurity, "keyboard", .graphite,
              "com.apple.preference.security?Privacy_ListenEvent", ["keyboard", "permission"]),
            p("privacy.fulldisk", "Full Disk Access", privacySecurity, "internaldrive", .graphite,
              "com.apple.preference.security?Privacy_AllFiles", ["permission", "files"]),
            p("privacy.automation", .init("Automation", comment: "System Settings pane; use the name macOS shows"), privacySecurity, "gearshape.2.fill", .graphite,
              "com.apple.preference.security?Privacy_Automation", ["apple events", "permission"]),
            p("privacy.location", "Location Services", privacySecurity, "location.fill", .blue,
              "com.apple.preference.security?Privacy_LocationServices", ["gps", "permission"]),
            p("privacy.camera", "Camera", privacySecurity, "camera.fill", .graphite,
              "com.apple.preference.security?Privacy_Camera", ["webcam", "permission"]),
            p("privacy.microphone", "Microphone", privacySecurity, "mic.fill", .orange,
              "com.apple.preference.security?Privacy_Microphone", ["permission"]),
            p("privacy.files", "Files & Folders", privacySecurity, "folder.fill", .blue,
              "com.apple.preference.security?Privacy_FilesAndFolders", ["permission"]),
            p("touchid", "Touch ID & Password", nil, "touchid", .red, "com.apple.Touch-ID-Settings.extension", ["fingerprint", "password"]),
            p("users", "Users & Groups", nil, "person.2.fill", .graphite, "com.apple.Users-Groups-Settings.extension", ["accounts", "guest"]),
            p("internetaccounts", "Internet Accounts", nil, "at", .blue, "com.apple.Internet-Accounts-Settings.extension",
              ["mail accounts", "google", "exchange"]),
            p("passwords", .init("Passwords", comment: "System Settings pane; use the name macOS shows"), nil, "key.fill", .graphite, "com.apple.Passwords-Settings.extension", ["keychain"]),
            p("gamecenter", "Game Center", nil, "gamecontroller.fill", .pink, "com.apple.Game-Center-Settings.extension"),
            p("wallet", "Wallet & Apple Pay", nil, "wallet.pass.fill", .graphite, "com.apple.WalletSettingsExtension", ["apple pay", "cards"]),
            p("keyboard", .init("Keyboard", comment: "System Settings pane; use the name macOS shows"), nil, "keyboard", .graphite, "com.apple.Keyboard-Settings.extension",
              ["shortcuts", "input sources", "dictation", "key repeat", "text replacements"]),
            p("mouse", .init("Mouse", comment: "System Settings pane; use the name macOS shows"), nil, "computermouse.fill", .graphite, "com.apple.Mouse-Settings.extension", ["scroll", "tracking speed"]),
            p("trackpad", "Trackpad", nil, "rectangle.and.hand.point.up.left.fill", .graphite, "com.apple.Trackpad-Settings.extension",
              ["gestures", "tap to click", "scroll"]),
            p("gamecontrollers", "Game Controllers", nil, "gamecontroller.fill", .graphite, "com.apple.Game-Controller-Settings.extension"),
            p("printers", "Printers & Scanners", nil, "printer.fill", .graphite, "com.apple.Print-Scanner-Settings.extension", ["printer", "scanner"]),
        ]
    }()

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase(.init("System Settings", comment: "Provider name: the macOS System Settings app")),
                     subtitle: String(localized: "Search every System Settings pane"), keywords: ["preferences", "settings"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return Self.panes.enumerated().map { i, p in item(p, score: 500 - Double(i)) }
        }
        guard query.scoped || text.count >= 2 else { return [] }
        // Location search: "general:" lists the panes of General, "privacy>cam" narrows inside it.
        if text.hasSuffix(":") || text.contains(">") {
            let parts = text.split(whereSeparator: { $0 == ">" || $0 == ":" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let area = parts.first, !area.isEmpty else { return [] }
            let rest = parts.dropFirst().joined(separator: " ")
            return Self.panes.compactMap { p in
                let place = p.area ?? p.title
                guard FuzzyMatcher.score(area, place.text) ?? FuzzyMatcher.score(area, place.english) != nil else { return nil }
                if rest.isEmpty { return item(p, score: 800) }
                return FuzzyMatcher.best(rest, title: p.title.text, keywords: p.title.englishTerms + p.keywords).map { item(p, score: $0) }
            }
        }
        return Self.panes.compactMap { p in
            guard let s = FuzzyMatcher.best(text, title: p.title.text, keywords: p.terms) else { return nil }
            // Keyword-only matches (e.g. "time" in Date & Time) rank below title matches.
            return item(p, score: query.scoped ? s : s * 0.97)
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        return Self.panes.first { "settings:\($0.id)" == id }.map { item($0, score: 0) }
    }

    func item(_ p: Pane, score: Double) -> PaletteItem {
        PaletteItem(
            id: "settings:\(p.id)", title: p.title.text, subtitle: p.subtitle, icon: .symbol(p.symbol, p.tint), providerID: id,
            accessory: Labels.open, score: score,
            primary: PaletteAction(id: "open", title: Labels.open, symbol: "gearshape") {
                if let url = p.url { Launch.open(url) }
                return .dismiss
            },
            actions: [PaletteAction(id: "copylink", title: String(localized: "Copy Settings Link"), symbol: "link",
                                    shortcut: ActionKeys.copyPath) {
                Launch.copy(p.url?.absoluteString ?? "")
                return .dismiss
            }],
            keywords: p.title.englishTerms + p.keywords)
    }
}
