import AppKit
import MacToysCore
import SwiftUI

/// Bulk rename with search and replace, regular expressions, counters, dates and undo.
///
/// URL actions: `open` (files, or the Finder selection when none are given), `undo` (the last batch),
/// `settings`.
@MainActor
public final class PowerRenameModule: ToyModule {
    public let info = ModuleInfo(
        id: "powerrename", name: "PowerRename",
        summary: "Bulk rename files with search and replace, regular expressions, numbering and undo.",
        symbol: "character.cursor.ibeam", tint: .purple, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["rename", "regex", "regular expression", "batch", "bulk", "enumerate"])

    let settings = Persisted("powerrename", default: PowerRenameSettings())
    private var windows: [HostedToolWindow] = []
    private var running = false
    private let log = Log.for("powerrename")
    private static let hotkeyID = "powerrename.open"

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
        [QuickAction(id: "powerrename.open", title: "PowerRename", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.activation) { [weak self] in self?.openWithFinderSelection() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        settings.value.activation.map { [ShortcutBinding("Rename the Finder selection", $0)] } ?? []
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "open", "show", "rename":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            if command.files.isEmpty { openWithFinderSelection() } else { open(command.files) }
        case "undo":
            guard isEnabled else { return true }
            undoLastBatch()
        default:
            return false
        }
        return true
    }

    // MARK: Windows

    /// Opens the window for the Finder selection (an empty window, ready for dropped files, when nothing is selected).
    func openWithFinderSelection() {
        guard let urls = FinderSelection.selectionRequestingPermission() else { return }
        open(urls)
    }

