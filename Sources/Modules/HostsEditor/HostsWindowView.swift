import AppKit
import MacToysCore
import SwiftUI

/// Design 07 "Hosts File Editor": entries with on/off switches, addresses, hosts, comments and ping.
struct HostsWindowView: View {
    @Bindable var model: HostsEditorModel
    var chrome = false
    @State private var editing: EntryDraft?
    @State private var editingHeader = false
    @State private var showFilters = false
    @State private var showStartWarning = false
    @State private var confirmDelete: Set<UUID>?

    var body: some View {
        VStack(spacing: 0) {
            if chrome {
                PreviewTitleBar(title: String(localized: "Hosts File Editor"), symbol: "server.rack", tint: .green) { toolbarButtons(preview: true) }
            }
            banner
            table
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 380)
        .navigationTitle("Hosts File Editor")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Address, host or comment")
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { toolbarButtons(preview: false) } }
        .sheet(item: $editing) { draft in
            EntryEditor(draft: draft, others: model.document.entries,
                        loopbackDuplicates: model.settings.value.loopbackDuplicates) { result in
                if let result {
                    if draft.isNew { model.add(result) } else { model.update(result) }
                }
                editing = nil
            }
        }
        .sheet(isPresented: $editingHeader) {
            HeaderEditor(lines: model.document.header) { lines in
                if let lines { model.document.setHeader(lines) }
                editingHeader = false
            }
        }
        .alert("Editing the hosts file changes how this Mac finds servers", isPresented: $showStartWarning) {
            Button("Don't Show Again") { model.settings.value.showWarningOnStart = false }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Entries here override DNS for every app. A wrong entry can make websites or services unreachable. MacToys keeps a backup before each save.")
        }
        .confirmationDialog(Text("Delete \(confirmDelete?.count ?? 0) entries?", comment: "Confirmation: number of hosts entries to delete"),
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let ids = confirmDelete { model.delete(ids) }; confirmDelete = nil }
        }
        .onAppear { if !chrome && model.settings.value.showWarningOnStart { showStartWarning = true } }
    }

    @ViewBuilder private func toolbarButtons(preview: Bool) -> some View {
        if preview {
            Image(systemName: "magnifyingglass").frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
        Button { showFilters.toggle() } label: {
            Image(systemName: model.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .help("Filter entries")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) { FilterPopover(model: model) }
        Button("New entry") { editing = EntryDraft(entry: HostsEntry(address: "", hosts: []), isNew: true) }
            .keyboardShortcut("n", modifiers: .command)
        Button {
            model.save()
        } label: {
            if model.saving { ProgressView().controlSize(.small) } else { Text("Save") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.isDirty || model.saving)
        .keyboardShortcut("s", modifiers: .command)
    }

    @ViewBuilder private var banner: some View {
        VStack(spacing: 0) {
            if let m = model.message {
                InfoBar(m.kind, title: Text(verbatim: m.title), message: Text(verbatim: m.text), actionTitle: Text("Dismiss")) {
                    model.message = nil
                }
                    .padding(10)
            } else if model.changedOnDisk {
                InfoBar(.warning, title: "The hosts file changed on disk", message: "Reload to see it; your unsaved edits will be lost.",
                        actionTitle: "Reload") { model.load() }
                    .padding(10)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Saving asks for your administrator password").font(.system(size: 12.5, weight: .semibold))
                        (model.settings.value.backupsEnabled
                            ? Text("A backup is written to ~/Library/Application Support/MacToys/Hosts before every change.")
                            : Text("Backups are off in Settings."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isDirty {
                        Text("Unsaved changes").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
                        Button("Revert") { model.revert() }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.08))
            }
            Divider()
        }
    }

    private var table: some View {
        let dupes = model.duplicates
        return Table(model.visibleEntries, selection: $model.selection) {
            TableColumn(Text("On", comment: "Column: the hosts entry is active")) { e in
                Toggle("Active", isOn: Binding(get: { e.active }, set: { model.setActive(e.id, $0) }))
                    .toggleStyle(.adaptiveSwitch).labelsHidden().controlSize(.small)
            }
            .width(46)
            TableColumn("Address") { e in
                HStack(spacing: 4) {
                    Text(e.address).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(e.active ? Color.primary : .secondary)
                    issueIcon(e)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Hosts") { e in
                Text(e.hosts.joined(separator: "  ")).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(dupes[e.id] != nil ? Tint.orange.color : (e.active ? Color.primary : .secondary))
                    .help(dupes[e.id].map {
                        String(localized: "Also mapped elsewhere: \($0.sorted().joined(separator: ", "))", comment: "The placeholder lists host names")
                    } ?? e.hostsText)
                    .lineLimit(1)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Comment") { e in
                Text(e.comment).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Ping") { e in pingLabel(model.pings[e.address]) }
                .width(min: 80, ideal: 90)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let e = model.entry(id) {
                Button("Edit…") { editing = EntryDraft(entry: e, isNew: false) }
                Button("Duplicate") { model.duplicate(id) }
                Button { model.setActive(id, !e.active) } label: {
                    e.active ? Text("Disable", comment: "Comment out the hosts entry") : Text("Enable", comment: "Uncomment the hosts entry")
                }
                Button("Ping") { model.ping(e.address) }
                Button("Copy Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.original ?? e.rendered(lineEnding: "\n"), forType: .string)
                }
                Divider()
                Button("Move Up") { model.document.move(id, by: -1) }
                Button("Move Down") { model.document.move(id, by: 1) }
                Divider()
            }
            if !ids.isEmpty { Button("Delete", role: .destructive) { confirmDelete = ids } }
        } primaryAction: { ids in
            if let id = ids.first, let e = model.entry(id) { editing = EntryDraft(entry: e, isNew: false) }
        }
        .onDeleteCommand { if !model.selection.isEmpty { confirmDelete = model.selection } }
        .overlay {
            if model.loaded && model.visibleEntries.isEmpty {
                if model.document.entries.isEmpty {
                    ContentUnavailableView("No entries", systemImage: "server.rack", description: Text("Add one with New entry."))
                } else {
                    ContentUnavailableView("No matching entries", systemImage: "server.rack", description: Text("Clear the search or filters."))
                }
            }
        }
    }

    @ViewBuilder private func issueIcon(_ e: HostsEntry) -> some View {
        let issues = HostsValidator.issues(e)
        if !issues.isEmpty {
            Image(systemName: issues.contains(where: \.isError) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issues.contains(where: \.isError) ? .red : .orange)
                .font(.system(size: 11))
                .help(issues.map(\.message).joined(separator: "\n"))
        }
    }

    @ViewBuilder private func pingLabel(_ state: PingState?) -> some View {
        switch state {
        case .reply(let ms)?:
            Label {
                Text(Measurement(value: ms, unit: UnitDuration.milliseconds)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(.fractionLength(ms < 1 ? 2 : 0)))))
            } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .font(.system(size: 11.5))
        case .noReply?:
            Label { Text("No reply") } icon: { Circle().fill(.red).frame(width: 7, height: 7) }
                .font(.system(size: 11.5))
        case .pending?:
            ProgressView().controlSize(.mini)
        case .skipped?, nil:
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        let entries = model.document.entries
        let disabled = entries.filter { !$0.active }.count
        let dupes = model.duplicates.count
        var parts = [String(localized: "\(entries.count) entries", comment: "Number of hosts entries"),
                     String(localized: "\(disabled) disabled", comment: "Number of disabled hosts entries")]
        if dupes > 0 { parts.append(String(localized: "\(dupes) with duplicate hosts", comment: "Number of hosts entries with duplicate host names")) }
        return HStack(spacing: 12) {
            Text(verbatim: parts.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Button("Ping All") { model.pingAll() }.controlSize(.small)
            Button("Header Comments…") { editingHeader = true }.controlSize(.small)
            Button("Open in TextEdit") {
                NSWorkspace.shared.open([URL(fileURLWithPath: model.path)],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Sample data for `MacToys --snapshot`.
    @MainActor
    static func preview() -> some View {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let settings = Persisted("hosts", default: HostsSettings(), store: SettingsStore(directory: dir))
        let model = HostsEditorModel(path: "/dev/null", settings: settings)
        model.document = HostsDocument.parse(HostsPreview.sample)
        model.loaded = true
        for (address, state) in [("127.0.0.1", PingState.reply(12)), ("255.255.255.255", .noReply), ("::1", .reply(12)),
                                 ("10.0.4.12", .reply(12)), ("192.168.1.20", .noReply), ("0.0.0.0", .skipped)] {
            model.pings[address] = state
        }
        if let docker = model.document.entries.first(where: { $0.address == "10.0.4.12" }) { model.selection = [docker.id] }
        return HostsWindowView(model: model, chrome: true).background(Color(nsColor: .windowBackgroundColor))
    }
}

enum HostsPreview {
    static let sample = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost\t# Loopback
    255.255.255.255\tbroadcasthost
    ::1\tlocalhost\t# IPv6 loopback
    10.0.4.12\tapi.dev.local web.dev.local\t# Docker dev stack
    # 0.0.0.0\tads.example.com tracker.example.net\t# Blocked
    192.168.1.20\tnas.home\t# Synology

    """
}

/// An entry being added or edited.
struct EntryDraft: Identifiable {
    var entry: HostsEntry
    var isNew: Bool
    var id: UUID { entry.id }
}

private struct EntryEditor: View {
    @State private var address: String
    @State private var hostsText: String
    @State private var comment: String
    @State private var active: Bool
    let draft: EntryDraft
    let others: [HostsEntry]
    let loopbackDuplicates: Bool
    let done: (HostsEntry?) -> Void

    init(draft: EntryDraft, others: [HostsEntry], loopbackDuplicates: Bool, done: @escaping (HostsEntry?) -> Void) {
        self.draft = draft
        self.others = others
        self.loopbackDuplicates = loopbackDuplicates
        self.done = done
        _address = State(initialValue: draft.entry.address)
        _hostsText = State(initialValue: draft.entry.hostsText)
        _comment = State(initialValue: draft.entry.comment)
        _active = State(initialValue: draft.entry.active)
    }

    private var result: HostsEntry {
        var e = draft.entry
        e.address = address.trimmingCharacters(in: .whitespaces)
        e.hosts = hostsText.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        e.comment = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        e.active = active
        return e
    }

    private var issues: [HostsValidator.Issue] {
        let e = result
        var list = HostsValidator.issues(e)
        let all = others.filter { $0.id != e.id } + [e]
        if let hosts = HostsValidator.duplicates(all, loopbackDuplicates: loopbackDuplicates)[e.id] {
            list += hosts.sorted().map { .duplicate($0) }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (draft.isNew ? Text("New Entry") : Text("Edit Entry")).font(.title3.bold())
            Form {
                TextField("Address", text: $address, prompt: Text("127.0.0.1 or ::1"))
                    .font(.system(.body, design: .monospaced))
                TextField("Hosts", text: $hostsText, prompt: Text(verbatim: "example.local www.example.local"))
                    .font(.system(.body, design: .monospaced))
                TextField("Comment", text: $comment, prompt: Text("Optional"))
                Toggle("Active", isOn: $active)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 210)
            if !issues.isEmpty && !address.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: issue.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.isError ? .red : .orange)
                            .font(.system(size: 12))
                    }
                }
            }
            Text("Separate several host names with spaces. Turn Active off to keep the entry commented out.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button { done(result) } label: { draft.isNew ? Text("Add") : Text("Save") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(issues.contains(where: \.isError) || address.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// "Additional lines": the comments at the top of the file.
private struct HeaderEditor: View {
    @State private var text: String
    let done: ([String]?) -> Void

    init(lines: [String], done: @escaping ([String]?) -> Void) {
        _text = State(initialValue: lines.joined(separator: "\n"))
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header Comments").font(.title3.bold())
            Text("The lines before the first entry. Lines that aren't comments are kept as they are; new entries go below these when placement is Top.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    var lines = text.components(separatedBy: "\n")
                    while lines.last == "" && lines.count > 1 { lines.removeLast() }
                    // Header lines that parse as mappings would become entries; keep them commented.
                    lines = lines.map { l in HostsDocument.parseEntry(l)?.active == true ? "# " + l : l }
                    done(text.isEmpty ? [] : lines)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

private struct FilterPopover: View {
    @Bindable var model: HostsEditorModel

    var body: some View {
        Form {
            TextField("Address", text: $model.addressFilter)
            TextField("Hosts", text: $model.hostFilter)
            TextField("Comment", text: $model.commentFilter)
            Toggle("Active entries only", isOn: $model.activeOnly)
            Toggle("Duplicates only", isOn: $model.duplicatesOnly)
            Button("Clear Filters") { model.clearFilters() }.disabled(!model.hasFilters)
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// A unified-toolbar look-alike for offscreen previews (real windows use the native toolbar).
struct PreviewTitleBar<Actions: View>: View {
    let title: String
    let symbol: String
    let tint: Tint
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c.opacity(0.85)).frame(width: 12, height: 12) }
            }
            .padding(.trailing, 10)
            ModuleIcon(symbol: symbol, tint: tint, size: 22)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            actions
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
