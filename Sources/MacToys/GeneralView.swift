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
                    RowLabel("mactoys", subtitle: cliInstalled ? "Linked at \(CLIInstaller.linkPath)"
                             : "Adds `mactoys` to \(CLIInstaller.linkPath) for scripting utilities from Terminal.")
                }
            }

            Section("Shortcuts") {
                let conflicts = ShortcutAudit.conflicts()
                if conflicts.isEmpty {
                    Label("No shortcut conflicts", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(conflicts, id: \.self) { c in
                        Label(c, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
                    RowLabel("Settings backup", subtitle: Paths.settings.path)
                }
                LabeledContent {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Paths.appSupport]) }
                } label: {
                    RowLabel("Data folder", subtitle: Paths.appSupport.path)
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
            if let other = seen[s] { out.append("\(s) is bound to both \(other) and \(id)") } else { seen[s] = id }
        }
        for id in HotkeyCenter.shared.failed.sorted() {
            if let s = bindings[id] { out.append("\(s) for \(id) is already used by another app") }
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
        do { _ = try Privileged.run(cmd, prompt: "MacToys wants to install the mactoys command-line tool.") }
        catch { NSAlert(error: error).runModal() }
    }

    static func uninstall() {
        do { _ = try Privileged.run("rm -f \(Shell.quote(linkPath))", prompt: "MacToys wants to remove the mactoys command-line tool.") }
        catch { NSAlert(error: error).runModal() }
    }
}
