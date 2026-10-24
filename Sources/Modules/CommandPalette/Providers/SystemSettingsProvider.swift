import AppKit
import MacToysCore

/// System Settings panes (`$`): opens any pane or privacy section by name or location.
@MainActor
final class SystemSettingsProvider: SearchProvider {
    let id = "settings"
    let name = "System Settings"
    let summary = "Open any System Settings pane: Wi‑Fi, Displays, Privacy & Security…"
    let icon = ItemIcon.symbol("gearshape.fill", .graphite)
    let defaultKeyword = "$"
    let examples = ["$ displays", "$ general:  (everything under General)", "$ privacy>camera"]

    struct Pane {
        let id: String
        let title: String
        /// Where it lives, e.g. "General" for Date & Time; empty for top-level panes.
        let area: String
        let symbol: String
        let tint: Tint
        let anchor: String
        let keywords: [String]

        var url: URL? { URL(string: "x-apple.systempreferences:\(anchor)") }
        var subtitle: String { area.isEmpty ? "Settings pane" : "\(area) › \(title)" }
    }

    static let panes: [Pane] = {
        func p(_ id: String, _ title: String, _ area: String, _ symbol: String, _ tint: Tint, _ anchor: String,
               _ keywords: [String] = []) -> Pane {
            Pane(id: id, title: title, area: area, symbol: symbol, tint: tint, anchor: anchor, keywords: keywords)
        }
        let privacy = "com.apple.settings.PrivacySecurity.extension"
        return [
            p("appleaccount", "Apple Account", "", "person.crop.circle.fill", .blue, "com.apple.systempreferences.AppleIDSettings",
              ["apple id", "icloud", "account"]),
            p("family", "Family", "", "person.2.fill", .blue, "com.apple.Family-Settings.extension", ["family sharing"]),
            p("wifi", "Wi‑Fi", "", "wifi", .blue, "com.apple.wifi-settings-extension", ["wifi", "wireless", "network"]),
            p("bluetooth", "Bluetooth", "", "dot.radiowaves.left.and.right", .blue, "com.apple.BluetoothSettings", ["bluetooth"]),
            p("network", "Network", "", "network", .blue, "com.apple.Network-Settings.extension", ["ethernet", "dns", "proxy", "firewall"]),
            p("vpn", "VPN", "Network", "network.badge.shield.half.filled", .blue, "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", ["vpn"]),
            p("battery", "Battery", "", "battery.100percent", .green, "com.apple.Battery-Settings.extension", ["energy", "power", "low power"]),
            p("general", "General", "", "gearshape.fill", .graphite, "com.apple.systempreferences.GeneralSettings"),
            p("about", "About", "General", "info.circle", .graphite, "com.apple.SystemProfiler.AboutExtension", ["serial", "model", "this mac"]),
            p("softwareupdate", "Software Update", "General", "arrow.down.circle.fill", .graphite,
              "com.apple.Software-Update-Settings.extension", ["update", "upgrade", "macos"]),
            p("storage", "Storage", "General", "internaldrive", .graphite, "com.apple.settings.Storage", ["disk space", "free space"]),
            p("airdrop", "AirDrop & Handoff", "General", "dot.radiowaves.left.and.right", .graphite,
              "com.apple.AirDrop-Handoff-Settings.extension", ["airdrop", "handoff", "airplay receiver"]),
            p("loginitems", "Login Items & Extensions", "General", "list.bullet", .graphite, "com.apple.LoginItems-Settings.extension",
              ["startup", "login items", "extensions", "background"]),
            p("language", "Language & Region", "General", "globe", .graphite, "com.apple.Localization-Settings.extension",
              ["language", "region", "locale", "translation"]),
            p("datetime", "Date & Time", "General", "calendar.badge.clock", .graphite, "com.apple.Date-Time-Settings.extension",
              ["clock", "time zone", "date", "time"]),
            p("sharing", "Sharing", "General", "square.and.arrow.up", .graphite, "com.apple.Sharing-Settings.extension",
              ["file sharing", "screen sharing", "remote login", "ssh", "computer name", "hostname"]),
            p("timemachine", "Time Machine", "General", "clock.arrow.circlepath", .graphite, "com.apple.Time-Machine-Settings.extension",
              ["backup"]),
            p("transfer", "Transfer or Reset", "General", "arrow.triangle.2.circlepath", .graphite,
              "com.apple.Transfer-Reset-Settings.extension", ["erase", "reset", "migration"]),
            p("startupdisk", "Startup Disk", "General", "internaldrive", .graphite, "com.apple.Startup-Disk-Settings.extension", ["boot"]),
            p("devicemanagement", "Device Management", "General", "gearshape.2.fill", .graphite, "com.apple.Profiles-Settings.extension",
              ["profiles", "mdm"]),
            p("accessibility", "Accessibility", "", "accessibility", .blue, "com.apple.Accessibility-Settings.extension",
              ["voiceover", "zoom", "display", "pointer"]),
            p("appearance", "Appearance", "", "circle.lefthalf.filled", .graphite, "com.apple.Appearance-Settings.extension",
              ["dark mode", "light mode", "accent color", "theme"]),
            p("intelligence", "Apple Intelligence & Siri", "", "sparkles", .purple, "com.apple.Siri-Settings.extension", ["siri", "ai"]),
            p("controlcenter", "Control Center", "", "switch.2", .graphite, "com.apple.ControlCenter-Settings.extension",
              ["menu bar", "menu bar icons"]),
            p("desktopdock", "Desktop & Dock", "", "menubar.dock.rectangle", .graphite, "com.apple.Desktop-Settings.extension",
              ["dock", "stage manager", "hot corners", "mission control", "widgets"]),
            p("displays", "Displays", "", "display", .blue, "com.apple.Displays-Settings.extension",
              ["resolution", "night shift", "brightness", "monitor", "scaling"]),
            p("screensaver", "Screen Saver", "", "sparkles.tv", .cyan, "com.apple.ScreenSaver-Settings.extension"),
            p("spotlight", "Spotlight", "", "magnifyingglass", .graphite, "com.apple.Spotlight-Settings.extension", ["search", "index"]),
            p("wallpaper", "Wallpaper", "", "photo.fill", .cyan, "com.apple.Wallpaper-Settings.extension", ["background", "desktop picture"]),
            p("notifications", "Notifications", "", "bell.badge.fill", .red, "com.apple.Notifications-Settings.extension", ["alerts", "banners"]),
            p("sound", "Sound", "", "speaker.wave.2.fill", .pink, "com.apple.Sound-Settings.extension",
              ["volume", "output", "input", "microphone", "alert sound"]),
            p("focus", "Focus", "", "moon.fill", .indigo, "com.apple.Focus-Settings.extension", ["do not disturb", "dnd"]),
            p("screentime", "Screen Time", "", "hourglass", .purple, "com.apple.Screen-Time-Settings.extension", ["downtime", "app limits"]),
            p("lockscreen", "Lock Screen", "", "lock.fill", .graphite, "com.apple.Lock-Screen-Settings.extension",
              ["screen saver delay", "require password"]),
            p("privacy", "Privacy & Security", "", "hand.raised.fill", .blue, privacy, ["security", "filevault", "gatekeeper"]),
            p("privacy.accessibility", "Accessibility", "Privacy & Security", "accessibility", .blue,
              "com.apple.preference.security?Privacy_Accessibility", ["permission"]),
            p("privacy.screen", "Screen & System Audio Recording", "Privacy & Security", "rectangle.dashed.badge.record", .red,
              "com.apple.preference.security?Privacy_ScreenCapture", ["screen recording", "permission"]),
            p("privacy.input", "Input Monitoring", "Privacy & Security", "keyboard", .graphite,
              "com.apple.preference.security?Privacy_ListenEvent", ["keyboard", "permission"]),
            p("privacy.fulldisk", "Full Disk Access", "Privacy & Security", "internaldrive", .graphite,
              "com.apple.preference.security?Privacy_AllFiles", ["permission", "files"]),
            p("privacy.automation", "Automation", "Privacy & Security", "gearshape.2.fill", .graphite,
              "com.apple.preference.security?Privacy_Automation", ["apple events", "permission"]),
            p("privacy.location", "Location Services", "Privacy & Security", "location.fill", .blue,
              "com.apple.preference.security?Privacy_LocationServices", ["gps", "permission"]),
            p("privacy.camera", "Camera", "Privacy & Security", "camera.fill", .graphite,
              "com.apple.preference.security?Privacy_Camera", ["webcam", "permission"]),
            p("privacy.microphone", "Microphone", "Privacy & Security", "mic.fill", .orange,
              "com.apple.preference.security?Privacy_Microphone", ["permission"]),
            p("privacy.files", "Files & Folders", "Privacy & Security", "folder.fill", .blue,
              "com.apple.preference.security?Privacy_FilesAndFolders", ["permission"]),
            p("touchid", "Touch ID & Password", "", "touchid", .red, "com.apple.Touch-ID-Settings.extension", ["fingerprint", "password"]),
            p("users", "Users & Groups", "", "person.2.fill", .graphite, "com.apple.Users-Groups-Settings.extension", ["accounts", "guest"]),
            p("internetaccounts", "Internet Accounts", "", "at", .blue, "com.apple.Internet-Accounts-Settings.extension",
              ["mail accounts", "google", "exchange"]),
            p("passwords", "Passwords", "", "key.fill", .graphite, "com.apple.Passwords-Settings.extension", ["keychain"]),
            p("gamecenter", "Game Center", "", "gamecontroller.fill", .pink, "com.apple.Game-Center-Settings.extension"),
            p("wallet", "Wallet & Apple Pay", "", "wallet.pass.fill", .graphite, "com.apple.WalletSettingsExtension", ["apple pay", "cards"]),
            p("keyboard", "Keyboard", "", "keyboard", .graphite, "com.apple.Keyboard-Settings.extension",
              ["shortcuts", "input sources", "dictation", "key repeat", "text replacements"]),
            p("mouse", "Mouse", "", "computermouse.fill", .graphite, "com.apple.Mouse-Settings.extension", ["scroll", "tracking speed"]),
            p("trackpad", "Trackpad", "", "rectangle.and.hand.point.up.left.fill", .graphite, "com.apple.Trackpad-Settings.extension",
              ["gestures", "tap to click", "scroll"]),
            p("gamecontrollers", "Game Controllers", "", "gamecontroller.fill", .graphite, "com.apple.Game-Controller-Settings.extension"),
            p("printers", "Printers & Scanners", "", "printer.fill", .graphite, "com.apple.Print-Scanner-Settings.extension", ["printer", "scanner"]),
        ]
    }()

