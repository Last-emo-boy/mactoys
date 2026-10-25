import AppKit
import MacToysCore
import SystemConfiguration

/// Network addresses of this Mac.
enum NetworkInfo {
    struct Address: Hashable, Sendable {
        let interface: String
        let displayName: String
        let value: String
        let kind: String
    }

    static func addresses() -> [Address] {
        var names: [String: String] = [:]
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? { names[bsd] = display }
        }
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var out: [Address] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ptr.pointee.ifa_addr else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") else { continue }
            let display = names[name] ?? name
            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                var value = String(cString: host)
                if let percent = value.firstIndex(of: "%") { value = String(value[..<percent]) }
                if family == AF_INET6, value.hasPrefix("fe80") { continue }
                out.append(Address(interface: name, displayName: display, value: value, kind: family == AF_INET ? "IPv4" : "IPv6"))
            } else if family == AF_LINK, name.hasPrefix("en") {
                let mac = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                    let nlen = Int(dl.pointee.sdl_nlen), alen = Int(dl.pointee.sdl_alen)
                    guard alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
                    let base = UnsafeRawPointer(dl).advanced(by: offset + nlen)
                    let bytes = (0..<alen).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
                if let mac { out.append(Address(interface: name, displayName: display, value: mac, kind: "MAC")) }
            }
        }
        return out
    }
}