    func open(_ urls: [URL]) {
        let s = settings.value
        let model = PowerRenameModel(items: RenameItemLoader.load(urls), options: s.initialOptions,
                                     flavor: s.regexFlavor, canUndo: RenameJournal.load(from: journalURL) != nil)
        model.onApplied = { [weak self] outcome, options in self?.applied(outcome, options: options) }
        model.onUndo = { [weak self] in self?.performUndo() }
        let view = PowerRenameWindowRoot(model: model, settings: settings)
        let window = HostedToolWindow(title: model.title, size: CGSize(width: 980, height: 640),
                                      minSize: CGSize(width: 760, height: 480), autosaveName: "MacToys.PowerRename",
                                      content: view)
        model.onItemsChanged = { [weak window, weak model] in
            if let window, let model { window.title = model.title }
        }
        window.onClose = { [weak self, weak window, weak model] in
            guard let self else { return }
            if let model, self.settings.value.restoreFlags { self.settings.value.lastOptions = model.options }
            self.windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.show()
    }

    private func applied(_ outcome: RenameExecutor.Outcome, options: RenameOptions) {
        settings.update { s in
            s.remember(search: options.search, replace: options.replace)
            if s.restoreFlags { s.lastOptions = options }
        }
        guard !outcome.done.isEmpty else { return }
        do {
            try RenameJournal(operations: outcome.done).save(to: journalURL)
        } catch {
            log.error("Could not save the undo journal: \(error.localizedDescription, privacy: .public)")
        }
        for f in outcome.failures {
            log.error("Rename failed \(f.operation.from.path, privacy: .public): \(f.message, privacy: .public)")
        }
    }

    // MARK: Undo

    private var journalURL: URL { Paths.data(for: "powerrename").appendingPathComponent("last-rename.json") }

    var canUndo: Bool { RenameJournal.load(from: journalURL) != nil }

    private func performUndo() -> RenameExecutor.Outcome? {
        guard let journal = RenameJournal.load(from: journalURL) else { return nil }
        let outcome = RenameExecutor.undo(journal.operations)
        do {
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            log.error("Could not remove the undo journal: \(error.localizedDescription, privacy: .public)")
        }
        for f in outcome.failures {
            log.error("Undo failed \(f.operation.from.path, privacy: .public): \(f.message, privacy: .public)")
        }
        return outcome
    }

    func undoLastBatch() {
        guard let outcome = performUndo() else {
            HUD.show("Nothing to undo", symbol: "arrow.uturn.backward")
            return
        }
        if outcome.failures.isEmpty {
            HUD.show("Restored \(outcome.done.count) name\(outcome.done.count == 1 ? "" : "s")", symbol: "arrow.uturn.backward")
        } else {
            HUD.show("\(outcome.failures.count) item\(outcome.failures.count == 1 ? "" : "s") could not be restored",
                     symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Settings

    public func settingsView() -> AnyView {
        AnyView(PowerRenameSettingsView(module: self))
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [PreviewScene("window", size: CGSize(width: 980, height: 600), wallpaper: false) { [settings] in
            AnyView(PowerRenameView(model: Self.sampleModel(), settings: settings, chrome: true))
        }]
    }

    static func sampleModel() -> PowerRenameModel {
        let names = ["IMG_4821.HEIC", "IMG_4822.HEIC", "IMG_4830.HEIC", "IMG_4831.mov", "IMG_4840.HEIC", "notes.txt"]
        let folder = URL(fileURLWithPath: "/Users/Shared/Trip", isDirectory: true)
        let items = names.enumerated().map { i, n in RenameItem(id: i, url: folder.appendingPathComponent(n)) }
        var options = RenameOptions()
        options.search = #"IMG_(\d+)"#
        options.replace = "Trip-${start=1,padding=3}-$1"
        options.useRegex = true
        options.matchAll = true
        options.enumerate = true
        return PowerRenameModel(items: items, options: options, flavor: .standard, canUndo: false, live: false)
    }
}

/// The window content; follows regex syntax changes made in Settings while open.
private struct PowerRenameWindowRoot: View {
    let model: PowerRenameModel
    let settings: Persisted<PowerRenameSettings>

    var body: some View {
        PowerRenameView(model: model, settings: settings)
            .frame(minWidth: 760, minHeight: 480)
            .onChange(of: settings.value.regexFlavor) { model.flavor = settings.value.regexFlavor }
    }
}

private struct PowerRenameSettingsView: View {
    let module: PowerRenameModule
    @Bindable var settings: Persisted<PowerRenameSettings>

    init(module: PowerRenameModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .purple) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rename many files at once").font(.headline)
                        Text("Select files in Finder and choose MacToys › PowerRename, or rename the current selection here.")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Undo Last Rename") { module.undoLastBatch() }
                        .disabled(!module.canUndo)
                    Button("Rename Finder Selection") { module.openWithFinderSelection() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Rename the Finder selection", subtitle: "Optional. Opens PowerRename with the files selected in Finder.",
                            shortcut: $settings.value.activation)
            }
            Section("Finder") {
                Toggle(isOn: $settings.value.showInFinderMenu) {
                    RowLabel("Show PowerRename in the Finder menu", subtitle: "Under MacToys in the context menu of selected items.")
                }
                Toggle(isOn: $settings.value.finderMenuNeedsOption) {
                    RowLabel("Only while holding ⌥ Option", subtitle: "Like Windows’ extended context menu: keeps the menu short otherwise.")
                }
                .disabled(!settings.value.showInFinderMenu)
                Toggle("Show icon in the Finder menu", isOn: $settings.value.showFinderMenuIcon)
                    .disabled(!settings.value.showInFinderMenu)
            }
            Section("Behavior") {
                Toggle(isOn: $settings.value.restoreFlags) {
                    RowLabel("Restore options on launch", subtitle: "Reopen with the checkboxes and choices of the last use.")
                }
                Toggle(isOn: $settings.value.autoComplete) {
                    RowLabel("Auto-complete search and replace", subtitle: "Suggest texts you used before while typing.")
                }
                Stepper(value: $settings.value.historySize, in: 1...50) {
                    RowLabel("Maximum number of items", subtitle: "\(settings.value.historySize) recent texts are kept for each field.")
                }
                Toggle(isOn: $settings.value.showRecentValues) {
                    RowLabel("Show recently used strings", subtitle: "Fill the fields with the last search and replacement.")
                }
                Picker(selection: $settings.value.regexFlavor) {
                    ForEach(RegexFlavor.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Regular expression syntax",
                             subtitle: settings.value.regexFlavor == .standard
                                 ? "$1, $&, $` and $' in replacements; backslashes are literal."
                                 : "Adds ${name}, $+{name}, backslash escapes and \\U \\L \\E \\u \\l case conversion.")
                }
                LabeledContent {
                    Button("Clear History") {
                        settings.update { $0.searchHistory = []; $0.replaceHistory = [] }
                    }
                    .disabled(settings.value.searchHistory.isEmpty && settings.value.replaceHistory.isEmpty)
                } label: {
                    RowLabel("Search and replace history",
                             subtitle: "\(settings.value.searchHistory.count + settings.value.replaceHistory.count) saved texts")
                }
            }
            FinderExtensionSection()
        }
    }
}
