import AppKit
import MacToysCore
import SwiftUI

/// Edits /etc/hosts: entries with on/off switches, validation, duplicates, ping, filters, header
/// comments, timestamped backups and a single administrator prompt per save.
@MainActor
public final class HostsEditorModule: ToyModule {
    public let info = ModuleInfo(
        id: "hosts", name: "Hosts File Editor",
        summary: "Edit /etc/hosts with validation, ping checks and automatic backups.",
        symbol: "server.rack", tint: .green, category: .advanced,
        permissions: [], enabledByDefault: true,
        keywords: ["hosts", "dns", "etc/hosts", "domain", "ip", "block", "localhost"])

    let settings = Persisted("hosts", default: HostsSettings())
    private(set) lazy var model = HostsEditorModel(settings: settings)
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    public init() {}

    public func start() {}

    public func stop() {
        window?.close()
        model.stopWatching()
        settings.flush()
    }

    func openWindow() {
        if window == nil {
            let controller = NSHostingController(rootView: HostsWindowView(model: model))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbar = NSToolbar(identifier: "hosts")
            w.toolbarStyle = .unified
            w.title = String(localized: "Hosts File Editor")
            w.setContentSize(NSSize(width: 940, height: 560))
            w.minSize = NSSize(width: 720, height: 380)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacToysHostsEditor")
            if w.frame.origin == .zero { w.center() }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.stopWatching() }
            }
            window = w
        }
        if !(window?.isVisible ?? false) {
            model.load()
            model.startWatching()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func settingsView() -> AnyView { AnyView(HostsSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "hosts.open", title: "Hosts File", symbol: "server.rack", tint: .green,
                     perform: { [weak self] in self?.openWindow() })]
    }

    /// `mactoys://hosts/<action>`: `open`/`show` (editor), `settings`, `textedit` (raw file).
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show": openWindow()
        case "settings": ModuleRegistry.shared.showSettings?(info.id)
        case "textedit":
            NSWorkspace.shared.open([URL(fileURLWithPath: "/private/etc/hosts")],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("window", size: CGSize(width: 940, height: 520), wallpaper: false) { AnyView(HostsWindowView.preview()) }]
    }
}

struct HostsSettingsView: View {
    let module: HostsEditorModule
    @Bindable var s: Persisted<HostsSettings>

    init(module: HostsEditorModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .green) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Map host names to addresses for this Mac").font(.system(size: 14, weight: .semibold))
                        Text("Saving asks for an administrator password once and flushes the DNS cache.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Hosts File Editor") { module.openWindow() }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Behavior") {
                Toggle(isOn: $s.value.showWarningOnStart) {
                    RowLabel("Show a warning at startup", subtitle: "Reminds you that hosts entries change name resolution for every app.")
                }
                Picker(selection: $s.value.placement) {
                    Text("Top", comment: "Placement of new hosts entries").tag(HostsDocument.Placement.top)
                    Text("Bottom", comment: "Placement of new hosts entries").tag(HostsDocument.Placement.bottom)
                } label: {
                    RowLabel("Placement of new entries", subtitle: "Top puts them after the header comments; bottom at the end of the file.")
                }
                Toggle(isOn: $s.value.loopbackDuplicates) {
                    RowLabel("Consider loopback addresses as duplicates",
                             subtitle: "Treat 127.0.0.1 and ::1 for the same host name as a duplicate.")
                }
                Toggle(isOn: $s.value.pingOnOpen) {
                    RowLabel("Ping entries when the editor opens", subtitle: "One packet per address, one second timeout.")
                }
            }

            Section("Backups") {
                Toggle(isOn: $s.value.backupsEnabled) {
                    RowLabel("Back up the hosts file before saving", subtitle: "Copies go to ~/Library/Application Support/MacToys/Hosts.")
                }
                Picker(selection: $s.value.retention) {
                    ForEach(HostsBackups.Retention.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Automatically delete backups")
                }
                .disabled(!s.value.backupsEnabled)
                if s.value.retention != .never {
                    Stepper(value: $s.value.backupCount, in: 1...100) {
                        RowLabel(title: s.value.retention == .count ? Text("Backups to keep") : Text("Always keep the newest"),
                                 subtitle: Text("\(s.value.backupCount) backups", comment: "Number of hosts file backups"))
                    }
                    .disabled(!s.value.backupsEnabled)
                }
                if s.value.retention == .ageAndCount {
                    Stepper(value: $s.value.backupDays, in: 1...365) {
                        RowLabel(title: Text("Delete backups older than"),
                                 subtitle: Text("\(s.value.backupDays) days", comment: "Age of hosts file backups"))
                    }
                    .disabled(!s.value.backupsEnabled)
                }
                HStack {
                    Button("Show Backups in Finder") { NSWorkspace.shared.open(module.model.backupDirectory) }
                    Button("Open Hosts in TextEdit") { _ = module.handle(AppCommand(module: "hosts", action: "textedit")) }
                    Spacer()
                }
            }

            Section {
                Text("There's no shortcut: open the editor from the MacToys menu, Settings or `open mactoys://hosts`. The file is saved as UTF-8 without a byte order mark, as macOS expects.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
