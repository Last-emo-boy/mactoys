import AppKit
import MacToysCore
import SwiftUI

/// The search field: an AppKit field so the panel can hand it the keyboard on demand and leave
/// keys an input method is composing alone.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 18
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        setPlaceholder(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text, !composing {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        setPlaceholder(field)
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                let length = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
            }
        }
    }

    private func setPlaceholder(_ field: NSTextField) {
        guard field.placeholderString != placeholder else { return }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.36), .font: NSFont.systemFont(ofSize: fontSize),
        ])
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelSearchField
        var lastFocus = -1

        init(_ parent: PanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// History · pinboards · Snippets, as chips. Pinboard chips take entries dragged onto them.
struct SourceStrip: View {
    @Bindable var model: ClipboardPanelModel
    var compact = false
    @Environment(\.clipStyle) private var style
    @State private var dropTarget: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(.history, symbol: "clock.arrow.circlepath", tint: nil, count: nil)
                ForEach(model.library.pinboards) { board in
                    chip(.pinboard(board.id), symbol: nil, tint: board.tint, count: board.items.count)
                        .onDrop(of: [.data], isTargeted: Binding(get: { dropTarget == board.id },
                                                                  set: { dropTarget = $0 ? board.id : (dropTarget == board.id ? nil : dropTarget) })) { _ in
                            guard let item = model.dragging else { return false }
                            model.library.add([item], to: board.id)
                            model.dragging = nil
                            return true
                        }
                }
                chip(.snippets, symbol: "text.quote", tint: nil, count: compact ? nil : model.library.snippets.count)
                Button {
                    model.mode = .newPinboard("", Pinboard.tints[model.library.pinboards.count % Pinboard.tints.count])
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(style.hairline))
                }
                .buttonStyle(.plain)
                .help(Text("New Pinboard"))
                .accessibilityLabel(Text("New Pinboard"))
            }
            .padding(.horizontal, compact ? 0 : 16)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ source: ClipboardPanelModel.Source, symbol: String?, tint: Tint?, count: Int?) -> some View {
        let selected = model.source == source
        let targeted: Bool = if case .pinboard(let id) = source { dropTarget == id } else { false }
        return Button { model.source = source } label: {
            HStack(spacing: 6) {
                if let tint {
                    Circle().fill(tint.color).frame(width: 8, height: 8)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(verbatim: model.title(of: source)).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                if let count, count > 0 {
                    Text(verbatim: count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(style.tertiary)
                }
            }
            .foregroundStyle(selected ? style.primary : style.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(selected || targeted ? Color.white.opacity(targeted ? 0.2 : 0.13) : Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(targeted ? Color.accentColor : selected ? style.stroke : style.hairline,
                                            lineWidth: targeted ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Type, app and date filters as compact menu pills.
struct FilterPills: View {
    @Bindable var model: ClipboardPanelModel
    @Environment(\.clipStyle) private var style

    var body: some View {
        HStack(spacing: 6) {
            typeMenu
            if model.source != .snippets {
                appMenu
                dateMenu
            }
        }
    }

    private var typeMenu: some View {
        let f = model.filter
        let title = f.pinnedOnly ? String(localized: "Pinned", comment: "Clipboard type filter: pinned entries only")
            : f.type?.filterTitle ?? String(localized: "All types", comment: "Clipboard type filter: no restriction")
        return Menu {
            Button(String(localized: "All types", comment: "Clipboard type filter: no restriction")) {
                model.filter.type = nil
                model.filter.pinnedOnly = false
            }
            if model.source == .history {
                Button(String(localized: "Pinned", comment: "Clipboard type filter: pinned entries only")) {
                    model.filter.type = nil
                    model.filter.pinnedOnly = true
                }
            }
            Divider()
            ForEach(ClipContentType.allCases) { type in
                Button {
                    model.filter.type = type
                    model.filter.pinnedOnly = false
                } label: { Label(type.filterTitle, systemImage: type.symbol) }
            }
        } label: {
            pill(title, symbol: f.pinnedOnly ? "pin.fill" : f.type?.symbol ?? "line.3.horizontal.decrease", active: f.type != nil || f.pinnedOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.source == .snippets)
    }

    private var appMenu: some View {
        let apps = appChoices
        let current = apps.first { $0.key == model.filter.app }
        return Menu {
            Button(String(localized: "All apps", comment: "Clipboard app filter: no restriction")) { model.filter.app = nil }
            if !apps.isEmpty { Divider() }
            ForEach(apps, id: \.key) { app in
                Button { model.filter.app = app.key } label: {
                    if let icon = AppIcons.icon(bundleID: app.item.sourceBundleID, name: app.item.sourceApp) {
                        Label { Text(verbatim: app.name) } icon: { Image(nsImage: Self.menuIcon(icon)) }
                    } else {
                        Text(verbatim: app.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let current, let icon = AppIcons.icon(bundleID: current.item.sourceBundleID, name: current.item.sourceApp) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                pillLabel(current?.name ?? String(localized: "All apps", comment: "Clipboard app filter: no restriction"),
                          symbol: current == nil ? "app.dashed" : nil)
            }
            .modifier(PillBackground(active: current != nil))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var dateMenu: some View {
        Menu {
            ForEach(ClipFilter.DateRange.allCases) { range in
                Button(range.title) { model.filter.date = range }
            }
        } label: {
            pill(model.filter.date.title, symbol: "calendar", active: model.filter.date != .any)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pill(_ title: String, symbol: String?, active: Bool) -> some View {
        pillLabel(title, symbol: symbol).modifier(PillBackground(active: active))
    }

    private func pillLabel(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(verbatim: title).font(.system(size: 12)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
    }

    /// Distinct source apps of the current source, most frequent first.
    private var appChoices: [(key: String, name: String, item: ClipItem)] {
        let items: [ClipItem] = switch model.source {
        case .history: model.history.items
        case .pinboard(let id): model.library.pinboard(id)?.items ?? []
        case .snippets: []
        }
        var counts: [String: (Int, ClipItem)] = [:]
        for item in items {
            guard let key = item.appKey, item.sourceApp != nil else { continue }
            counts[key] = ((counts[key]?.0 ?? 0) + 1, counts[key]?.1 ?? item)
        }
        return counts.sorted { $0.value.0 > $1.value.0 }.prefix(16)
            .map { (key: $0.key, name: $0.value.1.sourceApp ?? $0.key, item: $0.value.1) }
    }

    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = CGSize(width: 16, height: 16)
        return copy
    }
}

private struct PillBackground: ViewModifier {
    let active: Bool
    @Environment(\.clipStyle) private var style

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? style.primary : style.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(active ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.7) : style.hairline))
    }
}

/// What the list shows when there is nothing to list.
struct PanelEmptyState: View {
    let model: ClipboardPanelModel
    var onResume: () -> Void = {}
    var onSettings: () -> Void = {}
    @Environment(\.clipStyle) private var style

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(style.tertiary)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 2)
            title.font(.system(size: 14, weight: .semibold)).foregroundStyle(style.primary)
            message.font(.system(size: 12)).foregroundStyle(style.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.filter.isActive }

    private var symbol: String {
        if searching { return "magnifyingglass" }
        switch model.source {
        case .history: return model.history.isPaused ? "pause.circle" : "doc.on.clipboard"
        case .pinboard: return "pin.square"
        case .snippets: return "text.quote"
        }
    }

    private var title: Text {
        if searching {
            return model.query.isEmpty ? Text("No matching items", comment: "Clipboard panel: filters exclude everything")
                : Text("No results for “\(model.query)”", comment: "Clipboard panel: %@ is the search text")
        }
        switch model.source {
        case .history:
            return model.history.isPaused ? Text("Recording is paused") : Text("Nothing copied yet")
        case .pinboard(let id):
            return Text("“\(model.library.pinboard(id)?.name ?? "")” is empty", comment: "Empty pinboard; %@ is its name")
        case .snippets:
            return Text("No snippets yet")
        }
    }

    private var message: Text {
        if searching { return Text("Try fewer words, or clear the filters.") }
        switch model.source {
        case .history:
            return model.history.isPaused ? Text("Copies aren’t recorded until you resume.")
                : Text("Copy text, links, images or files and they show up here, newest first.")
        case .pinboard:
            return Text("Drag items onto this pinboard’s chip, or press ⌘K and choose Add to Pinboard.")
        case .snippets:
            return Text("Save text you type often, with placeholders for the date, the clipboard and the cursor.")
        }
    }

    @ViewBuilder private var action: some View {
        if !searching {
            if model.source == .history, model.history.isPaused {
                panelButton(Text("Resume Recording"), action: onResume)
            } else if model.source == .snippets {
                panelButton(Text("Add Snippets in Settings…"), action: onSettings)
            }
        }
    }

    private func panelButton(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title.font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
