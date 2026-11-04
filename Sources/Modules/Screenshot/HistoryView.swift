import AppKit
import MacToysCore
import SwiftUI

/// What the history window's tiles do.
struct HistoryActions {
    var open: (UUID) -> Void = { _ in }
    var copy: (UUID) -> Void = { _ in }
    var pin: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var clear: () -> Void = {}
    var capture: () -> Void = {}
}

/// Recent captures by day: thumbnails to re-open, copy, pin or delete.
struct HistoryView: View {
    let history: CaptureHistory
    let actions: HistoryActions
    /// The shortcut shown in the empty state.
    var areaShortcut: Shortcut?
    /// Draw a fake title bar (offscreen previews) instead of using the window toolbar.
    var chrome = false
    @State private var filter: CaptureKind?
    @State private var confirmClear = false

    var body: some View {
        if chrome {
            HostedToolWindowChrome(title: String(localized: "Capture History", comment: "Window title"),
                                   symbol: "clock.arrow.circlepath", tint: .pink) {
                toolbarItems
            } content: {
                main
            }
        } else {
            main
                .toolbar {
                    ToolbarItem(placement: .navigation) { ModuleIcon(symbol: "clock.arrow.circlepath", tint: .pink, size: 20) }
                    ToolbarItemGroup(placement: .primaryAction) { toolbarItems }
                }
                .confirmationDialog(Text("Delete every capture in the history?", comment: "Capture history: confirm clearing"),
                                    isPresented: $confirmClear) {
                    Button(role: .destructive) { actions.clear() } label: { Text("Delete All", comment: "Capture history: confirm clearing") }
                } message: {
                    Text("Files you saved stay where they are.", comment: "Capture history: what clearing keeps")
                }
        }
    }

    @ViewBuilder private var toolbarItems: some View {
        Picker(selection: $filter) {
            Text("All", comment: "Capture history filter: every kind").tag(CaptureKind?.none)
            ForEach([CaptureKind.area, .window, .screen]) { kind in
                Text(kind.title).tag(CaptureKind?.some(kind))
            }
        } label: {
            Text("Show", comment: "Capture history filter")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Button { confirmClear = true } label: {
            Label { Text("Clear History…", comment: "Capture history toolbar") } icon: { Image(systemName: "trash") }
        }
        .disabled(history.entries.isEmpty)
    }

    private var shown: [HistoryEntry] {
        guard let filter else { return history.entries }
        return history.entries.filter { $0.kind == filter }
    }

    /// Entries grouped by calendar day, newest first.
    private var days: [(day: Date, entries: [HistoryEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: shown) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]?.sorted { $0.date > $1.date } ?? []) }
    }

    private var main: some View {
        VStack(spacing: 0) {
            if shown.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(days, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Self.dayTitle(group.day)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 16) {
                                    ForEach(group.entries) { entry in
                                        HistoryTile(entry: entry, thumbnail: history.thumbnail(for: entry.id), actions: actions)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var empty: some View {
        ContentUnavailableView {
            Label { Text("No captures yet", comment: "Capture history: empty") } icon: { Image(systemName: "camera.viewfinder") }
        } description: {
            if filter != nil {
                Text("Nothing of this kind in the history.", comment: "Capture history: empty for the chosen filter")
            } else if let areaShortcut {
                Text("Screenshots you take appear here. Press \(areaShortcut.description) to capture an area.",
                     comment: "Capture history: empty; %@ is a shortcut such as ⌃⌥A")
            } else {
                Text("Screenshots you take appear here.", comment: "Capture history: empty")
            }
        } actions: {
            Button { actions.capture() } label: { Text("Capture Area", comment: "Capture history: take a screenshot") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(history.entries.count) captures", comment: "Capture history footer: how many captures are kept")
            Text(verbatim: "·")
            Text(verbatim: ByteCountFormatter.string(fromByteCount: history.totalBytes, countStyle: .file))
            Spacer()
            Text("Double-click a capture to annotate it", comment: "Capture history footer hint")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func dayTitle(_ day: Date) -> Text {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return Text("Today", comment: "Capture history section") }
        if cal.isDateInYesterday(day) { return Text("Yesterday", comment: "Capture history section") }
        return Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One capture in the history grid.
struct HistoryTile: View {
    let entry: HistoryEntry
    let thumbnail: NSImage?
    let actions: HistoryActions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                } else {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if hovering {
                    HStack(spacing: 2) {
                        icon("pencil.tip.crop.circle", Text("Annotate", comment: "Capture history tile button")) { actions.open(entry.id) }
                        icon("doc.on.doc", Text("Copy", comment: "Capture history tile button")) { actions.copy(entry.id) }
                        icon("pin", Text("Pin to screen", comment: "Capture history tile button")) { actions.pin(entry.id) }
                        icon("trash", Text("Delete", comment: "Capture history tile button")) { actions.delete(entry.id) }
                    }
                    .padding(3)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .frame(height: 140)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1))
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbol).foregroundStyle(Tint.pink.color)
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(verbatim: "\(entry.pixelWidth) × \(entry.pixelHeight)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture(count: 2) { actions.open(entry.id) }
        .contextMenu {
            Button { actions.open(entry.id) } label: { Text("Open in Annotate", comment: "Capture history menu") }
            Button { actions.copy(entry.id) } label: { Text("Copy", comment: "Capture history menu") }
            Button { actions.pin(entry.id) } label: { Text("Pin to Screen", comment: "Capture history menu") }
            if entry.savedPath != nil {
                Button { actions.reveal(entry.id) } label: { Text("Show in Finder", comment: "Capture history menu") }
            }
            Divider()
            Button(role: .destructive) { actions.delete(entry.id) } label: { Text("Delete", comment: "Capture history menu") }
        }
    }

    private func icon(_ symbol: String, _ help: Text, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
