import AppKit
import MacToysCore
import Observation
import SwiftUI

struct CNFSettings: Codable, Equatable {
    /// Refresh the index once a week while the utility is on.
    var autoUpdate = true
    var lastDigest: String?
    var lastSource: String?
}

/// What the settings page shows.
@MainActor
@Observable
final class CNFState {
    var brewPath: String?
    var zshrc: URL?
    var installed = false
    var installedHelper: String?
    var currentHelper: String?
    var otherHandlers = false
    var indexFormulae = 0
    var indexDate: Date?
    var updating = false
    var message: (kind: InfoKind, text: String)?
}

/// Suggests the Homebrew formula to install when a zsh command isn't found, through a managed
/// `command_not_found_handler` in ~/.zshrc and a cached copy of Homebrew's executables database.
@MainActor
public final class CommandNotFoundModule: ToyModule {
    public let info = ModuleInfo(
        id: "cmdnotfound", name: "Command Not Found",
        summary: "Suggests the Homebrew package to install when a zsh command is missing.",
        symbol: "terminal.fill", tint: .graphite, category: .systemTools,
        permissions: [], enabledByDefault: false,
        keywords: ["homebrew", "brew", "zsh", "shell", "terminal", "missing command", "install"])

    let settings = Persisted("cmdnotfound", default: CNFSettings())
    let state = CNFState()
    private let log = Log.for("cmdnotfound")
    private var timer: Timer?
    private var running = false

    static let refreshInterval: TimeInterval = 7 * 86400

    public init() {}

    /// The shell block stays installed while the utility is off: `mactoys cnf` then answers with
    /// zsh's plain message. Uninstall removes it.
    public func start() {
        guard !running else { return }
        running = true
        refreshStatus()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIfStale() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.updateIfStale() }
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        settings.flush()
    }

    // MARK: - Status

    func refreshStatus() {
        Task.detached {
            let zshrc = CNFPaths.zshrc()
            let text = (try? String(contentsOf: zshrc.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
            let helper = CNFPaths.helper()
            let brew = CNFPaths.brew
            let indexText = try? String(contentsOf: CNFPaths.index, encoding: .utf8)
            let count = indexText.map(CNFIndex.formulaCount) ?? 0
            let date = (try? FileManager.default.attributesOfItem(atPath: CNFPaths.index.path))?[.modificationDate] as? Date
            await MainActor.run {
                self.state.zshrc = zshrc
                self.state.installed = CNFShell.block.contains(text)
                self.state.installedHelper = CNFShell.installedHelper(in: text)
                self.state.otherHandlers = CNFShell.otherHandlers(in: text)
                self.state.currentHelper = helper
                self.state.brewPath = brew
                self.state.indexFormulae = count
                self.state.indexDate = indexText == nil ? nil : date
            }
        }
    }

    private func updateIfStale() {
        guard running, settings.value.autoUpdate, !state.updating else { return }
        let date = (try? FileManager.default.attributesOfItem(atPath: CNFPaths.index.path))?[.modificationDate] as? Date
        if let date, Date().timeIntervalSince(date) < Self.refreshInterval { return }
        updateIndex(quiet: true)
    }

    func updateIndex(quiet: Bool = false) {
        guard !state.updating else { return }
        state.updating = true
        let known = settings.value.lastDigest
        Task {
            do {
                let result = try await CNFUpdater.update(knownDigest: known)
                settings.update { $0.lastDigest = result.digest; $0.lastSource = result.source }
                if !quiet {
                    let source = CNFUpdater.sourceTitle(result.source)
                    state.message = (.success, result.unchanged
                                     ? String(localized: "The index is up to date (\(result.formulae) formulae).",
                                              comment: "Homebrew database; formulae are Homebrew packages")
                                     : String(localized: "Updated from \(source): \(result.formulae) formulae.",
                                              comment: "First a source such as GitHub Packages, then a number of Homebrew packages"))
                }
                log.info("index updated from \(result.source, privacy: .public)")
            } catch {
                if !quiet { state.message = (.error, error.localizedDescription) }
                log.error("index update failed: \(error.localizedDescription, privacy: .public)")
            }
            state.updating = false
            refreshStatus()
        }
    }

    // MARK: - Install

    func install() {
        guard let helper = CNFPaths.helper() else {
            state.message = (.error, String(localized: "Couldn't find MacToys.app's command-line helper. Move MacToys to /Applications or ~/Applications and try again."))
            return
        }
        edit { CNFShell.block.insert(CNFShell.handlerLines(helper: helper), into: $0) }
        if state.indexFormulae == 0 { updateIndex(quiet: true) }
    }

    func uninstall() {
        edit { CNFShell.block.remove(from: $0) }
    }

    /// Rewrites ~/.zshrc in place (symlinks followed), backing it up once.
    private func edit(_ transform: @escaping (String) -> String) {
        let zshrc = (state.zshrc ?? CNFPaths.zshrc()).resolvingSymlinksInPath()
        do {
            let exists = FileManager.default.fileExists(atPath: zshrc.path)
            let original = exists ? try String(contentsOf: zshrc, encoding: .utf8) : ""
            let updated = transform(original)
            guard updated != original else { refreshStatus(); return }
            if exists {
                let backup = Paths.data(for: "cmdnotfound").appendingPathComponent("zshrc-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: zshrc, to: backup)
                }
                let handle = try FileHandle(forWritingTo: zshrc)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data(updated.utf8))
            } else {
                try Data(updated.utf8).write(to: zshrc)
            }
            let path = zshrc.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            state.message = (.success, CNFShell.block.contains(updated)
                             ? String(localized: "Installed. Open a new terminal window (or run exec zsh) to use it.", comment: "exec zsh is a command")
                             : String(localized: "Removed from \(path).", comment: "The placeholder is a file path"))
        } catch {
            state.message = (.error, String(localized: "Couldn't edit \(zshrc.path): \(error.localizedDescription)",
                                            comment: "First a file path, then the system's error message"))
        }
        refreshStatus()
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView { AnyView(CNFSettingsView(module: self)) }

    /// `mactoys://cmdnotfound/<action>`: `install`, `uninstall`, `update` (index), `open`/`settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "settings", "show": ModuleRegistry.shared.showSettings?(info.id)
        case "install": install()
        case "uninstall": uninstall()
        case "update": updateIndex()
        default: return false
        }
        return true
    }
}

