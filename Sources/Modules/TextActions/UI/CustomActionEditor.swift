import AppKit
import MacToysCore
import SwiftUI

/// Creates or edits a custom action, with a place to try it on sample text.
struct CustomActionEditor: View {
    @State private var action: CustomAction
    let isNew: Bool
    let onSave: (CustomAction) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var sample = String(localized: "The quick brown fox jumps over the lazy dog",
                                       comment: "Sample text for trying a custom text action")
    @State private var trial: Trial?
    @State private var running = false
    @State private var shortcutNames: [String] = []

    enum Trial: Equatable {
        case success(String)
        case failure(String)
    }

    init(action: CustomAction, isNew: Bool, trial: Trial? = nil, onSave: @escaping (CustomAction) -> Void,
         onDelete: (() -> Void)?) {
        _action = State(initialValue: action)
        _trial = State(initialValue: trial)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    static let symbols = ["bolt", "link", "magnifyingglass", "globe", "terminal", "applescript", "square.2.layers.3d", "keyboard",
                          "chevron.left.forwardslash.chevron.right", "curlybraces", "doc.text", "note.text", "envelope",
                          "paperplane", "bubble.left", "quote.bubble", "text.quote", "list.bullet", "checklist",
                          "arrow.up.arrow.down", "textformat", "character.cursor.ibeam", "number", "lock", "wand.and.stars",
                          "sparkles", "hammer", "calendar", "bookmark", "star", "tag", "folder"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                typeSection
                definitionSection
                if action.kind.producesOutput { resultSection }
                conditionSection
                iconSection
                trySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 560, height: 680)
        .task(id: action.kind) {
            if action.kind == .shortcut && shortcutNames.isEmpty { shortcutNames = await ScriptRunner.shortcutNames() }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 14) {
            ModuleIcon(symbol: action.symbol.isEmpty ? "bolt" : action.symbol, tint: .purple, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                TextField(text: $action.name, prompt: Text("Action name")) { Text("Name") }
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                (isNew ? Text("New \(action.kind.title) action", comment: "Editor subtitle; %@ is the action type, e.g. Shell Script")
                       : Text("\(action.kind.title) action", comment: "Editor subtitle; %@ is the action type, e.g. Shell Script"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var typeSection: some View {
        Section {
            Picker(selection: $action.kind) {
                ForEach(CustomAction.Kind.allCases, id: \.self) { Text(verbatim: $0.shortTitle).tag($0) }
            } label: {
                RowLabel("Type")
            }
            .pickerStyle(.segmented)
            .onChange(of: action.kind) { old, new in
                if action.symbol == old.symbol { action.symbol = new.symbol }
                trial = nil
            }
        }
    }

    @ViewBuilder
    private var definitionSection: some View {
        switch action.kind {
        case .url:
            Section {
                TextField(text: $action.template, prompt: Text(verbatim: "https://example.com/search?q={text}")) { Text("URL") }
                    .font(.system(size: 12.5, design: .monospaced))
                if !action.template.isEmpty && !URLTemplate.isValid(action.template) {
                    InfoBar(.warning, title: "Not a complete web address", message: "Start with a scheme such as https:// or an app’s own, like things:")
                }
            } header: {
                Text("URL to open")
            } footer: {
                note("{text} is replaced by the selection, encoded for use in a URL.")
            }
        case .shell:
            Section {
                ScriptEditor(text: $action.script, placeholder: "tr '[:lower:]' '[:upper:]'")
            } header: {
                Text("Shell script")
            } footer: {
                note("Runs in zsh as a login shell. The selection arrives on standard input and in $MACTOYS_TEXT; what the script prints is the result. A non-zero exit status shows the error.")
            }
        case .appleScript:
            Section {
                ScriptEditor(text: $action.script, placeholder: "tell application \"Notes\" to make new note with properties {body:{text}}")
            } header: {
                Text("AppleScript")
            } footer: {
                note("{text} becomes the selection as an AppleScript string. The script’s result is the output.")
            }
        case .shortcut:
            Section {
                HStack(spacing: 8) {
                    TextField(text: $action.shortcutName, prompt: Text("Shortcut name")) { Text("Shortcut") }
                    Menu {
                        if shortcutNames.isEmpty {
                            Text("No shortcuts found")
                        }
                        ForEach(shortcutNames, id: \.self) { name in
                            Button { action.shortcutName = name } label: { Text(verbatim: name) }
                        }
                    } label: {
                        Text("Choose", comment: "Menu: pick one of the user's Shortcuts")
                    }
                    .fixedSize()
                }
            } header: {
                Text("Shortcut to run")
            } footer: {
                note("The selection is the Shortcut’s input; the text it outputs is the result.")
            }
        case .keyPress:
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: $action.keys, allowsModifierless: true)
                } label: {
                    RowLabel("Keys to press", subtitle: "Pressed in the app after the bar closes, with the text still selected.")
                }
            }
        }
    }

    private var resultSection: some View {
        Section("Result") {
            Picker(selection: $action.output) {
                ForEach(CustomAction.Output.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel(title: Text("With the output"),
                         subtitle: action.output == .replace ? Text("Copied instead where the text can’t be edited.") : nil)
            }
        }
    }

    private var conditionSection: some View {
        Section("Appears for") {
            Picker(selection: $action.condition) {
                ForEach(CustomAction.Condition.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Selection")
            }
            if action.condition == .regex {
                TextField(text: $action.pattern, prompt: Text(verbatim: "^#[0-9a-f]{6}$")) { Text("Regular expression") }
                    .font(.system(size: 12.5, design: .monospaced))
                if !action.pattern.isEmpty, (try? NSRegularExpression(pattern: action.pattern)) == nil {
                    InfoBar(.warning, title: "This pattern isn’t a valid regular expression")
                }
            }
        }
    }

    private var iconSection: some View {
        Section("Icon") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11), spacing: 4) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    let selected = action.symbol == symbol
                    Button {
                        action.symbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .frame(width: 34, height: 30)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? Color.accentColor : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: symbol))
                }
            }
            .padding(.vertical, 2)
            TextField(text: $action.symbol, prompt: Text(verbatim: "bolt")) { Text("SF Symbol name") }
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var trySection: some View {
        Section("Try it") {
            TextField(text: $sample, prompt: Text("Sample text")) { Text("Selection") }
            HStack {
                Button {
                    runTrial()
                } label: {
                    Label("Run on Sample", systemImage: "play.fill")
                }
                .disabled(running || !action.isComplete || action.kind == .keyPress)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if action.kind == .keyPress {
                    Text("Key presses can only be tried in another app.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            if let trial {
                switch trial {
                case .success(let text):
                    ScrollView {
                        Text(verbatim: text.isEmpty ? String(localized: "(no output)") : text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                case .failure(let message):
                    InfoBar(.error, title: "The action failed", verbatimMessage: message)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let onDelete {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Action" : "Save") {
                var saved = action
                saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                saved.symbol = NSImage(systemSymbolName: saved.symbol, accessibilityDescription: nil) == nil ? saved.kind.symbol : saved.symbol
                onSave(saved)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!action.isComplete)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func runTrial() {
        let current = action, text = sample
        switch current.kind {
        case .url:
            if let url = URLTemplate.expand(current.template, text: text) {
                trial = .success(url.absoluteString)
            } else {
                trial = .failure(String(localized: "The template doesn’t make a valid URL."))
            }
        case .keyPress:
            break
        case .shell, .appleScript, .shortcut:
            running = true
            Task {
                let result = await CustomActionRunner.run(current, text: text, appName: nil, bundleID: nil)
                running = false
                switch result {
                case .success(let output): trial = .success(output)
                case .failure(let message): trial = .failure(message)
                }
            }
        }
    }
}

/// A monospaced script field with a placeholder.
private struct ScriptEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(verbatim: placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}
