import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Create files and folders from your own templates.
///
/// URL actions: `create?template=<file name or title>&dir=<folder>` creates an item (without `template`
/// it shows the picker for `dir`), `open`/`show` shows the picker for `dir` or the frontmost Finder folder,
/// `templates` opens the templates folder, `settings`.
@MainActor
public final class NewPlusModule: ToyModule {
    public let info = ModuleInfo(
        id: "newplus", name: "New+",
        summary: "Create files and folders from your own templates in Finder.",
        symbol: "doc.badge.plus", tint: .green, category: .fileManagement,
        permissions: [.automation], enabledByDefault: true,
        keywords: ["new file", "template", "create", "new folder", "context menu"])

    let settings = Persisted("newplus", default: NewPlusSettings())
    private var running = false
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private let picker = NewPlusPickerPanel()
    private let log = Log.for("newplus")
    private static let hotkeyID = "newplus.picker"

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkey()
            self.watchTemplates()
            self.writeManifest()
        }
    }

    public func start() {
        running = true
        seedIfNeeded()
        watchTemplates()
        writeManifest()
        registerHotkey()
    }

    public func stop() {
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
        picker.close()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activation) { [weak self] in
            self?.showPicker(in: nil)
        }
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "newplus.picker", title: "New from Template…", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.activation) { [weak self] in self?.showPicker(in: nil) }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        settings.value.activation.map { [ShortcutBinding("New from template", $0)] } ?? []
    }

    public func handle(_ command: AppCommand) -> Bool {
        let dir = command.parameters["dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? command.files.first
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "templates":
            openTemplatesFolder()
        case "create":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            if let name = command.parameters["template"], !name.isEmpty {
                guard let template = NewPlusTemplates.find(name, in: templates, hideExtension: settings.value.hideExtensions,
                                                           hideLeadingDigits: settings.value.hideLeadingDigits) else {
                    HUD.show("No template named “\(name)”", symbol: "doc.badge.plus")
                    return true
                }
                create(template, in: dir ?? currentFolder())
            } else {
                showPicker(in: dir)
            }
        case "open", "show", "new":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            showPicker(in: dir)
        default:
            return false
        }
        return true
    }

    // MARK: Templates

    var templates: [NewPlusTemplate] { NewPlusTemplates.list(in: settings.value.templatesFolder) }

    private func seedIfNeeded() {
        guard !settings.value.seeded else { return }
        let folder = NewPlusSettings.defaultTemplatesFolder
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
        if existing.isEmpty {
            do {
                try NewPlusTemplates.seed(folder)
            } catch {
                log.error("Could not create the default templates: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        settings.value.seeded = true
    }

    func openTemplatesFolder() {
        let folder = settings.value.templatesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Writes the list the Finder extension shows.
    private func writeManifest() {
        let manifest = NewPlusMenuManifest(templates: templates, settings: settings.value)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: NewPlusMenuManifest.url, options: .atomic)
        } catch {
            log.error("Could not write the Finder menu: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rewrites the manifest whenever something in the templates folder changes.
    private func watchTemplates() {
        let path = settings.value.templatesFolder.path
        guard watchedPath != path || watcher == nil else { return }
        watcher?.cancel()
        watcher = nil
        watchedPath = path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let events = self.watcher?.data else { return }
            self.writeManifest()
            if events.contains(.delete) || events.contains(.rename) {
                // The folder itself moved away: watch whatever is at the path now.
                self.watcher?.cancel()
                self.watcher = nil
                self.watchTemplates()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Creating

    /// The frontmost Finder folder, or the Desktop when Finder can't be asked (Automation is requested then).
    private func currentFolder() -> URL {
        if !PermissionCenter.shared.isGranted(.automation), !PermissionCenter.automationGranted(bundleID: "com.apple.finder") {
            PermissionCenter.shared.request(.automation)
        }
        return FinderSelection.currentFolder()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func create(_ template: NewPlusTemplate, in folder: URL) {
        let s = settings.value
        do {
            let url = try NewPlusCreator.create(from: template, in: folder,
                                                options: .init(replaceVariables: s.replaceVariables,
                                                               stripLeadingDigits: s.hideLeadingDigits))
            reveal(url)
        } catch {
            log.error("New+ failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t create “\(template.title(hideExtension: s.hideExtensions, hideLeadingDigits: s.hideLeadingDigits))”"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Selects the new item in Finder and, when allowed, presses Return to rename it.
    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        guard settings.value.startRename, AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard FinderSelection.finderIsFrontmost else { return }
            if PermissionCenter.shared.isGranted(.automation) {
                let selected = FinderSelection.selectedURLs().map { $0.standardizedFileURL.path }
                guard selected == [url.standardizedFileURL.path] else { return }
            }
            KeySynth.tap(kVK_Return)
        }
    }

    // MARK: Picker

    func showPicker(in folder: URL?) {
        let s = settings.value
        let model = NewPlusPickerModel(templates: templates, destination: folder ?? currentFolder(),
                                       hideExtension: s.hideExtensions, hideLeadingDigits: s.hideLeadingDigits)
        let view = NewPlusPickerView(
            model: model,
            onCreate: { [weak self] template in
                self?.picker.close()
                self?.create(template, in: model.destination)
            },
            onChooseFolder: { [weak self] in self?.chooseFolder(for: model) },
            onOpenTemplates: { [weak self] in
                self?.picker.close()
                self?.openTemplatesFolder()
            })
        picker.show(view)
    }

    private func chooseFolder(for model: NewPlusPickerModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.destination
        panel.prompt = "Choose"
        picker.hidesOnResign = false
        if panel.runModal() == .OK, let url = panel.url { model.destination = url }
        picker.hidesOnResign = true
    }

    // MARK: Settings

    public func settingsView() -> AnyView {
        AnyView(NewPlusSettingsView(module: self))
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [PreviewScene("picker", size: CGSize(width: 460, height: 470)) {
            let folder = URL(fileURLWithPath: "/Users/Shared/Templates", isDirectory: true)
            let samples: [(String, Bool)] = [("Project", true), ("Client Brief $YYYY-$MM", true), ("Markdown Note.md", false),
                                             ("Meeting Notes.rtf", false), ("Python Script.py", false),
                                             ("Shell Script.sh", false), ("Web Page.html", false)]
            let model = NewPlusPickerModel(templates: samples.map { NewPlusTemplate(url: folder.appendingPathComponent($0.0), isFolder: $0.1) },
                                           destination: URL(fileURLWithPath: "/Users/Shared/Projects/mactoys", isDirectory: true),
                                           hideExtension: true, hideLeadingDigits: false)
            model.selection = 2
            return AnyView(NewPlusPickerView(model: model).padding(30))
        }]
    }
}

private struct NewPlusSettingsView: View {
    let module: NewPlusModule
    @Bindable var settings: Persisted<NewPlusSettings>

    init(module: NewPlusModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .green) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your templates").font(.headline)
                        Text("Right-click a folder’s background in Finder and choose New+. Anything in the templates folder — files, folders, aliases — becomes a template; folders are listed first.")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Open Templates Folder") { module.openTemplatesFolder() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Templates") {
                LabeledContent {
                    HStack {
                        if settings.value.customTemplatesFolder != nil {
                            Button("Use Default") { settings.value.customTemplatesFolder = nil }
                        }
                        Button("Change…") { chooseLocation() }
                    }
                } label: {
                    RowLabel("Templates location", subtitle: (settings.value.templatesFolder.path as NSString).abbreviatingWithTildeInPath)
                }
                ShortcutRow("New from template", subtitle: "Optional. Opens the template picker for the frontmost Finder folder.",
                            shortcut: $settings.value.activation)
            }
            Section("Display") {
                Toggle(isOn: $settings.value.hideExtensions) {
                    RowLabel("Hide the file extension in template names", subtitle: "“Report.docx” is shown as “Report”.")
                }
                Toggle(isOn: $settings.value.hideLeadingDigits) {
                    RowLabel("Hide leading digits, spaces and dots",
                             subtitle: "“1. Report” is shown and created as “Report”: use numbers to order your templates.")
                }
                Toggle(isOn: $settings.value.showInFinderMenu) {
                    RowLabel("Show New+ in the Finder menu", subtitle: "On the context menu of a folder’s background.")
                }
            }
            Section {
                Toggle(isOn: $settings.value.replaceVariables) {
                    RowLabel("Replace variables in template names",
                             subtitle: "Also in the names of files inside folder templates. Characters a name can’t hold become spaces.")
                }
                Toggle(isOn: $settings.value.startRename) {
                    RowLabel("Rename the new item right away", subtitle: "Selects it in Finder and starts editing its name. Needs Accessibility.")
                }
            } header: {
                Text("Behavior")
            } footer: {
                VariablesHelp().padding(.top, 4)
            }
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.value.templatesFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.value.customTemplatesFolder = url.path }
    }
}

private struct VariablesHelp: View {
    var body: some View {
        let date = DateTokens.help.filter { ["$YYYY", "$YY", "$MMMM", "$MMM", "$MM", "$DD", "$DDDD", "$hh", "$mm", "$ss", "$fff"].contains($0.token) }
        let special: [(String, String)] = [("$PARENT_FOLDER_NAME", "Name of the folder it’s created in"),
                                           ("%USERNAME%", "Your account name"),
                                           ("%NAME%", "Any environment variable, e.g. %HOME%")]
        VStack(alignment: .leading, spacing: 6) {
            Text("Example: “$YYYY-$MM-$DD Notes by %USERNAME%.md” → “\(example)”")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Array(stride(from: 0, to: date.count, by: 2)), id: \.self) { i in
                    GridRow {
                        cell(date[i].token, date[i].meaning)
                        if i + 1 < date.count { cell(date[i + 1].token, date[i + 1].meaning) }
                    }
                }
                ForEach(special, id: \.0) { s in
                    GridRow { cell(s.0, s.1).gridCellColumns(2) }
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var example: String {
        NewPlusVariables.expand("$YYYY-$MM-$DD Notes by %USERNAME%.md", context: .init(parentFolderName: "Projects"))
    }

    private func cell(_ token: String, _ meaning: String) -> some View {
        HStack(spacing: 6) {
            Text(token).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
            Text(meaning)
        }
    }
}
