import AppKit
import MacToysCore
import SwiftUI

/// Dashboard (`design/exports/02-settings-home.png`).
struct HomeView: View {
    @State private var registry = ModuleRegistry.shared
    @State private var permissions = PermissionCenter.shared
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all, on, off
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .on: "On"
            case .off: "Off"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                quickLaunch
                HStack(alignment: .top, spacing: 18) {
                    utilities
                    VStack(spacing: 18) {
                        permissionCard
                        aboutCard
                    }
                    .frame(width: 320)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var missingPermissions: [Permission] {
        let needed = Set(registry.modules.filter { registry.isEnabled($0.info.id) }.flatMap(\.info.permissions))
        return permissions.missing(Permission.allCases.filter { needed.contains($0) && !$0.isOptional })
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Home").font(.system(size: 24, weight: .bold)).kerning(-0.4)
                let n = missingPermissions.count
                Group {
                    if n > 0 {
                        Text("\(registry.enabledCount) of \(registry.modules.count) utilities are on · \(n) permissions need attention")
                    } else {
                        Text("\(registry.enabledCount) of \(registry.modules.count) utilities are on")
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back up settings") { BackupActions.backup() }
            Button("Open Command Palette") {
                ModuleRegistry.shared.dispatch(AppCommand(module: "cmdpal", action: "show"))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var quickLaunch: some View {
        let actions = Array(registry.quickActions.filter { $0.isOn == nil }.prefix(7))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Quick launch").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if actions.isEmpty {
                Text("Turn on a utility to see its actions here.").foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    ForEach(actions) { a in
                        Button(action: a.perform) {
                            VStack(alignment: .leading, spacing: 12) {
                                ModuleIcon(symbol: a.symbol, tint: a.tint, size: 30)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(verbatim: a.title).font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(2, reservesSpace: true)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let s = a.shortcut { Keycaps(s) } else {
                                        Text("Opens editor").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Utilities").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ForEach(ModuleCategory.allCases) { category in
                let mods = registry.modules(in: category).filter(include)
                if !mods.isEmpty {
                    Text(verbatim: category.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(mods, id: \.info.id) { m in UtilityRow(module: m) }
                }
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func include(_ m: any ToyModule) -> Bool {
        switch filter {
        case .all: true
        case .on: registry.isEnabled(m.info.id)
        case .off: !registry.isEnabled(m.info.id)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions").font(.system(size: 15, weight: .semibold))
                Text("macOS asks once per capability.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ForEach(Permission.allCases) { p in PermissionRow(permission: p) }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "MacToys \(AppInfo.version)").font(.system(size: 14, weight: .semibold))
                    Text("Feature parity with PowerToys 0.102").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Welcome tour") { WelcomeWindow.shared.show() }
                Button("General settings") { SettingsNavigation.shared.selection = .general }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

struct UtilityRow: View {
    let module: any ToyModule
    @State private var registry = ModuleRegistry.shared
    @State private var hovering = false

    var body: some View {
        let info = module.info
        HStack(spacing: 12) {
            ModuleIcon(info, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: info.name).fontWeight(.medium)
                Text(verbatim: info.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if let first = module.shortcutBindings.first(where: { !$0.keys.isEmpty }) { Keycaps(first.keys) }
            Toggle("", isOn: Binding(get: { registry.isEnabled(info.id) }, set: { registry.setEnabled(info.id, $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { SettingsNavigation.shared.selection = .module(info.id) }
    }
}

struct PermissionRow: View {
    let permission: Permission
    @State private var center = PermissionCenter.shared

    var body: some View {
        let ok = center.isGranted(permission)
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : permission.isOptional ? "circle.dashed" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : permission.isOptional ? .secondary : .orange)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: permission.title).fontWeight(.medium)
                Text(verbatim: permission.reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if !ok {
                Button("Grant") { center.request(permission) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

struct AppMark: View {
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.37, green: 0.36, blue: 0.9), Color(red: 1, green: 0.18, blue: 0.33),
                                          Color(red: 1, green: 0.58, blue: 0)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "puzzlepiece.extension.fill").font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }
}

@MainActor
enum BackupActions {
    static func backup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Back Up Here")
        panel.message = String(localized: "Choose a folder for the MacToys settings backup.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let dest = try SettingsStore.shared.backup(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func restore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Restore", comment: "Button: restore settings from the chosen backup folder")
        panel.message = String(localized: "Choose a MacToys settings backup folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsStore.shared.restore(from: url)
            let alert = NSAlert()
            alert.messageText = String(localized: "Settings restored")
            alert.informativeText = String(localized: "MacToys will relaunch to apply them.")
            alert.runModal()
            Relaunch.now()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
enum Relaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \(Shell.quote(path))"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
