import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Search state: every item, the ranked results and the selection.
@MainActor
@Observable
final class SearchModel {
    var query = "" { didSet { if query != oldValue { recompute(resetSelection: true) } } }
    var all: [BarEntry] = [] { didSet { recompute(resetSelection: false) } }
    private(set) var results: [BarEntry] = []
    var selection: String?
    var loading = false
    var trusted = true
    var focusRequest = 0

    @ObservationIgnored var onActivate: (String) -> Void = { _ in }
    @ObservationIgnored var onGrant: () -> Void = {}

    /// While nothing is typed, results sorted by app, with a heading for each app that has several
    /// items (single items name their app on their own row); one ranked list otherwise. An empty
    /// `app` means no heading.
    var groups: [(id: String, app: String, entries: [BarEntry])] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return [("ranked", "", results)] }
        var byApp: [(String, [BarEntry])] = []
        for e in results {
            if let last = byApp.indices.last, byApp[last].0 == e.appName { byApp[last].1.append(e) } else { byApp.append((e.appName, [e])) }
        }
        var out: [(id: String, app: String, entries: [BarEntry])] = []
        for (app, entries) in byApp {
            if entries.count > 1 {
                out.append((app, app, entries))
            } else if let last = out.indices.last, out[last].app.isEmpty {
                out[last].entries += entries
            } else {
                out.append(("single-\(app)", "", entries))
            }
        }
        return out
    }

    /// Re-ranks; a new query selects the best match, new entries keep the selection where possible.
    private func recompute(resetSelection: Bool) {
        let entries = all.map { SearchEntry(id: $0.id, title: $0.title, appName: $0.appName, section: $0.section) }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        results = MenuBarSearch.rank(entries, query: query).compactMap { byID[$0.id] }
        if resetSelection || !results.contains(where: { $0.id == selection }) { selection = results.first?.id }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let i = results.firstIndex { $0.id == selection } ?? -1
        selection = results[max(0, min(results.count - 1, i + delta))].id
    }
}

/// The search panel: a key-capable floating glass panel in the middle of the screen.
@MainActor
final class SearchController {
    let model = SearchModel()
    private var panel: FloatingPanel?
    private var monitor: Any?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }
    /// Called with the chosen item's id after the panel closed.
    var onChoose: (String) -> Void = { _ in }

    static let size = CGSize(width: 580, height: 470)

    func show() {
        let own = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == own ? nil : front
        let p = panel ?? makePanel()
        model.query = ""
        model.focusRequest += 1
        installMonitor()
        p.show(verticalFraction: 0.18)
    }

    func dismiss(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.dismiss()
        if restoreFocus { previousApp?.activate() }
    }

    func tearDown() {
        removeMonitor()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(size: Self.size)
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: SearchView(model: model) { [weak self] id in self?.choose(id) })
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.onClose = { [weak self] in self?.removeMonitor() }
        panel = p
        return p
    }

    private func choose(_ id: String) {
        dismiss(restoreFocus: true)
        // Give focus a moment to return before the item's menu opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { self?.onChoose(id) }
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, e.window === panel else { return false }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                switch Int(e.keyCode) {
                case 125: self.model.move(1)
                case 126: self.model.move(-1)
                case 36, 76:
                    guard let id = self.model.selection else { return true }
                    self.choose(id)
                case 53: self.dismiss(restoreFocus: true)
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Search field, list grouped by app, keyboard hints.
struct SearchView: View {
    @Bindable var model: SearchModel
    var choose: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                SearchTextField(text: $model.query, placeholder: String(localized: "Search menu bar items", comment: "Search field placeholder"),
                                focusRequest: model.focusRequest)
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if !model.trusted { accessBanner }
            content
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            footer
        }
        .frame(width: SearchController.size.width, height: SearchController.size.height)
        .barSurface(cornerRadius: 20)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        if model.results.isEmpty {
            Group {
                if !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if model.loading {
                    ProgressView { Text("Reading the menu bar…") }
                } else {
                    ContentUnavailableView {
                        Label("No menu bar items", systemImage: "menubar.rectangle")
                    } description: {
                        Text("Items appear here as apps add them to the menu bar.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.groups, id: \.id) { group in
                            if !group.app.isEmpty {
                                Text(verbatim: group.app)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.entries) { entry in
                                SearchRow(entry: entry, selected: entry.id == model.selection, hovered: entry.id == hovered,
                                          showsApp: group.app.isEmpty)
                                    .id(entry.id)
                                    .onHover { inside in if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil } }
                                    .onTapGesture {
                                        model.selection = entry.id
                                        choose(entry.id)
                                    }
                            }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 15)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Accessibility access needed").font(.system(size: 12.5, weight: .semibold))
                Text("Without it, search lists apps instead of their items, and opening one shows it in the menu bar for you to click.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Grant Access") { model.onGrant() }
                .buttonStyle(GlassProminentButtonStyle(fill: .white.opacity(0.16)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], Text("Select", comment: "Search footer: arrow keys select an item"))
            hint(["↩"], Text("Open", comment: "Search footer: Return opens the selected menu bar item"))
            hint(["esc"], Text("Close", comment: "Search footer: Escape closes search"))
            Spacer()
            Text("\(model.results.count) items", comment: "Search footer: number of menu bar items listed")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func hint(_ keys: [String], _ label: Text) -> some View {
        HStack(spacing: 6) {
            Keycaps(keys, dark: true)
            label.font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct SearchRow: View {
    let entry: BarEntry
    let selected: Bool
    let hovered: Bool
    let showsApp: Bool

    var body: some View {
        HStack(spacing: 12) {
            EntryIcon(icon: entry.icon, size: 20)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.18 : 0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                if showsApp && entry.title != entry.appName {
                    Text(verbatim: entry.appName).font(.system(size: 11.5)).foregroundStyle(.white.opacity(selected ? 0.8 : 0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if entry.section != .visible {
                Text(entry.section.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(selected ? 0.22 : 0.1)))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
            }
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.9) : .white.opacity(hovered ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

/// A borderless search field that takes focus whenever `focusRequest` changes.
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 19),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text && !composing { field.stringValue = text }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        /// The panel bumps `focusRequest` each time it opens; 0 (never opened, as in previews) leaves focus alone.
        var lastFocus = 0

        init(_ parent: SearchTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
