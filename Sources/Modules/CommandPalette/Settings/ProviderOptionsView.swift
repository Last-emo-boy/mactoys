import AppKit
import MacToysCore
import SwiftUI

/// A text editor bound to a list of lines.
struct LinesEditor: View {
    let title: String
    let subtitle: String
    @Binding var lines: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title, subtitle: subtitle)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onAppear { text = lines.joined(separator: "\n") }
                .onChange(of: text) { _, new in
                    lines = new.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
        }
    }
}

/// A multi-line text setting.
struct TextBlockEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title, subtitle: subtitle)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

/// The options of one provider; the same view appears in Command Palette's Extensions and Run's Plugins.
struct ProviderOptionsView: View {
    let providerID: String
    @Bindable var options: Persisted<ProviderOptions>

    var body: some View {
        switch providerID {
        case "apps": apps
        case "files": files
        case "calc": calculator
        case "units":
            Toggle(isOn: $options.value.unitsCopyWithUnit) { RowLabel("Copy results with their unit", subtitle: "“6.21 mi” instead of “6.21”") }
        case "time": time
        case "web": web
        case "url": browserPicker
        case "shell": shell
        case "windows":
            Toggle(isOn: $options.value.windowsIncludeMinimized) { RowLabel("Include minimized windows") }
            Toggle(isOn: $options.value.windowsIncludeHidden) { RowLabel("Include windows of hidden apps") }
        case "system":
            Toggle(isOn: $options.value.confirmSystemCommands) {
                RowLabel("Confirm restart, shut down, log out and Empty Trash")
            }
        case "clipboard":
            Toggle(isOn: $options.value.clipboardPasteOnEnter) {
                RowLabel("↵ pastes into the front app", subtitle: "Off: ↵ copies, ⇧⌘V pastes. Pasting needs Accessibility.")
            }
        case "bookmarks": bookmarks
        case "processes":
            Toggle(isOn: $options.value.processesConfirmKill) { RowLabel("Confirm before killing a process") }
        case "brew": brew
        case "scripts": scripts
        case "editors": editors
        case "history":
            LabeledContent { Button("Clear History") { LauncherEngine.shared.usage.clearHistory() } } label: {
                RowLabel("History", subtitle: "\(LauncherEngine.shared.usage.history.count) entries, shared by Command Palette and Run")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var apps: some View {
        Toggle(isOn: $options.value.appShowRunningIndicator) { RowLabel("Mark running apps") }
        Toggle(isOn: $options.value.appIncludeCoreServices) {
            RowLabel("Include system utilities", subtitle: "Apps in /System/Library/CoreServices/Applications (Directory Utility, Ticket Viewer…)")
        }
        LinesEditor(title: "More app folders", subtitle: "Besides /Applications, /System/Applications and ~/Applications; one path per line.",
                    lines: $options.value.appExtraFolders)
        LabeledContent { Button("Re-index Now") { (LauncherEngine.shared.provider("apps") as? AppsProvider)?.reindex() } } label: {
            RowLabel("App index", subtitle: "Updates by itself when apps are installed")
        }
    }

    @ViewBuilder private var files: some View {
        Picker(selection: $options.value.fileScope) {
            ForEach(FileScope.allCases) { Text($0.title).tag($0) }
        } label: { RowLabel("Search in") }
        Stepper(value: $options.value.fileMaxResults, in: 5...100, step: 5) {
            RowLabel("Maximum results", subtitle: "\(options.value.fileMaxResults) on the Files page; fewer in the main search")
        }
        Toggle(isOn: $options.value.fileMatchContents) { RowLabel("Also match file contents", subtitle: "Slower; uses the Spotlight index") }
        Toggle(isOn: $options.value.fileShowHidden) { RowLabel("Show hidden files when browsing a path") }
    }

    @ViewBuilder private var calculator: some View {
        Picker(selection: $options.value.angleUnit) {
            ForEach(AngleUnit.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: { RowLabel("Trigonometry uses") }
        Toggle(isOn: $options.value.calcShowBases) { RowLabel("Show hexadecimal, binary and octal for whole numbers") }
        Toggle(isOn: $options.value.calcShowScientific) { RowLabel("Show scientific notation") }
    }

    @ViewBuilder private var time: some View {
        Toggle(isOn: $options.value.timeShowSeconds) { RowLabel("Show seconds") }
        LinesEditor(title: "World clocks", subtitle: "Time zone identifiers listed with “time”, e.g. Europe/London; one per line.",
                    lines: $options.value.worldClocks)
        let invalid = options.value.worldClocks.filter { TimeZone(identifier: $0) == nil }
        if !invalid.isEmpty {
            InfoBar(.warning, title: "Unknown time zones", message: invalid.joined(separator: ", "))
        }
        TextBlockEditor(title: "Custom formats",
                        subtitle: "One per line: Name=pattern or Name=UTC:pattern (Unicode patterns plus UXT, UMS, WOY, DOW, DIM).",
                        text: $options.value.timeCustomFormats)
    }

    @ViewBuilder private var web: some View {
        Picker(selection: $options.value.searchEngine) {
            ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
        } label: { RowLabel("Search engine") }
        if options.value.searchEngine == .custom {
            LabeledContent {
                TextField("", text: $options.value.customSearchURL).textFieldStyle(.roundedBorder).frame(width: 300)
            } label: { RowLabel("Search URL", subtitle: "%s is replaced by the query") }
        }
        browserPicker
    }

    private var browserPicker: some View {
        Picker(selection: $options.value.browserBundleID) {
            Text("Default browser").tag("")
            ForEach(Self.browsers, id: \.bundleID) { b in Text(b.name).tag(b.bundleID) }
        } label: { RowLabel("Open web pages in", subtitle: "Shared by web search and URLs") }
    }

    @ViewBuilder private var shell: some View {
        Picker(selection: $options.value.terminal) {
            ForEach(TerminalApp.allCases) { t in
                Text(t.title + (NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) == nil ? " (not installed)" : "")).tag(t)
            }
        } label: { RowLabel("Terminal app") }
        Picker(selection: $options.value.shellMode) {
            ForEach(ShellMode.allCases) { Text($0.title).tag($0) }
        } label: { RowLabel("↵ runs the command", subtitle: "The other modes are in the actions menu (⌘K)") }
        Toggle(isOn: $options.value.shellKeepOpen) { RowLabel("Keep the terminal open after the command ends") }
        Toggle(isOn: $options.value.shellRememberHistory) { RowLabel("Remember commands") }
        LabeledContent { Button("Clear") { LauncherEngine.shared.usage.clearShellHistory() } } label: {
            RowLabel("Command history", subtitle: "\(LauncherEngine.shared.usage.shellHistory.count) commands")
        }
    }

    @ViewBuilder private var bookmarks: some View {
        ForEach(BrowserKind.allCases) { b in
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) != nil
            Toggle(isOn: Binding(get: { options.value.bookmarkBrowsers[b.rawValue] ?? true },
                                 set: { options.value.bookmarkBrowsers[b.rawValue] = $0 })) {
                RowLabel(b.title, subtitle: installed ? nil : "Not installed")
            }
        }
        InfoBar(.info, title: "Safari bookmarks need Full Disk Access",
                message: "macOS protects ~/Library/Safari. Chrome-family bookmarks work without it.",
                actionTitle: "Open Settings") { PermissionCenter.shared.openSettings(.fullDiskAccess) }
    }

    @ViewBuilder private var brew: some View {
        Toggle(isOn: $options.value.brewIncludeCasks) { RowLabel("Include casks (apps)") }
        if HomebrewProvider.brewPath == nil {
            InfoBar(.info, title: "Homebrew isn’t installed", message: "Install it from brew.sh to search and install packages.")
        }
    }

    @ViewBuilder private var scripts: some View {
        let folder = options.value.resolvedScriptsFolder
        LabeledContent {
            HStack {
                Button("Open") {
                    (LauncherEngine.shared.provider("scripts") as? ScriptsProvider)?.prepareFolder()
                    NSWorkspace.shared.open(folder)
                }
                Button("Choose…") { chooseScriptsFolder() }
                if !options.value.scriptsFolder.isEmpty { Button("Default") { options.value.scriptsFolder = "" } }
            }
        } label: {
            RowLabel("Script Commands folder", subtitle: (folder.path as NSString).abbreviatingWithTildeInPath)
        }
        LabeledContent {
            Button("Add Example") {
                options.value.exampleScriptCreated = false
                (LauncherEngine.shared.provider("scripts") as? ScriptsProvider)?.prepareFolder()
                (LauncherEngine.shared.provider("scripts") as? ScriptsProvider)?.rescan()
            }
        } label: {
            RowLabel("How scripts work",
                     subtitle: "Executable files here become commands. Header lines like “# @mactoys.title …”, “@mactoys.icon”, “@mactoys.mode silent|output|inline|terminal” and “@mactoys.argument Placeholder” set the title, icon, how output shows and an argument. Raycast script headers work too.")
        }
    }

    @ViewBuilder private var editors: some View {
        ForEach(CodeEditor.allCases) { e in
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleID) != nil
            Toggle(isOn: Binding(get: { options.value.editors[e.rawValue] ?? true }, set: { options.value.editors[e.rawValue] = $0 })) {
                RowLabel(e.title, subtitle: installed ? nil : "Not installed")
            }
        }
    }

    private func chooseScriptsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            options.value.scriptsFolder = url.path
        }
    }

    /// Installed web browsers.
    static var browsers: [(name: String, bundleID: String)] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var out: [(name: String, bundleID: String)] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let bid = Bundle(url: url)?.bundleIdentifier, !out.contains(where: { $0.bundleID == bid }) else { continue }
            out.append((FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), bid))
        }
        return out
    }
}

/// Header row of a provider in a settings list: icon, name, summary.
struct ProviderHeader: View {
    let provider: any SearchProvider
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            ItemIconView(icon: provider.icon, size: 22).environment(\.colorScheme, .light)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                Text(detail ?? provider.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Providers that have their own options.
let providersWithOptions: Set<String> = ["apps", "files", "calc", "units", "time", "web", "url", "shell", "windows", "system",
                                         "clipboard", "bookmarks", "processes", "brew", "scripts", "editors", "history"]
