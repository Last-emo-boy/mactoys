import AppKit
import MacToysCore
import SwiftUI

/// The File Locksmith window (`design/exports/07-tool-windows.png`).
struct FileLocksmithView: View {
    @Bindable var model: FileLocksmithModel
    /// Draw a fake title bar (offscreen previews) instead of using the window toolbar.
    var chrome = false
    /// Icons for previews, by process name.
    var sampleIcons: [String: (String, Tint)] = [:]

    var body: some View {
        if chrome {
            HostedToolWindowChrome(title: String(localized: "File Locksmith"), symbol: "lock.doc.fill", tint: .yellow) {
                toolbarButtons
            } content: {
                main
            }
        } else {
            main
                .toolbar {
                    ToolbarItem(placement: .navigation) { ModuleIcon(symbol: "lock.doc.fill", tint: .yellow, size: 20) }
                    ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
                }
        }
    }

    @ViewBuilder private var toolbarButtons: some View {
        Button { model.refresh() } label: { Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
            .help("Scan again")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.scanning)
        if model.elevated {
            Label("Administrator", systemImage: "lock.open.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("Showing the processes of every user")
        } else {
            Button("Restart as Administrator") { model.scanAsAdministrator() }
                .help("Scan the processes of every user with administrator privileges")
                .disabled(model.scanning)
        }
    }

    private var main: some View {
        VStack(spacing: 10) {
            pathBar
            if let error = model.lastError {
                InfoBar(.error, title: Text("Something went wrong"), message: Text(verbatim: error))
            }
            if model.processes.isEmpty {
                Group {
                    if model.scanning {
                        ProgressView("Scanning processes…")
                    } else {
                        ContentUnavailableView {
                            Label {
                                model.paths.count == 1 ? Text("Nothing is using this item") : Text("Nothing is using these items")
                            } icon: {
                                Image(systemName: "lock.open")
                            }
                        } description: {
                            model.inaccessible > 0 && !model.elevated
                                ? Text("Processes of other users weren’t checked. Restart as administrator to include them.")
                                : Text("No process has these files open or uses these folders.")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.processes) { p in
                            ProcessCard(model: model, process: p, sampleIcon: sampleIcons[p.name])
                        }
                    }
                }
            }
            if model.inaccessible > 0, !model.elevated, !model.processes.isEmpty {
                Text("\(model.inaccessible) processes of other users weren’t checked.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isFolder || model.paths.count > 1 ? "folder" : "doc")
                .foregroundStyle(Color.accentColor)
            Text(verbatim: model.pathTitle)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .help(model.paths.map(\.path).joined(separator: "\n"))
            Spacer()
            if model.scanning && !model.processes.isEmpty { ProgressView().controlSize(.small) }
            Text("\(model.processes.count) processes")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

private struct ProcessCard: View {
    let model: FileLocksmithModel
    let process: LockingProcess
    let sampleIcon: (String, Tint)?

    var body: some View {
        let expanded = model.expanded.contains(process.pid)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if expanded { model.expanded.remove(process.pid) } else { model.expanded.insert(process.pid) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        icon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: process.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(verbatim: model.subtitle(process))
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                actions
            }
            .padding(10)
            if expanded {
                Divider().padding(.leading, 10)
                VStack(alignment: .leading, spacing: 4) {
                    if let exe = process.executablePath {
                        detail(String(localized: "Program", comment: "File Locksmith: label of the process’s program path; keep it short"),
                               FileLocksmithModel.abbreviate(exe))
                    }
                    ForEach(Array(process.files.enumerated()), id: \.offset) { _, f in
                        detail(badge(f), model.displayPath(f.path), full: f.path)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }

    @ViewBuilder private var actions: some View {
        if !model.canEnd(process) {
            (process.pid == getpid() ? Text(verbatim: "MacToys")
                                     : Text("System", comment: "File Locksmith: shown instead of End process for system processes"))
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        } else if model.stuck.contains(process.pid) {
            Button("Force Quit") { model.forceQuit(process) }
                .buttonStyle(EndButtonStyle(strong: true))
                .help("Ends the process immediately. Unsaved work is lost.")
        } else if model.ending[process.pid] != nil {
            ProgressView().controlSize(.small)
        } else {
            Button("End process") { model.end(process) }
                .buttonStyle(EndButtonStyle(strong: false))
        }
    }

    @ViewBuilder private var icon: some View {
        if let sampleIcon {
            ModuleIcon(symbol: sampleIcon.0, tint: sampleIcon.1, size: 30)
        } else if let image = ProcessIcons.icon(for: process) {
            Image(nsImage: image).resizable().frame(width: 30, height: 30)
        } else {
            ModuleIcon(symbol: ProcessIcons.isShell(process) ? "apple.terminal.fill" : "cpu", tint: .graphite, size: 30)
        }
    }

    private func badge(_ f: LockedFile) -> String {
        switch f.kind {
        case .openFile:
            f.descriptor.map { String(localized: "fd \(String($0))", comment: "File Locksmith badge: open file descriptor number (Unix term, as lsof shows it); keep it short") }
                ?? String(localized: "open", comment: "File Locksmith badge: an open file; keep it short")
        case .workingDirectory: String(localized: "cwd", comment: "File Locksmith badge: the process’s current working directory (Unix term, as lsof shows it); keep it short")
        case .rootDirectory: String(localized: "root", comment: "File Locksmith badge: the process’s root directory (chroot, as lsof shows it); keep it short")
        case .executable: String(localized: "mapped", comment: "File Locksmith badge: the program or a library mapped into memory; keep it short")
        }
    }

    private func detail(_ label: String, _ value: String, full: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .leading)
                .fixedSize()
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .help(full ?? value)
            Spacer(minLength: 0)
            if let full {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                } label: { Image(systemName: "magnifyingglass.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
    }
}

/// The red "End process" pill from the design.
private struct EndButtonStyle: ButtonStyle {
    let strong: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(strong ? Color.white : Color.red)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(strong ? Color.red : Color.red.opacity(configuration.isPressed ? 0.2 : 0.1)))
    }
}

/// App icons for processes, cached by path.
@MainActor
enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for p: LockingProcess) -> NSImage? {
        if let app = NSRunningApplication(processIdentifier: p.pid), let icon = app.icon { return icon }
        guard let exe = p.executablePath, let range = exe.range(of: ".app/", options: .backwards) else { return nil }
        let bundle = String(exe[..<range.lowerBound]) + ".app"
        if let cached = cache[bundle] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = icon
        return icon
    }

    static func isShell(_ p: LockingProcess) -> Bool {
        ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "nu", "login"].contains(p.name.lowercased())
            || p.name.lowercased().hasPrefix("-")
    }
}
