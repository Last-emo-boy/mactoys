import AppKit
import MacToysCore
import SwiftUI

struct GeneralView: View {
    @State private var registry = ModuleRegistry.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var cliInstalled = CLIInstaller.isInstalled

    var body: some View {
        @Bindable var general = registry.general
        Form {
            Section {
                HStack(spacing: 16) {
                    AppMark(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("General").font(.system(size: 24, weight: .bold)).kerning(-0.4)
                        Text("MacToys \(AppInfo.version) (\(AppInfo.build)) · \(registry.enabledCount) of \(registry.modules.count) utilities on")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section("Startup") {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled })) {
                    RowLabel("Open MacToys at login")
                }
                Toggle(isOn: $general.value.showMenuBarIcon) {
                    RowLabel("Show in menu bar", subtitle: "When hidden, open MacToys again from Finder or Spotlight to reach Settings.")
                }
            }

            Section {
                FlyoutPicker(title: Text("Tiles", comment: "Menu bar flyout: the grid of buttons at the top"),
                             kind: .tiles, general: general)
                FlyoutPicker(title: Text("Switches", comment: "Menu bar flyout: the on/off rows below the tiles"),
                             kind: .switches, general: general)
            } header: {
                Text("Menu bar flyout")
            } footer: {
                Text("Switches you don't pick stay one click away under More Switches.")
            }

            Section("Language") {
                LanguagePicker { Relaunch.now() }
            }

            Section("Appearance") {
                Picker(selection: $general.value.appearance) {
                    Text("System").tag(GeneralSettings.Appearance.system)
                    Text("Light").tag(GeneralSettings.Appearance.light)
                    Text("Dark").tag(GeneralSettings.Appearance.dark)
                } label: { RowLabel("Settings appearance") }
                .pickerStyle(.segmented)
            }

            Section("Permissions") {
                ForEach(Permission.allCases) { p in PermissionRow(permission: p).padding(.horizontal, -16) }
            }

            Section("Command-line tool") {
                LabeledContent {
                    if cliInstalled {
                        Button("Uninstall") { CLIInstaller.uninstall(); cliInstalled = CLIInstaller.isInstalled }
                    } else {
                        Button("Install") { CLIInstaller.install(); cliInstalled = CLIInstaller.isInstalled }
                    }
                } label: {
                    RowLabel(title: Text(verbatim: "mactoys"),
                             subtitle: cliInstalled ? Text("Linked at \(CLIInstaller.linkPath)")
                                 : Text("Adds `mactoys` to \(CLIInstaller.linkPath) for scripting utilities from Terminal."))
                }
            }

            Section("Shortcuts") {
                let conflicts = ShortcutAudit.conflicts()
                if conflicts.isEmpty {
                    Label("No shortcut conflicts", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(conflicts, id: \.self) { c in
                        Label { Text(verbatim: c) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Backup") {
                LabeledContent {
                    HStack {
                        Button("Back Up…") { BackupActions.backup() }
                        Button("Restore…") { BackupActions.restore() }
                    }
                } label: {
                    RowLabel("Settings backup", verbatimSubtitle: Paths.settings.path)
                }
                LabeledContent {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Paths.appSupport]) }
                } label: {
                    RowLabel("Data folder", verbatimSubtitle: Paths.appSupport.path)
                }
            }

            Section("About") {
                LabeledContent("Welcome tour") { Button("Show") { WelcomeWindow.shared.show() } }
                LabeledContent("Quit MacToys") { Button("Quit") { NSApp.terminate(nil) } }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Finds duplicate bindings and shortcuts other apps already own.
@MainActor
enum ShortcutAudit {
    static func conflicts() -> [String] {
        var out: [String] = []
        let bindings = HotkeyCenter.shared.bindings
        var seen: [Shortcut: String] = [:]
        for (id, s) in bindings.sorted(by: { $0.key < $1.key }) {
            if let other = seen[s] {
                out.append(String(localized: "\(s.description) is bound to both \(other) and \(id)"))
            } else {
                seen[s] = id
            }
        }
        for id in HotkeyCenter.shared.failed.sorted() {
            if let s = bindings[id] {
                out.append(String(localized: "\(s.description) for \(id) is already used by another app"))
            }
        }
        return out
    }
}

/// Symlinks the bundled CLI into /usr/local/bin (asks for an administrator password).
@MainActor
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/mactoys"
    static var bundled: String { Bundle.main.bundlePath + "/Contents/Helpers/mactoys" }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundled
    }

    static func install() {
        let cmd = "mkdir -p /usr/local/bin && ln -sf \(Shell.quote(bundled)) \(Shell.quote(linkPath))"
        do { _ = try Privileged.run(cmd, prompt: String(localized: "MacToys wants to install the mactoys command-line tool.")) }
        catch { NSAlert(error: error).runModal() }
    }

    static func uninstall() {
        do {
            _ = try Privileged.run("rm -f \(Shell.quote(linkPath))",
                                   prompt: String(localized: "MacToys wants to remove the mactoys command-line tool."))
        }
        catch { NSAlert(error: error).runModal() }
    }
}

/// Chooses which quick actions the menu bar flyout shows (`GeneralSettings.menuBarTiles` / `menuBarSwitches`).
private struct FlyoutPicker: View {
    enum Kind { case tiles, switches }
    let title: Text
    let kind: Kind
    @Bindable var general: Persisted<GeneralSettings>
    @State private var registry = ModuleRegistry.shared

    var body: some View {
        let layout = FlyoutLayout(actions: registry.quickActions, general: general.value)
        let shown = kind == .tiles ? layout.tiles : layout.switches
        let more = kind == .tiles ? layout.moreTiles : layout.moreSwitches
        DisclosureGroup {
            ForEach(shown + more) { action in
                Toggle(isOn: Binding(get: { shown.contains { $0.id == action.id } },
                                     set: { set(action.id, on: $0, shown: shown) })) {
                    Label {
                        Text(verbatim: action.title)
                    } icon: {
                        ModuleIcon(symbol: action.symbol, tint: action.tint, size: 20)
                    }
                }
            }
            Button(String(localized: "Use Defaults", comment: "Menu bar flyout: go back to the standard tiles or switches")) {
                if kind == .tiles { general.value.menuBarTiles = nil } else { general.value.menuBarSwitches = nil }
            }
        } label: {
            LabeledContent {
                Text("\(shown.count) of \(shown.count + more.count)", comment: "How many tiles or switches the flyout shows, of how many there are")
                    .monospacedDigit()
            } label: { title }
        }
    }

    private func set(_ id: String, on: Bool, shown: [QuickAction]) {
        let list = QuickAccessLayout.toggling(id, on: on, shown: shown.map(\.id))
        if kind == .tiles { general.value.menuBarTiles = list } else { general.value.menuBarSwitches = list }
    }
}