struct CNFSettingsView: View {
    let module: CommandNotFoundModule
    @Bindable var s: Persisted<CNFSettings>
    @Bindable var state: CNFState
    @State private var tryCommand = "wget"

    init(module: CommandNotFoundModule) {
        self.module = module
        self.s = module.settings
        self.state = module.state
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .graphite) {
                HStack(spacing: 14) {
                    Image(systemName: state.installed ? "checkmark.seal.fill" : "terminal")
                        .font(.system(size: 22)).foregroundStyle(state.installed ? .green : .secondary).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        (state.installed ? Text("Installed in zsh") : Text("Not installed", comment: "The zsh handler isn't installed"))
                            .font(.system(size: 14, weight: .semibold))
                        (state.zshrc.map { Text("Managed block in \($0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                                                comment: "The placeholder is a file path such as ~/.zshrc") } ?? Text("Checking…"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.installed {
                        if state.installedHelper != nil && state.currentHelper != nil && state.installedHelper != state.currentHelper {
                            Button("Update Path") { module.install() }
                        }
                        Button("Uninstall") { module.uninstall() }
                    } else {
                        Button("Install") { module.install() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        } content: {
            if let m = state.message {
                Section {
                    InfoBar(m.kind, title: m.kind == .error ? Text("Something went wrong") : Text("Done"), message: Text(verbatim: m.text),
                            actionTitle: Text("Dismiss")) { state.message = nil }
                }
            }
            if state.installed && state.installedHelper != nil && state.currentHelper != nil && state.installedHelper != state.currentHelper {
                Section {
                    InfoBar(.warning, title: "MacToys moved",
                            message: "The handler points at \(state.installedHelper ?? ""). Update it to use this copy.",
                            actionTitle: "Update Path") { module.install() }
                }
            }

            Section("Status") {
                LabeledContent {
                    if let brew = state.brewPath {
                        Text(verbatim: brew).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                    }
                } label: {
                    RowLabel(title: Text(verbatim: "Homebrew"),
                             subtitle: state.brewPath == nil ? Text("Not found. Suggestions still work; install Homebrew to use them.")
                                 : Text("Found", comment: "Homebrew is installed"))
                }
                LabeledContent {
                    ((state.installedHelper ?? state.currentHelper).map { Text(verbatim: $0) } ?? Text("Not found", comment: "The helper tool wasn't found"))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .trailing)
                } label: {
                    RowLabel("Helper", subtitle: "Called by zsh's command_not_found_handler.")
                }
                if state.otherHandlers {
                    InfoBar(.info, title: "Another command-not-found handler is set up",
                            message: "Your .zshrc also loads one (for example Homebrew's `brew command-not-found-init`). The MacToys block comes last, so it wins.")
                }
            }

            Section("Index") {
                LabeledContent {
                    HStack(spacing: 8) {
                        if state.updating { ProgressView().controlSize(.small) }
                        Button("Update Index") { module.updateIndex() }.disabled(state.updating)
                    }
                } label: {
                    RowLabel(title: Text("Homebrew executables database"), subtitle: Text(verbatim: indexSubtitle))
                }
                Toggle(isOn: $s.value.autoUpdate) {
                    RowLabel(title: Text("Update automatically every week"),
                             subtitle: Text("Downloads Homebrew's published executables.txt (about \(ByteCountFormatter.string(fromByteCount: 350_000, countStyle: .file))).",
                                            comment: "executables.txt is a file name; the placeholder is a size such as '350 KB'"))
                }
            }

            Section("Try a command") {
                HStack(spacing: 8) {
                    Text(verbatim: "$").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("Command", text: $tryCommand, prompt: Text(verbatim: "wget"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: 240)
                }
                let found = CommandNotFound.suggestions(for: tryCommand.trimmingCharacters(in: .whitespaces))
                // What zsh prints in Terminal, which stays English like the rest of the command-line output.
                Text(verbatim: CommandNotFound.message(for: tryCommand.trimmingCharacters(in: .whitespaces), suggestions: found,
                                                       brewInstalled: state.brewPath != nil))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                    .foregroundStyle(.white)
            }

            Section {
                Text("Works in zsh, macOS's default shell. The handler only prints suggestions when output goes to a terminal, so scripts see zsh's normal error. Uninstall removes the block; nothing else in .zshrc is touched, and a backup is kept from before the first change.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .onAppear { module.refreshStatus() }
    }

    private var indexSubtitle: String {
        guard let date = state.indexDate, state.indexFormulae > 0 else { return String(localized: "Not downloaded yet.") }
        let age = date.formatted(.relative(presentation: .named))
        let count = state.indexFormulae
        guard let source = s.value.lastSource.map(CNFUpdater.sourceTitle) else {
            return String(localized: "\(count) formulae · updated \(age)",
                          comment: "First a number of Homebrew packages, then when, e.g. '2 days ago'")
        }
        return String(localized: "\(count) formulae · updated \(age) from \(source)",
                      comment: "A number of Homebrew packages, when (e.g. '2 days ago'), then a source such as GitHub Packages")
    }
}
