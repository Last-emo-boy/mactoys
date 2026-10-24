import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Connects a document view to its window (title, proxy icon, edited dot) and the module.
@MainActor
final class PlistWindowContext {
    weak var window: NSWindow?
    weak var module: PlistPreviewModule?

    func update(_ doc: PlistDocument) {
        window?.title = doc.displayName
        window?.representedURL = doc.fileURL
        window?.isDocumentEdited = doc.isDirty
    }
}

/// Design 07 "Plist Preview": an outline with Key / Type / Value columns.
struct PlistDocumentView: View {
    @Bindable var doc: PlistDocument
    let context: PlistWindowContext
    var chrome = false
    @State private var confirmWrite = false
    @State private var domainText = ""
    @State private var showDiff = false

    var body: some View {
        VStack(spacing: 0) {
            if chrome {
                PreviewTitleBar(title: doc.displayName, symbol: "list.bullet.indent", tint: .brown) { primaryActions(preview: true) }
            }
            if let m = doc.message {
                InfoBar(m.kind, title: m.kind == .error ? "Problem" : (m.kind == .warning ? "Note" : "Done"), message: m.text,
                        actionTitle: "Dismiss") { doc.message = nil }
                    .padding(10)
                Divider()
            }
            PlistOutlineView(doc: doc)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle(doc.displayName)
        .searchable(text: $doc.searchText, placement: .toolbar, prompt: "Keys and values")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!doc.canUndo).keyboardShortcut("z", modifiers: .command).help("Undo")
                Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!doc.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
            }
            ToolbarItemGroup(placement: .primaryAction) { primaryActions(preview: false) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { context.module?.open([url], replacing: doc) } }
                }
            }
            return true
        }
        .onChange(of: doc.isDirty) { context.update(doc) }
        .onChange(of: doc.fileURL) { context.update(doc) }
        .alert("Write to defaults?", isPresented: $confirmWrite) {
            TextField("Domain", text: $domainText)
            Button("Write", role: .destructive) { writeToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every setting of the domain with this document (defaults import). Apps using it may need to be relaunched.")
        }
        .sheet(isPresented: $showDiff) { DiffSheet(doc: doc) { showDiff = false } }
    }

    @ViewBuilder private func primaryActions(preview: Bool) -> some View {
        if preview {
            Image(systemName: "magnifyingglass").frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
        Menu {
            Button("Add Item") { doc.add(near: doc.selection) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Duplicate") { if let s = doc.selection { doc.duplicate(s) } }.disabled(doc.selection == nil || doc.selection == doc.root.id)
            Button("Delete") { if let s = doc.selection { doc.delete(s) } }.disabled(doc.selection == nil || doc.selection == doc.root.id)
            Divider()
            Button("Copy Key Path") { if let s = doc.selection { doc.copyKeyPath(s) } }.disabled(doc.selection == nil)
            Button("Expand All") { doc.expandAll() }
            Button("Collapse All") { doc.collapseAll() }
            Divider()
            Button("Compare with \(doc.fileURL == nil ? "Defaults" : "File on Disk")…") {
                do { try doc.compareWithSource(); showDiff = true } catch { doc.message = .init(kind: .error, text: error.localizedDescription) }
            }
            .disabled(doc.fileURL == nil && doc.domain == nil)
            Button("Reload from Disk") {
                do { try doc.reload() } catch { doc.message = .init(kind: .error, text: error.localizedDescription) }
            }
            .disabled(doc.fileURL == nil)
            Button("Save As…") { context.module?.saveAs(doc) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(doc.readOnly)
        .help("More")
        Button("Save") { context.module?.save(doc) }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(doc.readOnly || !(doc.isDirty || doc.fileURL == nil))
        Button("Write to defaults") {
            domainText = doc.domain ?? doc.fileURL?.deletingPathExtension().lastPathComponent ?? ""
            confirmWrite = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(doc.readOnly || doc.root.type != .dictionary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Format", selection: Binding(get: { doc.format }, set: { f in
                if f == .json && !doc.root.isJSONCompatible {
                    doc.message = .init(kind: .error, text: "This document has dates or data, which JSON can't hold.")
                } else {
                    doc.format = f
                }
            })) {
                ForEach([PlistFormat.xml, .binary, .json], id: \.self) { Text($0.title).tag($0) }
                if doc.format == .openStep { Text(PlistFormat.openStep.title).tag(PlistFormat.openStep) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(doc.readOnly)
            .help("Format used when saving")
            if let s = doc.selection, let path = doc.keyPath(s) {
                Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if doc.isDirty { Text("Edited").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Text(doc.fileURL?.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                 ?? (doc.domain.map { "defaults domain \($0)" } ?? "Not saved"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func writeToDefaults() {
        let domain = domainText.trimmingCharacters(in: .whitespaces)
        guard !domain.isEmpty else { return }
        do {
            try doc.writeToDefaults(domain: domain)
            context.module?.offerRelaunch(for: domain)
        } catch {
            doc.message = .init(kind: .error, text: error.localizedDescription)
        }
    }

    /// The Dock's preferences, as in the design board.
    @MainActor
    static func preview() -> some View {
        func item(_ name: String) -> PlistNode {
            PlistNode(value: .dictionary([
                PlistNode(key: "GUID", value: .integer(Int64(abs(name.hashValue % 900_000_000)))),
                PlistNode(key: "tile-data", value: .dictionary([PlistNode(key: "file-label", value: .string(name))])),
                PlistNode(key: "tile-type", value: .string("file-tile")),
            ]))
        }
        let apps = ["Safari", "Mail", "Xcode", "Terminal", "Music", "Notes", "Calendar", "Photos", "System Settings"].map(item)
        let root = PlistNode(value: .dictionary([
            PlistNode(key: "autohide", value: .boolean(true)),
            PlistNode(key: "tilesize", value: .integer(48)),
            PlistNode(key: "orientation", value: .string("bottom")),
            PlistNode(key: "persistent-apps", value: .array(apps)),
            PlistNode(key: "mru-spaces", value: .boolean(false)),
            PlistNode(key: "wvous-br-corner", value: .integer(14)),
            PlistNode(key: "largesize", value: .integer(72)),
            PlistNode(key: "magnification", value: .boolean(false)),
            PlistNode(key: "mineffect", value: .string("scale")),
            PlistNode(key: "minimize-to-application", value: .boolean(true)),
            PlistNode(key: "show-recents", value: .boolean(false)),
            PlistNode(key: "show-process-indicators", value: .boolean(true)),
            PlistNode(key: "autohide-delay", value: .real(0.2)),
            PlistNode(key: "launchanim", value: .boolean(true)),
            PlistNode(key: "expose-group-apps", value: .boolean(false)),
            PlistNode(key: "persistent-others", value: .array([])),
            PlistNode(key: "mod-count", value: .integer(212)),
            PlistNode(key: "lastShowIndicatorTime", value: .date(Date(timeIntervalSince1970: 1_792_000_000))),
        ]))
        let doc = PlistDocument(root: root, fileURL: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"),
                                format: .binary, domain: "com.apple.dock")
        let persistent = root.children?[3].id
        doc.expanded = Set([root.id] + [persistent].compactMap { $0 })
        doc.selection = root.children?[1].id
        return PlistDocumentView(doc: doc, context: PlistWindowContext(), chrome: true)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The outline: indentation, disclosure chevrons, inline editors.
struct PlistOutlineView: View {
    @Bindable var doc: PlistDocument

    var body: some View {
        let rows = doc.rows
        let searching = doc.matches != nil
        Table(rows, selection: $doc.selection) {
            TableColumn("Key") { row in
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                    if row.node.isContainer {
                        Button { doc.toggleExpanded(row.id) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(searching || doc.expanded.contains(row.id) ? 90 : 0))
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(searching)
                    } else {
                        Text("·").foregroundStyle(.tertiary).frame(width: 14)
                    }
                    if row.depth > 0 && row.arrayIndex == nil && !doc.readOnly {
                        EditableText(value: row.node.key, font: .system(size: 12, design: .monospaced)) { doc.rename(row.id, to: $0) }
                    } else {
                        Text(row.displayKey).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(row.arrayIndex != nil ? Color.primary.opacity(0.75) : .primary)
                    }
                }
            }
            .width(min: 160, ideal: 300)
            TableColumn("Type") { row in
                if doc.readOnly {
                    Text(row.node.type.title).foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(PlistType.allCases.filter { row.depth > 0 || $0.isContainer }) { t in
                            Button(t.title) { doc.changeType(row.id, to: t) }
                        }
                    } label: {
                        Text(row.node.type.title).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .width(min: 80, ideal: 100, max: 130)
            TableColumn("Value") { row in ValueCell(doc: doc, node: row.node) }
                .width(min: 140, ideal: 260)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, !doc.readOnly {
                Button("Add Item") { doc.add(near: id) }
                if id != doc.root.id {
                    Button("Duplicate") { doc.duplicate(id) }
                    Button("Move Up") { doc.move(id, by: -1) }
                    Button("Move Down") { doc.move(id, by: 1) }
                }
                Menu("Change Type") {
                    ForEach(PlistType.allCases.filter { id != doc.root.id || $0.isContainer }) { t in
                        Button(t.title) { doc.changeType(id, to: t) }
                    }
                }
                Divider()
            }
            if let id = ids.first {
                Button("Copy Key Path") { doc.copyKeyPath(id) }
                Button("Copy Value") {
                    if let n = doc.root.node(id) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.isContainer ? n.summary : n.valueText, forType: .string)
                    }
                }
            }
            if let id = ids.first, id != doc.root.id, !doc.readOnly {
                Divider()
                Button("Delete", role: .destructive) { doc.delete(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first, doc.root.node(id)?.isContainer == true { doc.toggleExpanded(id) }
        }
        .onDeleteCommand { if let s = doc.selection, !doc.readOnly { doc.delete(s) } }
    }
}

private struct ValueCell: View {
    let doc: PlistDocument
    let node: PlistNode

    var body: some View {
        switch node.value {
        case .dictionary, .array:
            Text(node.summary).font(.system(size: 12, design: .monospaced))
        case .boolean(let b):
            if doc.readOnly {
                Text(b ? "YES" : "NO").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.purple)
            } else {
                Menu {
                    Button("YES") { doc.setValue(node.id, .boolean(true)) }
                    Button("NO") { doc.setValue(node.id, .boolean(false)) }
                } label: {
                    Text(b ? "YES" : "NO").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.purple)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        case .date(let d):
            if doc.readOnly {
                Text(d.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12, design: .monospaced))
            } else {
                DatePicker("", selection: Binding(get: { d }, set: { doc.setValue(node.id, .date($0)) }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.field).controlSize(.small)
            }
        default:
            if doc.readOnly {
                Text(node.valueText).font(.system(size: 12, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            } else {
                EditableText(value: node.valueText, font: .system(size: 12, design: .monospaced)) { doc.setValue(node.id, text: $0) }
            }
        }
    }
}

/// A plain text field that commits on Return or when it loses focus; invalid input snaps back.
struct EditableText: View {
    let value: String
    let font: Font
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(value: String, font: Font, commit: @escaping (String) -> Bool) {
        self.value = value
        self.font = font
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onChange(of: value) { _, v in if !focused { draft = v } }
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
    }

    private func apply() {
        guard draft != value else { return }
        if !commit(draft) { draft = value }
    }
}

private struct DiffSheet: View {
    let doc: PlistDocument
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compared with \(doc.fileURL == nil ? "defaults domain \(doc.domain ?? "")" : "the file on disk")").font(.title3.bold())
            if let diffs = doc.differences, !diffs.isEmpty {
                Table(diffs) {
                    TableColumn("") { d in
                        Image(systemName: d.kind == .added ? "plus.circle.fill" : (d.kind == .removed ? "minus.circle.fill" : "pencil.circle.fill"))
                            .foregroundStyle(d.kind == .added ? .green : (d.kind == .removed ? .red : .orange))
                    }
                    .width(22)
                    TableColumn("Key path") { d in Text(PlistNode.keyPath(d.path)).font(.system(size: 12, design: .monospaced)) }
                    TableColumn("On disk") { d in Text(d.old ?? "—").foregroundStyle(.secondary).lineLimit(2) }
                    TableColumn("This document") { d in Text(d.new ?? "—").lineLimit(2) }
                }
            } else {
                ContentUnavailableView("No differences", systemImage: "checkmark.circle",
                                       description: Text("The document matches what's saved."))
            }
            HStack {
                Text("\(doc.differences?.count ?? 0) difference\(doc.differences?.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 440)
    }
}

/// Browses `defaults domains` read-only; any domain can be opened as an editable document.
struct DefaultsBrowserView: View {
    let module: PlistPreviewModule
    @State private var domains: [String] = []
    @State private var filter = ""
    @State private var selected: String?
    @State private var doc: PlistDocument?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Filter domains", text: $filter).textFieldStyle(.roundedBorder).padding(8)
                List(domains.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self, selection: $selected) { d in
                    Text(d).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                if let doc {
                    PlistOutlineView(doc: doc)
                } else if let error {
                    ContentUnavailableView("Couldn't read the domain", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Choose a domain", systemImage: "list.bullet.indent",
                                           description: Text("Preferences are shown read-only. Open one as a document to edit and write it back."))
                }
                Divider()
                HStack {
                    Text(selected.map { "defaults export \($0) -" } ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { load() }.disabled(selected == nil)
                    Button("Open as Document") {
                        if let selected, let doc { module.openDomain(selected, root: doc.root) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(doc == nil)
                }
                .padding(10)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .navigationTitle("Defaults Domains")
        .task {
            let list = await Task.detached { DefaultsDomains.list() }.value
            domains = list
        }
        .onChange(of: selected) { load() }
    }

    private func load() {
        guard let selected else { return }
        error = nil
        let domain = selected
        Task {
            let result: Result<PlistNode, Error> = await Task.detached {
                do { return .success(try DefaultsDomains.export(domain)) } catch { return .failure(error) }
            }.value
            guard self.selected == domain else { return }
            switch result {
            case .success(let root):
                let d = PlistDocument(root: root, domain: domain)
                d.readOnly = true
                doc = d
            case .failure(let e):
                doc = nil
                error = e.localizedDescription
            }
        }
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