/// System commands: lock, sleep, restart, shut down, log out, Trash, appearance, and more.
@MainActor
final class SystemCommandsProvider: SearchProvider {
    let id = "system"
    let name = String(localized: "System", comment: "Provider name and row label: system commands (lock, sleep, restart…)")
    let summary = String(localized: "Lock, sleep, restart, shut down, log out, empty the Trash, toggle Dark Mode and more")
    let icon = ItemIcon.symbol("power", .red)
    let defaultKeyword = ""
    let examples = ["lock", "sleep", "restart", "empty trash", "dark mode", "ip address"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    private struct Command {
        let id: String
        let title: Phrase
        let subtitle: String
        let symbol: String
        let tint: Tint
        let keywords: [String]
        /// Destructive commands ask first when confirmation is on: the confirm button's title.
        let confirm: String?
        let run: @MainActor () -> Void
    }

    private var list: [Command] {
        [
            // Its own key: the command is a verb ("lock the screen"), the System Settings pane of the same English name a noun.
            Command(id: "lock", title: Phrase(.init("Lock Screen (command)", defaultValue: "Lock Screen",
                                                    comment: "System command: lock the Mac now, like Apple menu › Lock Screen")),
                    subtitle: String(localized: "Lock this Mac"), symbol: "lock.fill",
                    tint: .indigo, keywords: ["lock", "lock screen", "away"], confirm: nil) { SystemActions.lockScreen() },
            Command(id: "sleep", title: Phrase(.init("Sleep", comment: "System command: put the Mac to sleep")),
                    subtitle: String(localized: "Put this Mac to sleep"), symbol: "moon.zzz.fill", tint: .indigo,
                    keywords: ["sleep", "suspend", "standby"], confirm: nil) { SystemActions.pmset("sleepnow") },
            Command(id: "displaysleep", title: Phrase(.init("Sleep Displays", comment: "System command: turn the displays off")),
                    subtitle: String(localized: "Turn the displays off"), symbol: "display",
                    tint: .indigo, keywords: ["display sleep", "screen off", "monitor off"], confirm: nil) {
                SystemActions.pmset("displaysleepnow")
            },
            Command(id: "restart", title: Phrase(.init("Restart", comment: "System command and its confirmation button: restart the Mac")),
                    subtitle: String(localized: "Restart this Mac"), symbol: "restart", tint: .orange,
                    keywords: ["restart", "reboot"],
                    confirm: String(localized: "Restart", comment: "System command and its confirmation button: restart the Mac")) {
                SystemActions.loginwindow("aevtrest")
            },
            Command(id: "shutdown", title: Phrase(.init("Shut Down", comment: "System command and its confirmation button: turn the Mac off")),
                    subtitle: String(localized: "Turn this Mac off"), symbol: "power", tint: .red,
                    keywords: ["shut down", "shutdown", "power off", "turn off"],
                    confirm: String(localized: "Shut Down", comment: "System command and its confirmation button: turn the Mac off")) {
                SystemActions.loginwindow("aevtshut")
            },
            Command(id: "logout", title: Phrase(.init("Log Out", comment: "System command and its confirmation button: log out of the user account")),
                    subtitle: String(localized: "Log out of \(NSFullUserName())", comment: "%@ is the user's full name"),
                    symbol: "rectangle.portrait.and.arrow.right", tint: .orange, keywords: ["log out", "logout", "sign out"],
                    confirm: String(localized: "Log Out", comment: "System command and its confirmation button: log out of the user account")) {
                SystemActions.loginwindow("aevtrlgo")
            },
            Command(id: "emptytrash", title: Phrase("Empty Trash"), subtitle: String(localized: "Permanently erase the items in the Trash"),
                    symbol: "trash.fill", tint: .graphite, keywords: ["empty trash", "trash", "recycle bin", "bin"],
                    confirm: String(localized: "Empty Trash", comment: "Confirmation button: empty the Trash")) {
                SystemActions.emptyTrash()
            },
            Command(id: "opentrash", title: Phrase("Open Trash"), subtitle: String(localized: "Show the Trash in Finder"),
                    symbol: "trash", tint: .graphite, keywords: ["trash", "recycle bin", "bin"], confirm: nil) {
                Launch.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            },
            Command(id: "darkmode", title: Phrase("Toggle Dark Mode"), subtitle: String(localized: "Switch between light and dark appearance"),
                    symbol: "circle.lefthalf.filled", tint: .graphite, keywords: ["dark mode", "light mode", "appearance", "theme"],
                    confirm: nil) { SystemActions.toggleDarkMode() },
            Command(id: "showdesktop", title: Phrase("Show Desktop"), subtitle: String(localized: "Move windows aside"),
                    symbol: "menubar.dock.rectangle", tint: .blue, keywords: ["desktop", "show desktop"], confirm: nil) {
                SystemActions.missionControl(argument: "1")
            },
            Command(id: "missioncontrol", title: Phrase("Mission Control"), subtitle: String(localized: "Show all windows and Spaces"),
                    symbol: "rectangle.3.group", tint: .blue, keywords: ["mission control", "expose", "spaces"], confirm: nil) {
                SystemActions.missionControl(argument: nil)
            },
            Command(id: "screensaver", title: Phrase("Start Screen Saver"), subtitle: String(localized: "Run the screen saver now"),
                    symbol: "sparkles.tv", tint: .purple, keywords: ["screen saver", "screensaver"], confirm: nil) {
                Launch.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            },
            Command(id: "eject", title: Phrase("Eject All Disks"), subtitle: String(localized: "Unmount every removable volume"),
                    symbol: "eject.fill", tint: .graphite, keywords: ["eject", "unmount", "disks", "volumes"], confirm: nil) {
                SystemActions.ejectAll()
            },
            Command(id: "mute", title: Phrase("Toggle Mute"), subtitle: String(localized: "Mute or unmute the sound output"),
                    symbol: "speaker.slash.fill", tint: .pink, keywords: ["mute", "unmute", "sound", "volume"], confirm: nil) {
                SystemActions.toggleMute()
            },
            Command(id: "hiddenfiles", title: Phrase("Toggle Hidden Files"), subtitle: String(localized: "Show or hide hidden files in Finder"),
                    symbol: "eye.slash", tint: .blue, keywords: ["hidden files", "dotfiles", "show hidden"], confirm: nil) {
                SystemActions.toggleHiddenFiles()
            },
            Command(id: "relaunchfinder", title: Phrase("Relaunch Finder"), subtitle: String(localized: "Quit and reopen Finder"),
                    symbol: "arrow.clockwise", tint: .blue, keywords: ["restart finder", "relaunch finder", "finder"], confirm: nil) {
                SystemActions.killall("Finder")
            },
            Command(id: "restartdock", title: Phrase("Restart Dock"), subtitle: String(localized: "Quit and reopen the Dock"),
                    symbol: "dock.rectangle", tint: .blue, keywords: ["restart dock", "dock"], confirm: nil) {
                SystemActions.killall("Dock")
            },
        ]
    }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("System Commands"), subtitle: String(localized: "Lock, sleep, restart, shut down and more"),
                     keywords: ["power", "system"])]
    }

    /// Every system command, for pickers in settings.
    var allCommands: [PaletteItem] { list.map { item($0, score: 0) } }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return list.enumerated().map { i, c in item(c, score: 500 - Double(i)) }
        }
        guard query.scoped || text.count >= 2 else { return [] }
        var results = list.compactMap { c -> PaletteItem? in
            guard let s = FuzzyMatcher.best(text, title: c.title.text, keywords: c.title.englishTerms + c.keywords) else { return nil }
            return item(c, score: s)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("ip") || lower.hasPrefix("mac") || lower.hasPrefix("address") || (query.scoped && lower.hasPrefix("net")) {
            results += await addressItems(macOnly: lower.hasPrefix("mac"), ipOnly: lower.hasPrefix("ip"))
        }
        return results
    }

    func resolve(_ id: String) -> PaletteItem? {
        if id == "system:page" { return commands.first }
        if id.hasPrefix("system:address:") { return nil }
        guard id.hasPrefix("system:"), let c = list.first(where: { "system:\($0.id)" == id }) else { return nil }
        return item(c, score: 0)
    }

    private func item(_ c: Command, score: Double) -> PaletteItem {
        let confirmFirst = engine.options.value.confirmSystemCommands
        let run = c.run
        let primary = PaletteAction(id: "run", title: c.title.text, symbol: c.symbol, destructive: c.confirm != nil) {
            if let verb = c.confirm, confirmFirst {
                let question = String(localized: "\(c.title.text)?", comment: "Confirmation prompt; %@ is a system command such as “Restart”")
                return .confirm(Confirmation(title: question, message: c.subtitle, confirmTitle: verb) {
                    .dismissThen(run)
                })
            }
            return .dismissThen(run)
        }
        return PaletteItem(id: "system:\(c.id)", title: c.title.text, subtitle: c.subtitle, icon: .symbol(c.symbol, c.tint),
                           providerID: id, section: name,
                           accessory: String(localized: "System", comment: "Provider name and row label: system commands (lock, sleep, restart…)"),
                           score: score, primary: primary, keywords: c.title.englishTerms + c.keywords)
    }

    private func addressItems(macOnly: Bool, ipOnly: Bool) async -> [PaletteItem] {
        let addresses = await background { NetworkInfo.addresses() }
        return addresses.filter { macOnly ? $0.kind == "MAC" : ipOnly ? $0.kind != "MAC" : true }.enumerated().map { i, a in
            PaletteItem(id: "system:address:\(a.interface):\(a.value)", title: a.value,
                        subtitle: "\(a.kind) · \(a.displayName) (\(a.interface))",
                        icon: .symbol(a.kind == "MAC" ? "barcode" : "network", .blue), providerID: id,
                        section: String(localized: "Network", comment: "System Settings pane; use the name macOS shows"),
                        accessory: Labels.copy, score: 880 - Double(i),
                        primary: PaletteAction(id: "copy", title: Labels.copy,
                                               symbol: "doc.on.doc") {
                            Launch.copy(a.value)
                            HUD.show("Copied \(a.value)", symbol: "doc.on.doc")
                            return .dismiss
                        }, isPinnable: false)
        }
    }
}

