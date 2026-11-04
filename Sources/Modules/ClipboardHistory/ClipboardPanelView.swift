import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Sizes of the panel and the paste bar.
enum PanelLayout {
    static let panelSize = CGSize(width: 780, height: 520)
    static let previewWidth: CGFloat = 304
    static let barHeight: CGFloat = 300
    static let barMaxWidth: CGFloat = 1720
}

/// What the views call back into (the controller in the app, nothing in previews).
@MainActor
struct PanelCallbacks {
    var resume: () -> Void = {}
    var settings: () -> Void = {}
    var open: (URL) -> Void = { _ in }
}

/// The floating clipboard panel: search, sources, the list and a preview.
struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    var callbacks = PanelCallbacks()
    @Environment(\.clipStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                SourceStrip(model: model)
                    .frame(height: 30)
                    .padding(.bottom, 10)
                Rectangle().fill(style.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    list
                    if model.settings.showPreview, !model.rows.isEmpty {
                        Rectangle().fill(style.hairline).frame(width: 1)
                        ClipPreviewPane(row: model.selectedRow, now: model.now(),
                                        merging: model.marked.count > 1 ? model.targetClips : [],
                                        separator: model.settings.mergeSeparator.string, onOpen: callbacks.open)
                            .frame(width: PanelLayout.previewWidth)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: model.selectedRow?.id)
                    }
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(style.hairline).frame(height: 1)
                PanelFooter(model: model)
            }
            if model.mode == .actions {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ActionsMenuView(model: model)
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 44)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
            if isSheet { PanelSheetView(model: model).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: model.mode)
        .clipGlass(cornerRadius: 20)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { appeared = true }
        }
    }

    private var isSheet: Bool {
        switch model.mode {
        case .browse, .actions: false
        default: true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(style.secondary)
            PanelSearchField(text: $model.query, placeholder: placeholder, focusRequest: model.focusRequest)
                .frame(maxWidth: .infinity)
            FilterPills(model: model)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var placeholder: String {
        switch model.source {
        case .history: String(localized: "Search clipboard history and snippets", comment: "Clipboard panel search placeholder")
        case .pinboard(let id): String(localized: "Search “\(model.library.pinboard(id)?.name ?? "")”", comment: "Search placeholder; %@ is a pinboard")
        case .snippets: String(localized: "Search snippets by name or abbreviation", comment: "Clipboard panel search placeholder")
        }
    }

    @ViewBuilder private var list: some View {
        if model.rows.isEmpty {
            PanelEmptyState(model: model, onResume: callbacks.resume, onSettings: callbacks.settings)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let snippets = model.source == .history ? model.rows.prefix { $0.snippet != nil }.count : 0
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            if snippets > 0, i == 0 { sectionHeader(Text("Snippets", comment: "Clipboard panel section heading")) }
                            if snippets > 0, i == snippets { sectionHeader(Text("History", comment: "Clipboard panel section heading")) }
                            ClipRowView(row: row, selected: i == model.selection, marked: model.marked.contains(row.id), now: model.now())
                                .id(row.id)
                                .modifier(RowInteractions(model: model, index: i, row: row))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selection) { _, new in
                    if model.rows.indices.contains(new) { proxy.scrollTo(model.rows[new].id) }
                }
            }
        }
    }

    private func sectionHeader(_ title: Text) -> some View {
        title.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// Clicks, double-clicks, the context menu and dragging, for rows and cards.
struct RowInteractions: ViewModifier {
    let model: ClipboardPanelModel
    let index: Int
    let row: ClipboardPanelModel.Row

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                model.select(index)
                model.activate()
            }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                model.select(index, toggle: flags.contains(.command), extend: flags.contains(.shift))
            }
            .contextMenu {
                let commands = model.commands(for: row)
                ForEach(commands) { command in
                    Button(role: command.destructive ? .destructive : nil) {
                        if !model.marked.contains(row.id) { model.select(index) }
                        model.perform(command.kind)
                    } label: {
                        Label(command.title, systemImage: command.symbol)
                    }
                }
            }
            .onDrag {
                if let clip = row.clip { model.dragging = clip }
                return DragProvider.provider(for: row)
            }
    }
}

