import MacToysCore
import SwiftUI

struct WorkspacesSettingsView: View {
    let module: WorkspacesModule

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .blue) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save the apps and windows you use together, then bring them all back with one click.")
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Each workspace remembers where every window goes on each display, and can open files, folders or URLs with its apps.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Launch editor") { module.openEditor() }
                                .buttonStyle(.borderedProminent)
                            Keycaps(s.value.editorShortcut)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    MiniLayout()
                        .frame(width: 150, height: 92)
                }
            }
        } content: {
            Section("Workspaces") {
                if s.value.workspaces.isEmpty {
                    Text("No workspaces yet. Open the editor and capture the windows on your screen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(s.value.workspaces) { ws in
                        HStack(spacing: 10) {
                            HStack(spacing: -6) {
                                ForEach(Array(Set(ws.apps.map(\.appPath))).sorted().prefix(3), id: \.self) { path in
                                    Image(nsImage: AppIcons.icon(path: path)).resizable().frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: 52, alignment: .leading)
                            RowLabel(ws.name, subtitle: WorkspaceText.summary(of: ws))
                            Spacer()
                            if let sc = ws.shortcut { Keycaps(sc) }
                            Button { module.openEditor(selecting: ws.id) } label: {
                                Text("Edit", comment: "Button: edit the workspace")
                            }
                            Button { module.launch(ws.id) } label: {
                                Text("Launch", comment: "Button: launch the workspace")
                            }
                        }
                    }
                }
                if s.value.workspaces.contains(where: \.launchAtLogin) && !LoginItem.isEnabled {
                    InfoBar(.warning, title: "MacToys doesn't open at login",
                            message: "Workspaces set to launch at login run when MacToys starts as you log in.",
                            actionTitle: "Open at Login") { LoginItem.set(true) }
                }
            }
            Section("Activation") {
                ShortcutRow("Editor shortcut", subtitle: "Opens the Workspaces editor", shortcut: $s.value.editorShortcut)
            }
            Section("Launching") {
                Toggle(isOn: $s.value.moveExistingByDefault) {
                    RowLabel("Move existing windows in new workspaces",
                             subtitle: "Apps that are already open have their windows moved instead of opening new ones")
                }
                SliderRow("Wait for windows", subtitle: "How long to wait for a launched app's windows to appear",
                          value: $s.value.windowTimeout, in: 5...60, step: 5) {
                    Duration.seconds(Int($0)).formatted(.units(allowed: [.seconds], width: .narrow))
                }
                Toggle(isOn: $s.value.showProgress) {
                    RowLabel("Show launch progress", subtitle: "A small window lists each app as it launches and moves into place")
                }
                Toggle(isOn: $s.value.closeProgressWhenDone) {
                    RowLabel("Close it when every window is in place")
                }
                .disabled(!s.value.showProgress)
            }
            Section("Other ways to launch") {
                LabeledContent {
                    Text(verbatim: "mactoys://workspaces/launch?name=…")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    RowLabel("URL", subtitle: "From scripts, Shortcuts or other apps")
                }
                Text("In the editor, Create Shortcut saves a small app you can keep in the Dock, a web location or a shell script that launches the workspace.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A tiny drawing of a saved layout for the hero card.
private struct MiniLayout: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.12))
            tile(Tint.blue, x: 8, y: 8, w: 80, h: 76)
            tile(Tint.graphite, x: 92, y: 8, w: 50, h: 36)
            tile(Tint.teal, x: 92, y: 48, w: 50, h: 36)
        }
    }

    private func tile(_ tint: Tint, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.color)
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }
}
