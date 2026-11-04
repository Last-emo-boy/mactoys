import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    let module: ClipboardHistoryModule
    @Bindable var settings: Persisted<ClipboardSettings>
    let library: ClipLibrary
    @State private var history = ClipboardHistory.shared
    @State private var editingSnippet: SnippetDraft?
    @State private var confirmClear = false

    var body: some View {
        SettingsPage(module: module) {
            ClipboardHero(style: $settings.value.style, showPreview: settings.value.showPreview,
                          shortcut: settings.value.openShortcut, itemCount: history.items.count,
                          paused: settings.value.paused) { module.panel.show() }
        } content: {
            Section("Panel") {
                ShortcutRow("Open clipboard history", shortcut: $settings.value.openShortcut)
                Picker(selection: $settings.value.style) {
                    ForEach(ClipboardSettings.PanelStyle.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Style", subtitle: "The panel opens on the display with the pointer; the paste bar runs along its bottom.")
                }
                Picker(selection: $settings.value.returnAction) {
                    ForEach(ClipboardSettings.ReturnAction.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Return key", subtitle: "⇧↩ pastes as plain text, ⌥↩ does the other action, ⌘C only copies.")
                }
                Toggle(isOn: $settings.value.showPreview) {
                    RowLabel("Show the preview pane", subtitle: "Panel style: a large preview of the selected item with its details.")
                }
                Toggle(isOn: $settings.value.moveToTopOnPaste) {
                    RowLabel("Move pasted items to the top", subtitle: "So ⌘1 pastes what you used last.")
                }
                Picker(selection: $settings.value.mergeSeparator) {
                    ForEach(ClipboardSettings.MergeSeparator.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Merge with", subtitle: "Goes between items you join with ⌘M or paste together.")
                }
            }

            Section("Paste stack") {
                ShortcutRow("Paste stack on/off", subtitle: "Copy several things, then each ⌘V pastes the next one.",
                            shortcut: $settings.value.stackShortcut)
                Picker(selection: $settings.value.stackOrder) {
                    ForEach(PasteStack.Order.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Paste order")
                }
                Toggle(isOn: $settings.value.restoreClipboardAfterStack) {
                    RowLabel("Restore the clipboard afterwards", subtitle: "Put back what you had copied before the stack started.")
                }
            }

            Section {
                PinboardsEditor(library: library)
            } header: {
                Text("Pinboards")
            } footer: {
                Text("Collections for things you paste again and again. Items on a pinboard never expire. Drag items onto a pinboard in the panel, or use ⌘K.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            Section {
                SnippetsEditor(library: library, editing: $editingSnippet)
                Toggle(isOn: $settings.value.restoreClipboardAfterSnippet) {
                    RowLabel("Keep the clipboard when pasting a snippet", subtitle: "Snippets paste through the clipboard; this puts your copy back.")
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Type a snippet’s abbreviation in the panel’s search and press Return. Placeholders: {date}, {time}, {datetime}, {date:yyyy-MM-dd}, {clipboard}, {cursor}.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle(isOn: $settings.value.paused) {
                    RowLabel("Pause recording", subtitle: "Nothing you copy is saved until you turn this off again.")
                }
                ShortcutRow("Pause or resume recording", shortcut: $settings.value.pauseShortcut)
                LabeledContent {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Tint.green.color).font(.system(size: 16))
                } label: {
                    RowLabel("Passwords are never recorded",
                             subtitle: "Copies marked concealed or transient — passwords, one-time codes, generated content — are skipped.")
                }
            }

            Section {
                ExcludedAppsList(apps: $settings.value.excludedApps)
            } header: {
                Text("Never record copies from")
            } footer: {
                Text("Copies made while one of these apps is in front are skipped. Password managers are listed from the start.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            Section("History") {
                Picker(selection: $settings.value.maxItems) {
                    ForEach(ClipboardSettings.limits, id: \.self) { n in
                        Text("\(n) items", comment: "Clipboard history size limit").tag(n)
                    }
                } label: {
                    RowLabel("Keep up to", subtitle: "Pinned items don’t count.")
                }
                Picker(selection: $settings.value.retention) {
                    ForEach(ClipboardSettings.Retention.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Keep items for")
                }
                LabeledContent {
                    Button("Clear History…") { confirmClear = true }
                        .disabled(history.items.allSatisfy(\.pinned))
                } label: {
                    RowLabel(title: Text("\(history.items.count) items", comment: "Clipboard history: number of saved entries"),
                             subtitle: Text("Pinned items, pinboards and snippets are kept."))
                }
            }
        }
        .sheet(item: $editingSnippet) { draft in
            SnippetEditorView(snippet: draft.snippet, isNew: draft.isNew,
                              onSave: { library.updateSnippet($0); editingSnippet = nil },
                              onDelete: draft.isNew ? nil : { library.deleteSnippet(draft.snippet.id); editingSnippet = nil },
                              onCancel: { editingSnippet = nil })
        }
        .confirmationDialog(Text("Clear clipboard history?"), isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("Pinned items, pinboards and snippets are kept. This can’t be undone.")
        }
    }
}

/// A snippet being edited in the sheet.
struct SnippetDraft: Identifiable {
    var snippet: Snippet
    var isNew: Bool
    var id: UUID { snippet.id }
}

// MARK: Pinboards

struct PinboardsEditor: View {
    let library: ClipLibrary

    var body: some View {
        if library.pinboards.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "pin.square").font(.system(size: 22)).foregroundStyle(Tint.indigo.color).symbolRenderingMode(.hierarchical)
                RowLabel("No pinboards yet", subtitle: "Make one for snippets of a project, replies you send often or brand colors.")
                Spacer()
                addButton
            }
            .padding(.vertical, 2)
        } else {
            ForEach(library.pinboards) { board in
                PinboardRow(library: library, board: board)
            }
            HStack {
                Spacer()
                addButton
            }
        }
    }

    private var addButton: some View {
        Button {
            library.createPinboard(name: String(localized: "New Pinboard", comment: "Default name of a pinboard created in Settings"))
        } label: {
            Label("Add Pinboard", systemImage: "plus")
        }
    }
}

private struct PinboardRow: View {
    let library: ClipLibrary
    let board: Pinboard
    @State private var name = ""

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Pinboard.tints, id: \.self) { tint in
                    Button {
                        library.updatePinboard(board.id) { $0.tint = tint }
                    } label: {
                        Label { Text(verbatim: tint.colorName) } icon: { Image(nsImage: Self.dot(tint)) }
                    }
                }
            } label: {
                Circle().fill(board.tint.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.black.opacity(0.1)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Pinboard color"))
            TextField(text: $name, prompt: Text("Name", comment: "Placeholder: pinboard name")) { Text("Name") }
                .textFieldStyle(.plain)
                .labelsHidden()
                .onSubmit(save)
                .onChange(of: name) { _, _ in save() }
            Spacer(minLength: 8)
            Text("\(board.items.count) items", comment: "Number of entries on a pinboard")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Button(role: .destructive) { library.deletePinboard(board.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(Text("Delete pinboard"))
                .accessibilityLabel(Text("Delete pinboard"))
        }
        .onAppear { name = board.name }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.updatePinboard(board.id) { $0.name = trimmed }
    }

    private static func dot(_ tint: Tint) -> NSImage {
        let size = CGSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            tint.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}

// MARK: Snippets

struct SnippetsEditor: View {
    let library: ClipLibrary
    @Binding var editing: SnippetDraft?

    var body: some View {
        if library.snippets.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "text.quote").font(.system(size: 20)).foregroundStyle(ClipStyle.snippetTint.color)
                RowLabel("No snippets yet", subtitle: "Signatures, addresses, replies and templates you paste often.")
                Spacer()
                addButton
            }
            .padding(.vertical, 2)
        } else {
            ForEach(library.snippets) { snippet in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(verbatim: snippet.name).fontWeight(.medium)
                            if !snippet.abbreviation.isEmpty {
                                Text(verbatim: snippet.abbreviation)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 6).frame(height: 18)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                        }
                        Text(verbatim: ClipText.firstLine(snippet.text, limit: 90))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { editing = SnippetDraft(snippet: snippet, isNew: false) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help(Text("Edit snippet"))
                        .accessibilityLabel(Text("Edit snippet"))
                    Button(role: .destructive) { library.deleteSnippet(snippet.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(Text("Delete snippet"))
                        .accessibilityLabel(Text("Delete snippet"))
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = SnippetDraft(snippet: snippet, isNew: false) }
            }
            HStack {
                Spacer()
                addButton
            }
        }
    }

    private var addButton: some View {
        Button {
            editing = SnippetDraft(snippet: Snippet(name: "", text: ""), isNew: true)
        } label: {
            Label("Add Snippet", systemImage: "plus")
        }
    }
}

/// Name, abbreviation and template of a snippet, with placeholder buttons and a live preview.
struct SnippetEditorView: View {
    @State var snippet: Snippet
    let isNew: Bool
    var onSave: (Snippet) -> Void = { _ in }
    var onDelete: (() -> Void)?
    var onCancel: () -> Void = {}
    @State private var selection: TextSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ModuleIcon(symbol: "text.quote", tint: ClipStyle.snippetTint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    (isNew ? Text("New Snippet") : Text("Edit Snippet")).font(.system(size: 17, weight: .bold))
                    Text("Pastes from the clipboard panel by name or abbreviation.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name", comment: "Snippet editor field").gridColumnAlignment(.trailing)
                    TextField(text: $snippet.name, prompt: Text("Email signature", comment: "Placeholder: example snippet name")) { Text("Name") }
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Abbreviation", comment: "Snippet editor field: short text that finds the snippet")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(text: $snippet.abbreviation, prompt: Text(verbatim: "sig")) { Text("Abbreviation") }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(maxWidth: 180)
                        Text("Type it in the panel’s search, then press Return.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Text", comment: "Snippet editor field: the snippet's content").fontWeight(.medium)
                    Spacer()
                    Text("Insert", comment: "Snippet editor: label before the placeholder buttons").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    ForEach(SnippetExpander.Placeholder.allCases) { p in
                        Button { insert(p.token) } label: {
                            Text(verbatim: p.title).font(.system(size: 11.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(p.help)
                    }
                }
                TextEditor(text: $snippet.text, selection: $selection)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120, maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview", comment: "Snippet editor: the expanded text").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                previewText
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) { Text("Delete", comment: "Button: delete the snippet") }
                }
                Spacer()
                Button(action: onCancel) { Text("Cancel") }.keyboardShortcut(.cancelAction)
                Button { onSave(trimmed) } label: { Text("Save", comment: "Button: save the snippet") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.text.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var trimmed: Snippet {
        var s = snippet
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.abbreviation = s.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.name.isEmpty { s.name = ClipText.firstLine(s.text, limit: 40) }
        return s
    }

    private var previewText: Text {
        let result = SnippetExpander.expand(snippet.text, clipboard: String(localized: "(clipboard text)", comment: "Snippet preview: stands in for the clipboard"))
        guard !result.text.isEmpty else { return Text("The expanded text appears here.").foregroundStyle(.tertiary) }
        guard let offset = result.cursorOffset else { return Text(verbatim: result.text) }
        let split = result.text.index(result.text.endIndex, offsetBy: -offset)
        var caret = AttributedString("|")
        caret.foregroundColor = .accentColor
        caret.font = .system(size: 12.5, weight: .bold)
        return Text(AttributedString(String(result.text[..<split])) + caret + AttributedString(String(result.text[split...])))
    }

    /// Inserts a placeholder at the insertion point (at the end when there is none).
    private func insert(_ token: String) {
        if case .selection(let range)? = selection?.indices, range.lowerBound >= snippet.text.startIndex,
           range.upperBound <= snippet.text.endIndex {
            let offset = snippet.text.distance(from: snippet.text.startIndex, to: range.lowerBound) + token.count
            snippet.text.replaceSubrange(range, with: token)
            let caret = snippet.text.index(snippet.text.startIndex, offsetBy: offset)
            selection = TextSelection(insertionPoint: caret)
        } else {
            snippet.text += token
        }
    }
}

// MARK: Excluded apps

/// The apps whose copies are never recorded, as removable chips with their icons.
/// Entries are bundle identifiers or app names (`[String].matches(app:)` accepts both).
struct ExcludedAppsList: View {
    @Binding var apps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if apps.isEmpty {
                Text("Every app is recorded.", comment: "Clipboard settings: the list of excluded apps is empty")
                    .foregroundStyle(.secondary)
            } else {
                ChipFlow(spacing: 6) {
                    ForEach(apps, id: \.self) { entry in chip(entry) }
                }
            }
            HStack(spacing: 10) {
                Menu {
                    let running = runningApps
                    if !running.isEmpty {
                        Section(String(localized: "Running", comment: "Menu section: apps that are running now")) {
                            ForEach(running, id: \.self) { app in
                                Button { add(app.bundleIdentifier ?? app.localizedName ?? "") } label: {
                                    Label {
                                        Text(verbatim: app.localizedName ?? app.bundleIdentifier ?? "")
                                    } icon: {
                                        if let icon = app.icon { Image(nsImage: Self.sized(icon)) }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button(String(localized: "Choose App…", comment: "Menu item: pick an app in a file dialog")) { choose() }
                } label: {
                    Label("Add App", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                if Set(apps) != Set(ClipboardSettings.defaultExcludedApps) {
                    Button("Restore Defaults") { apps = ClipboardSettings.defaultExcludedApps }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chip(_ entry: String) -> some View {
        let name = Self.displayName(entry)
        return HStack(spacing: 5) {
            if let icon = Self.icon(entry) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16, height: 16)
            }
            Text(verbatim: name).font(.system(size: 12)).lineLimit(1)
            Button { apps.removeAll { $0 == entry } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Remove \(name)", comment: "Tooltip: remove an app from the excluded apps; %@ is the app"))
            .accessibilityLabel(Text("Remove \(name)", comment: "Tooltip: remove an app from the excluded apps; %@ is the app"))
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .help(Text(verbatim: entry))
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !apps.matches(app: $0) }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ entry: String) {
        guard !entry.isEmpty, !apps.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) else { return }
        apps.append(entry)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add", comment: "Open dialog button: add the chosen apps to the excluded apps")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent)
        }
    }

    private static func isBundleID(_ entry: String) -> Bool {
        entry.contains(".") && !entry.contains(" ")
    }

    private static func appURL(_ entry: String) -> URL? {
        isBundleID(entry) ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) : nil
    }

    /// The app's name for a bundle identifier of an installed app; the entry itself otherwise.
    static func displayName(_ entry: String) -> String {
        guard let url = appURL(entry) else { return entry }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    /// The installed app's icon; nil when it isn't installed.
    static func icon(_ entry: String) -> NSImage? {
        AppIcons.icon(bundleID: isBundleID(entry) ? entry : nil, name: isBundleID(entry) ? nil : entry)
    }

    private static func sized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = CGSize(width: 16, height: 16)
        return copy
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: Hero

/// Both window styles as live miniatures (the current one highlighted), with the shortcut and status.
struct ClipboardHero: View {
    @Binding var style: ClipboardSettings.PanelStyle
    let showPreview: Bool
    let shortcut: Shortcut?
    let itemCount: Int
    let paused: Bool
    var onOpen: () -> Void = {}

    var body: some View {
        HeroCard(tint: .indigo) {
            HStack(alignment: .center, spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(ClipboardSettings.PanelStyle.allCases) { s in
                        Button { style = s } label: {
                            VStack(spacing: 6) {
                                MiniScreen(style: s, showPreview: showPreview)
                                    .frame(width: 168, height: 104)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(style == s ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: style == s ? 2.5 : 1))
                                Text(verbatim: s.title)
                                    .font(.system(size: 11.5, weight: style == s ? .semibold : .regular))
                                    .foregroundStyle(style == s ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(style == s ? .isSelected : [])
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        (style == .panel ? Text("Clipboard panel") : Text("Paste bar")).font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 8)
                        status
                    }
                    Text("↩ pastes into the app you came from, ⇧↩ as plain text, ⌘1…⌘9 the first nine. Tab switches to pinboards and snippets, ⌘K shows every action.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(action: onOpen) { Text("Open", comment: "Button: open the clipboard panel") }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                        if shortcut != nil { Keycaps(shortcut) }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(paused ? Tint.orange.color : Tint.green.color).frame(width: 7, height: 7)
            Group {
                if paused {
                    Text("Recording paused", comment: "Clipboard status in the settings hero")
                } else {
                    Text("\(itemCount) items", comment: "Clipboard history: number of saved entries")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// A tiny desktop with the panel or the paste bar on it.
struct MiniScreen: View {
    let style: ClipboardSettings.PanelStyle
    let showPreview: Bool

    private static let tiles: [(Tint, CGFloat)] = [(.blue, 0.62), (.mint, 0.8), (.pink, 0.45), (.indigo, 0.7), (.graphite, 0.55)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.36, green: 0.2, blue: 0.56),
                                        Color(red: 0.86, green: 0.52, blue: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.18)).frame(height: 5)
                switch style {
                case .panel: panel(width: w * 0.78, height: h * 0.66).offset(x: w * 0.11, y: h * 0.16)
                case .bar: bar(width: w - 12, height: h * 0.4).offset(x: 6, y: h - h * 0.4 - 6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func panel(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(.white.opacity(0.32)).frame(width: width * 0.36, height: 3).padding(6)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3.5) {
                    ForEach(Array(Self.tiles.enumerated()), id: \.offset) { i, tile in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1.5).fill(tile.0.color).frame(width: 6, height: 6)
                            Capsule().fill(.white.opacity(0.42)).frame(width: (showPreview ? width * 0.36 : width * 0.62) * tile.1, height: 2.5)
                        }
                        .padding(.horizontal, 3)
                        .frame(height: 9, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 2.5).fill(.white.opacity(i == 0 ? 0.16 : 0)))
                    }
                }
                .padding(4)
                if showPreview {
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Tint.blue.color, Tint.indigo.color], startPoint: .top, endPoint: .bottom))
                            .frame(height: height * 0.36)
                        Capsule().fill(.white.opacity(0.4)).frame(width: width * 0.22, height: 2.5)
                        Capsule().fill(.white.opacity(0.22)).frame(width: width * 0.16, height: 2.5)
                    }
                    .padding(5)
                    .frame(width: width * 0.4)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.15).opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule().fill(.white.opacity(0.3)).frame(width: width * 0.22, height: 2.5)
            HStack(spacing: 3.5) {
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { i, tile in
                    VStack(spacing: 0) {
                        Rectangle().fill(tile.0.color).frame(height: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(.white.opacity(0.4)).frame(height: 2)
                            Capsule().fill(.white.opacity(0.25)).frame(width: 12 * tile.1, height: 2)
                        }
                        .padding(2.5)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(i == 0 ? Color.accentColor : .clear, lineWidth: 1))
                }
            }
        }
        .padding(5)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.15).opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}