/// Item providers for dragging entries into other apps.
enum DragProvider {
    static func provider(for row: ClipboardPanelModel.Row) -> NSItemProvider {
        switch row.content {
        case .snippet(let snippet):
            return NSItemProvider(object: SnippetExpander.expand(snippet.text).text as NSString)
        case .clip(let item):
            switch item.kind {
            case .files:
                if let url = item.files.first, let provider = NSItemProvider(contentsOf: url) { return provider }
                return NSItemProvider(object: (item.plainText ?? "") as NSString)
            case .image:
                guard let data = item.image else { return NSItemProvider(object: (item.text ?? "") as NSString) }
                let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
                provider.suggestedName = item.name ?? String(localized: "Image", comment: "File name of a dragged clipboard image")
                return provider
            default:
                let text = item.text ?? ""
                let provider: NSItemProvider
                if let url = ClipText.link(in: text) {
                    provider = NSItemProvider(object: url as NSURL)
                    provider.registerObject(text as NSString, visibility: .all)
                } else {
                    provider = NSItemProvider(object: text as NSString)
                }
                if let rtf = item.rtf {
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { done in
                        done(rtf, nil)
                        return nil
                    }
                }
                return provider
            }
        }
    }
}

/// Status on the left, key hints on the right.
struct PanelFooter: View {
    let model: ClipboardPanelModel
    var compact = false
    @Environment(\.clipStyle) private var style

    var body: some View {
        HStack(spacing: 14) {
            status
            Spacer(minLength: 8)
            if model.selectedRow != nil {
                if model.marked.count > 1 {
                    KeyHint(title: Text("Merge", comment: "Footer hint: merge the selected clipboard items"), keys: ["⌘", "M"])
                }
                KeyHint(title: primaryTitle, keys: ["↩"])
                if !compact, model.selectedRow?.clip?.kind != .text || model.marked.count > 1 {
                    KeyHint(title: Text("Plain text", comment: "Footer hint: ⇧↩ pastes as plain text"), keys: ["⇧", "↩"])
                }
                Rectangle().fill(style.hairline).frame(width: 1, height: 16)
            }
            KeyHint(title: Text("Actions", comment: "Footer hint: ⌘K opens the actions menu"), keys: ["⌘", "K"])
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var primaryTitle: Text {
        if model.selectedRow?.snippet == nil, model.marked.count > 1 {
            return model.settings.returnAction == .paste ? Text("Paste merged", comment: "Footer hint") : Text("Copy merged", comment: "Footer hint")
        }
        return model.settings.returnAction == .paste ? Text("Paste", comment: "Footer hint: ↩ pastes")
            : Text("Copy", comment: "Footer hint: ↩ copies")
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 7) {
            if model.history.isPaused {
                Circle().fill(Tint.orange.color).frame(width: 7, height: 7)
                Text("Recording paused").foregroundStyle(Tint.orange.color)
            } else if model.stackCount > 0 {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Tint.indigo.color)
                Text("Paste stack · \(model.stackCount)", comment: "Footer status: number of items waiting in the paste stack")
                    .foregroundStyle(style.secondary)
            } else if model.marked.count > 1 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                Text("\(model.marked.count) selected", comment: "Footer status: selected clipboard items").foregroundStyle(style.secondary)
            } else {
                Image(systemName: "doc.on.clipboard").foregroundStyle(style.secondary)
                Text("\(model.rows.filter { $0.clip != nil }.count) items", comment: "Footer status: entries listed")
                    .foregroundStyle(style.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// The paste bar: the same content as cards along the bottom of the screen.
struct PasteBarView: View {
    @Bindable var model: ClipboardPanelModel
    var callbacks = PanelCallbacks()
    @Environment(\.clipStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(style.secondary)
                        PanelSearchField(text: $model.query, placeholder: String(localized: "Search", comment: "Paste bar search placeholder"),
                                         fontSize: 14, focusRequest: model.focusRequest)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 250, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style.hairline))
                    SourceStrip(model: model, compact: true)
                    Spacer(minLength: 8)
                    FilterPills(model: model)
                }
                .padding(.horizontal, 18)
                .frame(height: 54)
                cards
                PanelFooter(model: model, compact: true)
                    .padding(.top, -2)
            }
            if model.mode == .actions {
                ActionsMenuView(model: model).transition(.opacity)
            }
            if !(model.mode == .browse || model.mode == .actions) { PanelSheetView(model: model).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: model.mode)
        .clipGlass(cornerRadius: 22)
        .offset(y: appeared || reduceMotion ? 0 : 24)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { appeared = true } }
    }

    @ViewBuilder private var cards: some View {
        if model.rows.isEmpty {
            PanelEmptyState(model: model, onResume: callbacks.resume, onSettings: callbacks.settings)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            ClipCardView(row: row, selected: i == model.selection, marked: model.marked.contains(row.id), now: model.now())
                                .id(row.id)
                                .modifier(RowInteractions(model: model, index: i, row: row))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, new in
                    if model.rows.indices.contains(new) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(model.rows[new].id) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
