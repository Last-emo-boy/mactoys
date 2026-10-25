import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// The PowerRename window (`design/exports/07-tool-windows.png`): options on the left, the live preview on the right.
struct PowerRenameView: View {
    @Bindable var model: PowerRenameModel
    let settings: Persisted<PowerRenameSettings>
    /// Draw a fake title bar (offscreen previews) instead of using the window toolbar.
    var chrome = false

    var body: some View {
        if chrome {
            HostedToolWindowChrome(title: model.title, symbol: "character.cursor.ibeam", tint: .purple) {
                toolbarButtons
            } content: {
                main
            }
        } else {
            main
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ModuleIcon(symbol: "character.cursor.ibeam", tint: .purple, size: 20)
                    }
                    ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
                }
        }
    }

    @ViewBuilder private var toolbarButtons: some View {
        Button { addFiles() } label: { Label("Add Files", systemImage: "plus") }
            .help("Add files or folders")
        Button { model.apply() } label: { Text("Apply", comment: "PowerRename toolbar: rename the items now") }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.renameCount == 0)
    }

    private var main: some View {
        HStack(spacing: 0) {
            PowerRenameOptionsPane(model: model, settings: settings)
                .frame(width: 290)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                PowerRenamePreviewTable(model: model)
                Divider()
                footer
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls.filter(\.isFileURL))
            return true
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = model.resultMessage {
                Image(systemName: model.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.failures.isEmpty ? .green : .orange)
                Text(verbatim: message)
                if !model.failures.isEmpty {
                    Button { showFailures() } label: { Text("Details", comment: "PowerRename footer: show which items failed and why") }
                        .buttonStyle(.link)
                }
            } else {
                Text(verbatim: summary)
            }
            Spacer()
            Toggle("Only show renamed", isOn: $model.onlyShowRenamed)
                .toggleStyle(.checkbox)
            if model.canUndo {
                Button("Undo Rename") { model.undo() }
            } else {
                Text("Undo is available after renaming").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var summary: String {
        var parts = [String(localized: "\(model.renameCount) of \(model.items.count) items will be renamed",
                            comment: "PowerRename footer: items that will be renamed, of all listed items")]
        if model.conflictCount > 0 {
            parts.append(String(localized: "\(model.conflictCount) renamed with a number",
                                comment: "PowerRename footer: items whose new name is taken, so a number like (2) is added"))
        }
        if model.invalidCount > 0 {
            parts.append(String(localized: "\(model.invalidCount) invalid", comment: "PowerRename footer: items whose new name is not a valid file name"))
        }
        return parts.joined(separator: " · ")
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Open panel button: add the chosen files to PowerRename")
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func showFailures() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Some items could not be renamed")
        alert.informativeText = model.failures.prefix(20)
            .map {
                String(localized: "\($0.operation.from.lastPathComponent) → \($0.operation.to.lastPathComponent): \($0.message)",
                       comment: "PowerRename failure line: old name → new name: reason")
            }
            .joined(separator: "\n")
        alert.runModal()
    }
}

/// Search, replace and every option.
struct PowerRenameOptionsPane: View {
    @Bindable var model: PowerRenameModel
    let settings: Persisted<PowerRenameSettings>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                label("Search for")
                HistoryField(placeholder: "Text or regular expression", text: $model.options.search,
                             history: settings.value.autoComplete ? settings.value.searchHistory : [])
                if let error = model.patternError {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
                label("Replace with").padding(.top, 4)
                HStack(spacing: 6) {
                    HistoryField(placeholder: "Replacement", text: $model.options.replace,
                                 history: settings.value.autoComplete ? settings.value.replaceHistory : [])
                    VariablesMenu(options: $model.options)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Use regular expressions", isOn: $model.options.useRegex)
                    Toggle("Match all occurrences", isOn: $model.options.matchAll)
                    Toggle("Case sensitive", isOn: $model.options.caseSensitive)
                    Toggle("Enumerate items", isOn: $model.options.enumerate)
                        .help(Text("${}, ${start=1}, ${increment=2}, ${padding=3} or combined: ${start=10,increment=2,padding=4}",
                                   comment: "PowerRename tooltip: keep the ${…} variables as they are"))
                    Toggle("Random string values", isOn: $model.options.randomize)
                        .help(Text(verbatim: "${rstringalnum=9}, ${rstringalpha=9}, ${rstringdigit=9}, ${ruuidv4}"))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 6)

                label("Apply to").padding(.top, 8)
                Picker("Apply to", selection: $model.options.scope) {
                    ForEach(RenameScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    ForEach([TextFormat.lowercase, .uppercase, .titleCase, .capitalized], id: \.self) { f in
                        FormatButton(format: f, selection: $model.options.textFormat)
                    }
                }
                .padding(.top, 2)

                label("Include").padding(.top, 8)
                // Side by side when the translations fit, else one per line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { includeToggles }
                    VStack(alignment: .leading, spacing: 7) { includeToggles }
                }
                .toggleStyle(.checkbox)

                label("Exclude").padding(.top, 8)
                TextField("Exclude", text: $model.options.exclude,
                          prompt: Text("e.g. *.tmp, .DS_Store", comment: "PowerRename exclude field placeholder; keep the patterns *.tmp and .DS_Store"))
                    .textFieldStyle(.roundedBorder)

                label("Dates in variables").padding(.top, 8)
                Picker("Dates in variables", selection: $model.options.dateSource) {
                    ForEach(RenameDateSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)
        }
    }

    @ViewBuilder private var includeToggles: some View {
        Toggle("Files", isOn: $model.options.includeFiles)
        Toggle("Folders", isOn: $model.options.includeFolders)
        Toggle("Subfolders", isOn: $model.options.includeSubfolders)
            .help("Rename the items inside selected folders too")
    }

    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// A text field with suggestions from earlier uses.
struct HistoryField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let history: [String]

    var body: some View {
        let suggestions = history.filter { text.isEmpty || ($0.localizedCaseInsensitiveContains(text) && $0 != text) }
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5, design: .monospaced))
            .autocorrectionDisabled()
            .textInputSuggestions {
                ForEach(suggestions, id: \.self) { s in
                    Text(verbatim: s).textInputCompletion(s)
                }
            }
    }
}

