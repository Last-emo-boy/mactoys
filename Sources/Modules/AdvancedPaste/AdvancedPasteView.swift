import MacToysCore
import Observation
import SwiftUI

/// State of one opening of the Advanced Paste window.
@MainActor
@Observable
final class PasteSession {
    enum State: Equatable {
        case idle
        case running(title: String, progress: Double?)
        case preview(title: String, output: AdvancedPasteTransforms.Output)
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case action(AdvancedPasteTransforms.Action)
            case custom(CustomAction)
            case history(ClipItem)
        }

        let id: String
        let kind: Kind
        let title: String
        let symbol: String
        /// ⌘1…⌘9.
        let number: Int?
    }

    let settings: AdvancedPasteSettings
    private(set) var input: AdvancedPasteTransforms.Input
    private(set) var summary: ClipboardSummary
    private(set) var rows: [Row] = []
    let history: [ClipItem]
    var prompt = ""
    var selection: Int = 0
    var state: State = .idle

    init(input: AdvancedPasteTransforms.Input, settings: AdvancedPasteSettings, history: [ClipItem]) {
        self.settings = settings
        self.history = history
        self.input = input
        self.summary = ClipboardSummary(input)
        rebuildRows()
    }

    var showsPrompt: Bool { settings.aiEnabled && settings.showPromptBox }
    var isEmpty: Bool { input.isEmpty }

    /// Makes a history entry the content to transform.
    func use(_ item: ClipItem) {
        input = AdvancedPasteTransforms.Input(item)
        summary = ClipboardSummary(input)
        rebuildRows()
        selection = 0
    }

    /// Whether a history entry is what's being transformed (the newest entry usually is).
    func isCurrent(_ entry: ClipItem) -> Bool {
        switch entry.kind {
        case .files: entry.files == input.files
        case .image: !input.hasText && entry.image != nil && entry.image == input.image
        default: input.files.isEmpty && entry.text != nil && entry.text == input.text
        }
    }

    private func rebuildRows() {
        var list: [Row] = []
        var number = 1
        func next() -> Int? {
            defer { number += 1 }
            return number <= 9 ? number : nil
        }
        for action in settings.enabledActions where action.accepts(input) {
            list.append(Row(id: action.name, kind: .action(action), title: action.title, symbol: action.symbol, number: next()))
        }
        let ai = AdvancedPasteTransforms.Action.ai(prompt: "", provider: settings.provider)
        if ai.accepts(input) {
            for custom in settings.visibleCustomActions {
                list.append(Row(id: custom.id.uuidString, kind: .custom(custom), title: custom.name, symbol: "sparkles", number: next()))
            }
        }
        if settings.historyEnabled {
            for entry in history.prefix(12) where !isCurrent(entry) {
                let symbol = entry.kind == .image ? "photo" : entry.kind == .files ? "doc"
                    : ClipboardSummary.isLink(entry.text ?? "") ? "link" : "doc.plaintext"
                let title = entry.kind == .image
                    ? String(localized: "Image · \(entry.date.formatted(date: .abbreviated, time: .shortened))",
                             comment: "Clipboard history entry for a copied image; %@ is when it was copied")
                    : entry.title
                list.append(Row(id: "history." + entry.id.uuidString, kind: .history(entry), title: title, symbol: symbol, number: nil))
            }
        }
        rows = list
        selection = min(selection, max(0, list.count - 1))
    }

    func row(number n: Int) -> Row? { rows.first { $0.number == n } }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    var selectedRow: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// "Transcode to .mp3…": an action that is running.
    nonisolated static func inProgress(_ title: String) -> String {
        String(localized: "\(title)…", comment: "Advanced Paste: %@ is the action that is running")
    }
}

/// The window content (design 07, left).
struct AdvancedPasteView: View {
    @Bindable var session: PasteSession
    var onRun: (PasteSession.Row) -> Void = { _ in }
    var onPrompt: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPastePreview: () -> Void = {}
    var onBack: () -> Void = {}
    var onSettings: () -> Void = {}
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if session.showsPrompt {
                promptField
                Divider()
            }
            if session.settings.showPreview {
                preview
                Divider()
            }
            content
        }
        .frame(width: 440, height: 560, alignment: .top)
        .background(.regularMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { promptFocused = session.showsPrompt }
    }

    private var promptField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tint.purple.color)
            TextField("Describe a transform… “translate to French”", text: $session.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($promptFocused)
                .onSubmit(onPrompt)
            if !session.prompt.isEmpty {
                Keycaps(["↩"])
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: session.summary.symbol).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 1)
            (session.isEmpty ? Text("The clipboard is empty") : Text(verbatim: session.summary.snippet))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(session.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !session.isEmpty {
                Text(verbatim: session.summary.detail).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle: list
        case .running(let title, let progress): running(title, progress)
        case .preview(let title, let output): result(title, output)
        case .failed(let message): failure(message)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if session.rows.isEmpty {
                        (session.isEmpty ? Text("Copy something, then open Advanced Paste again.")
                                         : Text("No paste actions apply to this content."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    section(Text("Paste as", comment: "Advanced Paste window: heading above the list of formats"), rows: session.rows.enumerated().filter { if case .action = $0.element.kind { true } else { false } })
                    section(Text("Custom actions"), rows: session.rows.enumerated().filter { if case .custom = $0.element.kind { true } else { false } })
                    section(Text("History", comment: "Advanced Paste window: heading above recent clipboard entries"), rows: session.rows.enumerated().filter { if case .history = $0.element.kind { true } else { false } })
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: session.selection) { _, new in
                if session.rows.indices.contains(new) { proxy.scrollTo(session.rows[new].id) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: Text, rows: [EnumeratedSequence<[PasteSession.Row]>.Element]) -> some View {
        if !rows.isEmpty {
            title
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 3)
            ForEach(rows, id: \.element.id) { index, row in
                rowView(row, selected: index == session.selection)
                    .id(row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { session.selection = index; onRun(row) }
                    .onHover { if $0 { session.selection = index } }
            }
        }
    }

    private func rowView(_ row: PasteSession.Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : (row.symbol == "sparkles" ? Tint.purple.color : Color.primary.opacity(0.75)))
                .frame(width: 20)
            Text(verbatim: row.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let n = row.number {
                Text(verbatim: "⌘ \(n)").font(.system(size: 11.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 6)
    }

    private func running(_ title: String, _ progress: Double?) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if let progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.large)
                Text(verbatim: "\(title) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.system(size: 13, weight: .medium))
            } else {
                ProgressView().controlSize(.large)
                Text(verbatim: PasteSession.inProgress(title)).font(.system(size: 13, weight: .medium))
            }
            Button(role: .cancel, action: onCancel) { Label("Cancel", systemImage: "xmark") }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func result(_ title: String, _ output: AdvancedPasteTransforms.Output) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: outputText(output))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Back", action: onBack)
                Spacer()
                Button("Paste", action: onPastePreview).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
            Text(verbatim: message).font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack {
                Button("Back", action: onBack)
                Button("Settings…", action: onSettings)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private func outputText(_ output: AdvancedPasteTransforms.Output) -> String {
        switch output {
        case .text(let s): s
        case .file(let url): url.lastPathComponent
        }
    }
}