    var commands: [PaletteItem] {
        [pageCommand(title: "System Settings", subtitle: "Search every System Settings pane", keywords: ["preferences", "settings"])]
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
                guard FuzzyMatcher.score(area, p.area.isEmpty ? p.title : p.area) != nil else { return nil }
                if rest.isEmpty { return item(p, score: 800) }
                return FuzzyMatcher.best(rest, title: p.title, keywords: p.keywords).map { item(p, score: $0) }
            }
        }
        return Self.panes.compactMap { p in
            guard let s = FuzzyMatcher.best(text, title: p.title, keywords: p.keywords + (p.area.isEmpty ? [] : [p.area])) else { return nil }
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
            id: "settings:\(p.id)", title: p.title, subtitle: p.subtitle, icon: .symbol(p.symbol, p.tint), providerID: id,
            accessory: "Open", score: score,
            primary: PaletteAction(id: "open", title: "Open", symbol: "gearshape") {
                if let url = p.url { Launch.open(url) }
                return .dismiss
            },
            actions: [PaletteAction(id: "copylink", title: "Copy Settings Link", symbol: "link", shortcut: ActionKeys.copyPath) {
                Launch.copy(p.url?.absoluteString ?? "")
                return .dismiss
            }],
            keywords: p.keywords)
    }
}