/// Inserts a variable into *Replace with*.
struct VariablesMenu: View {
    @Binding var options: RenameOptions

    var body: some View {
        Menu {
            Section("Counters") {
                insert("${}", "Counter from 0") { $0.enumerate = true }
                insert("${start=1,padding=3}", "Counter from 001") { $0.enumerate = true }
                insert("${start=10,increment=2,padding=4}",
                       meaning: String(localized: "Counter 0010, 0012, …", comment: "PowerRename variable menu; keep the sample numbers")) {
                    $0.enumerate = true
                }
            }
            Section("Random values") {
                insert("${rstringalnum=9}", "Letters and digits") { $0.randomize = true }
                insert("${rstringalpha=9}", "Letters") { $0.randomize = true }
                insert("${rstringdigit=9}", "Digits") { $0.randomize = true }
                insert("${ruuidv4}", meaning: "UUID") { $0.randomize = true }
            }
            Menu("File date") {
                ForEach(DateTokens.help, id: \.token) { t in insert(t.token, meaning: t.meaning) { _ in } }
            }
            Menu("Photo metadata") {
                ForEach(PhotoMetadata.help, id: \.token) { t in insert(t.token, meaning: t.meaning) { _ in } }
            }
            Section("Regular expressions") {
                insert("$1", "First capture group") { $0.useRegex = true }
                insert("$&", "Whole match") { $0.useRegex = true }
            }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a variable")
    }

    private func insert(_ token: String, _ meaning: String.LocalizationValue,
                        enable: @escaping (inout RenameOptions) -> Void) -> some View {
        insert(token, meaning: String(localized: meaning), enable: enable)
    }

    /// `meaning` is already localized.
    private func insert(_ token: String, meaning: String, enable: @escaping (inout RenameOptions) -> Void) -> some View {
        Button(token + "   " + meaning) {
            options.replace += token
            enable(&options)
        }
    }
}

/// One of the "aa", "AA", "Aa", "Aa Bb" toggle buttons; clicking the selected one turns formatting off.
struct FormatButton: View {
    let format: TextFormat
    @Binding var selection: TextFormat

    var body: some View {
        let on = selection == format
        Button {
            selection = on ? .none : format
        } label: {
            Text(verbatim: format.label)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .help(format.title)
    }
}

/// Original → Renamed table with checkboxes.
struct PowerRenamePreviewTable: View {
    @Bindable var model: PowerRenameModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            let rows = model.visibleRows
            if rows.isEmpty {
                ContentUnavailableView {
                    Label {
                        model.items.isEmpty ? Text("No items") : Text("Nothing to rename")
                    } icon: {
                        Image(systemName: model.items.isEmpty ? "tray" : "line.3.horizontal.decrease.circle")
                    }
                } description: {
                    model.items.isEmpty ? Text("Drop files or folders here, or click + to add them.") : Text("No item matches the search.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            PreviewRow(row: row, checked: Binding(get: { model.isChecked(row) },
                                                                  set: { model.setChecked(row, $0) }))
                                .background(index % 2 == 1 ? Color.primary.opacity(0.025) : .clear)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { model.unchecked.isEmpty }, set: { model.setAllChecked($0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: 30)
                .help("Select all")
            Text("Original", comment: "PowerRename column: the current name").frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.onlyShowRenamed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("Renamed", comment: "PowerRename column: the new name")
                    if model.onlyShowRenamed { Image(systemName: "line.3.horizontal.decrease.circle.fill") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show only the items that will be renamed")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

private struct PreviewRow: View {
    let row: RenamePreview
    @Binding var checked: Bool

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: $checked).toggleStyle(.checkbox).labelsHidden()
                .frame(width: 30)
                .disabled(row.status == .skipped)
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: row.item.name).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, CGFloat(row.item.depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(row.status == .skipped || row.status == .unchecked ? 0.45 : 1)
            renamed.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder private var renamed: some View {
        switch row.status {
        case .rename:
            Text(verbatim: row.newName ?? "").foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
        case .conflict:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(verbatim: row.newName ?? "").foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
            }
            .help("“\(row.proposedName ?? "")” already exists, so a number is added")
        case .invalid(let reason):
            HStack(spacing: 5) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(verbatim: row.proposedName ?? "").foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
            }
            .help(reason)
        case .unchanged, .skipped, .unchecked:
            Text(verbatim: "—").foregroundStyle(Color.accentColor.opacity(row.status == .unchanged ? 1 : 0.4))
        }
    }

    private var symbol: String {
        if row.item.isFolder { return "folder" }
        let type = UTType(filenameExtension: row.item.url.pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true { return "film" }
        if type?.conforms(to: .application) == true || type?.conforms(to: .package) == true { return "app" }
        return "doc"
    }
}
