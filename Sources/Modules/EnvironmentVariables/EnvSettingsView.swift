import AppKit
import MacToysCore
import SwiftUI

struct EnvSettingsView: View {
    let module: EnvironmentVariablesModule
    @Bindable var s: Persisted<EnvSettings>
    @Bindable var editor: EnvEditorState
    @State private var confirmUninstall = false

    init(module: EnvironmentVariablesModule) {
        self.module = module
        self.s = module.settings
        self.editor = module.editor
    }

    var body: some View {
        let applier = module.applier
        SettingsPage(module: module) {
            HeroCard(tint: .graphite) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profiles and User variables for zsh and apps").font(.system(size: 14, weight: .semibold))
                        Text(status(installed: applier.isInstalled)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Environment Variables") { module.openWindow() }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Apply to") {
                Toggle(isOn: Binding(get: { s.value.applyToLaunchd }, set: { s.value.applyToLaunchd = $0; reapply() })) {
                    RowLabel("Apps opened from the Dock and Finder",
                             subtitle: "Sets the variables with launchctl now and at every login through ~/Library/LaunchAgents/com.w33d.mactoys.envvars.plist. Apps already running keep their environment.")
                }
                Toggle(isOn: Binding(get: { s.value.keepPathOrderInLoginShells }, set: { s.value.keepPathOrderInLoginShells = $0; reapply() })) {
                    RowLabel("Keep PATH order in login shells",
                             subtitle: "macOS's path_helper (/etc/zprofile) moves system folders to the front in Terminal's login shells. This re-applies PATH-like variables from ~/.zprofile afterwards.")
                }
            }

            Section("Files") {
                fileRow(Text(verbatim: "~/.zshenv"),
                        detail: applier.isInstalled ? Text("Contains the MacToys block") : Text("Not modified"), url: applier.zshenv)
                fileRow(Text(verbatim: "env.zsh"), detail: Text("The exports MacToys generates"), url: applier.envFile)
                fileRow(Text("Login agent"),
                        detail: FileManager.default.fileExists(atPath: applier.launchAgent.path)
                            ? Text("Installed", comment: "The login agent file exists") : Text("Not installed", comment: "The login agent file doesn't exist"),
                        url: applier.launchAgent)
                fileRow(Text("Backups"), detail: Text("Copies of startup files from before MacToys first changed them"),
                        url: applier.backupDirectory)
                HStack {
                    Button("Remove MacToys from Startup Files…") { confirmUninstall = true }
                    Spacer()
                }
                if let m = editor.message {
                    InfoBar(m.kind, title: m.kind == .error ? Text("Something went wrong") : Text("Done"), message: Text(verbatim: m.text),
                            actionTitle: Text("Dismiss")) { editor.message = nil }
                }
            }

            Section {
                Text("MacToys edits only your own variables. System-wide files (/etc/zshenv, /etc/paths, /etc/paths.d) are shown read-only in the editor's Effective view; changing them needs an administrator and is left to you. Turning this utility off keeps applied variables in place.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Remove MacToys from your shell startup files?", isPresented: $confirmUninstall) {
            Button("Remove", role: .destructive) { module.uninstall() }
        } message: {
            Text("The managed blocks in ~/.zshenv and ~/.zprofile, env.zsh and the login agent are removed, and launchd variables are restored. Your profiles stay saved in MacToys.")
        }
    }

    private func status(installed: Bool) -> String {
        let count = module.effective.count
        guard installed, s.value.lastApplied != nil else { return String(localized: "Nothing applied yet") }
        var parts = [String(localized: "\(count) variables applied", comment: "Environment Variables status")]
        parts.append(s.value.applied.map { String(localized: "profile \($0.name)", comment: "Environment Variables status: the applied profile") }
                     ?? String(localized: "no profile", comment: "Environment Variables status: no profile is applied"))
        if module.hasUnappliedChanges { parts.append(String(localized: "unapplied changes", comment: "Environment Variables status")) }
        return parts.joined(separator: " · ")
    }

    private func reapply() {
        if s.value.lastApplied != nil { module.apply() }
    }

    private func fileRow(_ title: Text, detail: Text, url: URL) -> some View {
        LabeledContent {
            Button("Show in Finder") {
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
            .controlSize(.small)
        } label: {
            RowLabel(title: title, subtitle: detail)
        }
    }
}