/// The system-level operations behind the commands.
@MainActor
enum SystemActions {
    private static let log = Log.for("cmdpal")

    static func lockScreen() {
        // login.framework's SACLockScreenImmediate locks like the Control Center button does.
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        // Fallback: ⌃⌘Q, the system lock shortcut (needs Accessibility to post).
        KeySynth.tap(12, flags: [.maskControl, .maskCommand])
    }

    static func pmset(_ verb: String) {
        Task { _ = await AsyncProcess.run("/usr/bin/pmset", [verb], timeout: 10) }
    }

    static func killall(_ process: String) {
        Task { _ = await AsyncProcess.run("/usr/bin/killall", [process], timeout: 10) }
    }

    /// Sends a restart (`rest`), shut down (`shut`) or log out (`rlgo`) Apple event to loginwindow
    /// (Technical Q&A QA1134). These skip the system's own dialog; the palette confirms instead.
    static func loginwindow(_ event: String) {
        do {
            try AppleScript.run("tell application \"loginwindow\" to «event \(event)»")
        } catch {
            log.error("loginwindow \(event, privacy: .public): \(error.localizedDescription, privacy: .public)")
            HUD.show("Couldn’t send the command", symbol: "exclamationmark.triangle")
        }
    }

    static func emptyTrash() {
        do {
            try AppleScript.run("tell application \"Finder\" to empty trash")
            HUD.show("Trash emptied", symbol: "trash")
        } catch {
            log.error("Empty Trash: \(error.localizedDescription, privacy: .public)")
            HUD.show("Automation permission for Finder needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.automation)
        }
    }

    static func toggleDarkMode() {
        do {
            try AppleScript.run("""
            tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
            """)
        } catch {
            log.error("Dark mode: \(error.localizedDescription, privacy: .public)")
            HUD.show("Allow MacToys to control System Events", symbol: "exclamationmark.shield")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func toggleMute() {
        do {
            let muted = try AppleScript.run("output muted of (get volume settings)").booleanValue
            try AppleScript.run("set volume output muted \(!muted)")
            if muted { HUD.show("Sound on", symbol: "speaker.wave.2.fill") } else { HUD.show("Muted", symbol: "speaker.slash.fill") }
        } catch {
            log.error("Mute: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func missionControl(argument: String?) {
        let path = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            Launch.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            return
        }
        Task { _ = await AsyncProcess.run(path, argument.map { [$0] } ?? [], timeout: 5) }
    }

    static func ejectAll() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var ejected = 0
        for v in volumes {
            let values = try? v.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsEjectable == true || values?.volumeIsRemovable == true,
                  values?.volumeIsInternal != true, v.path != "/" else { continue }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: v)
                ejected += 1
            } catch {
                HUD.show("Couldn’t eject \(v.lastPathComponent)", symbol: "exclamationmark.triangle")
            }
        }
        if ejected > 0 { HUD.show("Ejected \(ejected) disks", symbol: "eject.fill") }
        else { HUD.show("No disks to eject", symbol: "eject") }
    }

    static func toggleHiddenFiles() {
        let shown = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
        Task {
            _ = await AsyncProcess.run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shown ? "false" : "true"])
            _ = await AsyncProcess.run("/usr/bin/killall", ["Finder"])
            if shown { HUD.show("Hidden files hidden", symbol: "eye.slash") } else { HUD.show("Hidden files shown", symbol: "eye") }
        }
    }
}
