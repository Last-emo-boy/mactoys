import AppKit
import MacToysCore
import SwiftUI

public struct FileLocksmithSettings: Codable, Equatable, Sendable {
    /// Read by the Finder extension (`MacToys › What’s using this file?`).
    public var showInFinderMenu = true
    /// Only show the Finder menu item while ⌥ is held (Windows' extended context menu).
    public var finderMenuNeedsOption = false
    /// Optional shortcut that checks the Finder selection.
    public var activation: Shortcut?

    public init() {}
}

/// Shows which processes use files and folders, and ends them.
///
/// URL actions: `open` (files, or the Finder selection when none are given), `admin` (same, scanning
/// every user's processes after the administrator prompt), `settings`.
@MainActor
public final class FileLocksmithModule: ToyModule {
    public let info = ModuleInfo(
        id: "filelocksmith", name: "File Locksmith",
        summary: "See which processes are using a file or folder, and end them.",
        symbol: "lock.doc.fill", tint: .yellow, category: .fileManagement,
        permissions: [.fullDiskAccess], enabledByDefault: true,
        keywords: ["lock", "in use", "busy", "open files", "lsof", "unlock", "process", "eject"])

    let settings = Persisted("filelocksmith", default: FileLocksmithSettings())
    private var windows: [HostedToolWindow] = []
    private var running = false
    private static let hotkeyID = "filelocksmith.open"

    public init() {
        settings.onChange { [weak self] _ in self?.registerHotkey() }
    }

    public func start() {
        running = true
        registerHotkey()
    }

    public func stop() {
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        for w in windows { w.close() }
        windows.removeAll()
    }

    private func registerHotkey() {
        guard running else { return }
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activation) { [weak self] in
            self?.openWithFinderSelection()
        }
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "filelocksmith.open", title: "What’s Using This?", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.activation) { [weak self] in self?.openWithFinderSelection() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        settings.value.activation.map { [ShortcutBinding("What’s using the Finder selection", $0)] } ?? []
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "open", "show", "admin":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            let files = command.files.isEmpty ? FinderSelection.selectedURLs() : command.files
            open(files, elevated: command.action == "admin")
        default:
            return false
        }
        return true
    }

    func openWithFinderSelection() {
        open(FinderSelection.selectedURLs())
    }

    func open(_ urls: [URL], elevated: Bool = false) {
        guard !urls.isEmpty else {
            HUD.show("Select files or folders in Finder first", symbol: "lock.doc")
            return
        }
        let model = FileLocksmithModel(paths: urls)
        let window = HostedToolWindow(title: "File Locksmith", size: CGSize(width: 580, height: 460),
                                      minSize: CGSize(width: 460, height: 300), autosaveName: "MacToys.FileLocksmith",
                                      content: FileLocksmithView(model: model).frame(minWidth: 460, minHeight: 300))
        window.onClose = { [weak self, weak window] in
            model.deactivate()
            self?.windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.show()
        model.activate(elevated: elevated)
    }

    // MARK: Settings

    public func settingsView() -> AnyView {
        AnyView(FileLocksmithSettingsView(module: self))
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [PreviewScene("window", size: CGSize(width: 580, height: 420), wallpaper: false) {
            AnyView(FileLocksmithView(model: Self.sampleModel(), chrome: true,
                                      sampleIcons: ["Xcode": ("hammer.fill", .blue), "zsh": ("apple.terminal.fill", .graphite),
                                                    "swift-frontend": ("cpu", .graphite)]))
        }]
    }

    static func sampleModel() -> FileLocksmithModel {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/mactoys/build").path
        func files(_ names: [String]) -> [LockedFile] {
            names.enumerated().map { LockedFile(path: root + "/" + $1, kind: .openFile, descriptor: Int32(12 + $0)) }
        }
        let user = NSUserName()
        let processes = [
            LockingProcess(pid: 4182, name: "Xcode", executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode", uid: 501,
                           user: user, startTime: 0,
                           files: files(["DerivedData/Build.db", "DerivedData/Build.db-wal", "DerivedData/Build.db-shm",
                                         "DerivedData/Logs/Build/LogStoreManifest.plist", "Index.noindex/DataStore/v5/units",
                                         "Index.noindex/DataStore/v5/records", "MacToys.build/Objects-normal/arm64/MacToys.swiftdeps"])),
            LockingProcess(pid: 9921, name: "zsh", executablePath: "/bin/zsh", uid: 501, user: user, startTime: 0,
                           files: [LockedFile(path: root, kind: .workingDirectory)]),
            LockingProcess(pid: 10233, name: "swift-frontend", executablePath: "/usr/bin/swift-frontend", uid: 501, user: user,
                           startTime: 0, files: files(["MacToys.o", "MacToys.swiftmodule"])),
        ]
        let model = FileLocksmithModel(sample: [URL(fileURLWithPath: root, isDirectory: true)], processes: processes, inaccessible: 41)
        model.expanded = [10233]
        return model
    }
}

private struct FileLocksmithSettingsView: View {
    let module: FileLocksmithModule
    @Bindable var settings: Persisted<FileLocksmithSettings>

    init(module: FileLocksmithModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .yellow) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find out what’s using a file").font(.headline)
                        Text("Select files or folders in Finder and choose MacToys › What’s using this file? Folders are checked with everything inside them.")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Choose…") { choose() }
                    Button("Check Finder Selection") { module.openWithFinderSelection() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Finder") {
                Toggle(isOn: $settings.value.showInFinderMenu) {
                    RowLabel("Show File Locksmith in the Finder menu", subtitle: "Under MacToys in the context menu of selected items.")
                }
                Toggle(isOn: $settings.value.finderMenuNeedsOption) {
                    RowLabel("Only while holding ⌥ Option", subtitle: "Like Windows’ extended context menu.")
                }
                .disabled(!settings.value.showInFinderMenu)
                ShortcutRow("Check the Finder selection", subtitle: "Optional.", shortcut: $settings.value.activation)
            }
            Section("About scanning") {
                LabeledContent {
                    EmptyView()
                } label: {
                    RowLabel("Your processes are checked without asking",
                             subtitle: "Other users’ and system processes need administrator access: use Restart as Administrator in the window. Processes that exit disappear from the list by themselves.")
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Check"
        if panel.runModal() == .OK { module.open(panel.urls) }
    }
}
