import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// State of the "New from template…" picker.
@MainActor
@Observable
final class NewPlusPickerModel {
    var templates: [NewPlusTemplate]
    var destination: URL
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    let hideExtension: Bool
    let hideLeadingDigits: Bool

    init(templates: [NewPlusTemplate], destination: URL, hideExtension: Bool, hideLeadingDigits: Bool) {
        self.templates = templates
        self.destination = destination
        self.hideExtension = hideExtension
        self.hideLeadingDigits = hideLeadingDigits
    }

    func title(_ t: NewPlusTemplate) -> String {
        t.title(hideExtension: hideExtension, hideLeadingDigits: hideLeadingDigits)
    }

    var filtered: [NewPlusTemplate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return templates }
        return templates.filter { title($0).localizedCaseInsensitiveContains(q) || $0.fileName.localizedCaseInsensitiveContains(q) }
    }

    var selected: NewPlusTemplate? {
        let list = filtered
        return list.indices.contains(selection) ? list[selection] : list.first
    }

    func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }
}

struct NewPlusPickerView: View {
    @Bindable var model: NewPlusPickerModel
    var onCreate: (NewPlusTemplate) -> Void = { _ in }
    var onChooseFolder: () -> Void = {}
    var onOpenTemplates: () -> Void = {}
    @FocusState private var searchFocused: Bool
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(14)
                Divider().opacity(0.4)
                list
                Divider().opacity(0.4)
                footer.padding(.horizontal, 14).padding(.vertical, 10)
            }
            // Glass adapts text to the backdrop; keep it light on the dark tint.
            .foregroundStyle(.white)
        }
        .frame(width: 400)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ModuleIcon(symbol: "doc.badge.plus", tint: .green, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New from template").font(.system(size: 14, weight: .semibold))
                    Button(action: onChooseFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill").font(.system(size: 10))
                            Text("in \(model.destination.lastPathComponent)", comment: "New+ picker: the folder the new item is created in")
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Self.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.destination.path)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Self.secondary)
                TextField("Search templates", text: $model.query, prompt: Text("Search templates").foregroundStyle(Self.tertiary))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let t = model.selected { onCreate(t) } }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
        }
    }

    private var list: some View {
        let items = model.filtered
        return Group {
            if items.isEmpty {
                (model.templates.isEmpty ? Text("The templates folder is empty.") : Text("No template matches “\(model.query)”."))
                    .font(.system(size: 12)).foregroundStyle(Self.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                                row(t, selected: i == min(model.selection, items.count - 1))
                                    .id(t.id)
                                    .onTapGesture { model.selection = i; onCreate(t) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(items.count) * 42 + 12, 300))
                    .onChange(of: model.selection) { _, s in
                        if items.indices.contains(s) { proxy.scrollTo(items[s].id) }
                    }
                }
            }
        }
    }

    private func row(_ t: NewPlusTemplate, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: TemplateIcons.icon(for: t)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.title(t)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: TemplateIcons.kind(of: t)).font(.system(size: 11)).foregroundStyle(Self.secondary).lineLimit(1)
            }
            Spacer()
            if selected { Text(verbatim: "↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.secondary) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Button("Open Templates Folder", action: onOpenTemplates).buttonStyle(.link).font(.system(size: 12))
            Spacer()
            Text("esc to close", comment: "New+ picker hint: press the Escape key to close").font(.system(size: 11)).foregroundStyle(Self.tertiary)
        }
    }
}

/// Finder icons and kind names for templates.
@MainActor
enum TemplateIcons {
    static func icon(for t: NewPlusTemplate) -> NSImage {
        if FileManager.default.fileExists(atPath: t.url.path) { return NSWorkspace.shared.icon(forFile: t.url.path) }
        if t.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: t.url.pathExtension) ?? .data)
    }

    static func kind(of t: NewPlusTemplate) -> String {
        if t.isFolder { return String(localized: "Folder", comment: "New+ picker: kind of a folder template") }
        let type = (try? t.url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: t.url.pathExtension)
        return type?.localizedDescription ?? String(localized: "Document", comment: "New+ picker: kind of a file of unknown type")
    }
}

/// The floating panel that hosts the picker.
@MainActor
final class NewPlusPickerPanel {
    private var panel: FloatingPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show<V: View>(_ view: V) {
        let p = panel ?? FloatingPanel(size: CGSize(width: 400, height: 420))
        p.setContent(view)
        if let host = p.contentView {
            host.layoutSubtreeIfNeeded()
            p.setContentSize(host.fittingSize)
        }
        panel = p
        p.show(verticalFraction: 0.2)
    }

    func close() {
        panel?.dismiss()
    }

    /// Keeps the panel open while a modal (folder chooser) runs.
    var hidesOnResign: Bool {
        get { panel?.hidesOnResign ?? true }
        set { panel?.hidesOnResign = newValue }
    }
}
