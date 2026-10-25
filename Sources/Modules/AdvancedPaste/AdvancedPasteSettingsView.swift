import MacToysCore
import SwiftUI

struct AdvancedPasteSettingsView: View {
    let module: AdvancedPasteModule
    @Bindable var settings: Persisted<AdvancedPasteSettings>
    @State private var apiKey = ""
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var history = ClipboardHistory.shared

    private typealias Action = AdvancedPasteTransforms.Action

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .purple) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced Paste window").font(.system(size: 14, weight: .semibold))
                        Text("Pick a format, run an AI action or paste from history. ⌘1…⌘9 run an action directly.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { module.controller.showWindow() } label: {
                        Text("Open", comment: "Button: open the Advanced Paste window")
                    }
                        .buttonStyle(.borderedProminent)
                    Keycaps(settings.value.openShortcut)
                }
            }
        } content: {
            Section("Activation & behavior") {
                ShortcutRow("Open Advanced Paste window", shortcut: $settings.value.openShortcut)
                Picker(selection: $settings.value.windowPosition) {
                    ForEach(AdvancedPasteSettings.WindowPosition.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { RowLabel("Window position", subtitle: "Falls back to the pointer when an app doesn't report its text cursor.") }
                Toggle(isOn: $settings.value.showPreview) { RowLabel("Show a preview of the current clipboard content") }
                Toggle(isOn: $settings.value.historyEnabled) {
                    RowLabel("Clipboard history", subtitle: "Lists recent copies in the window; pick one to transform or paste it.")
                }
                Toggle(isOn: $settings.value.closeOnFocusLoss) { RowLabel("Close the window when it loses focus") }
                Toggle(isOn: $settings.value.customFormatPreview) {
                    RowLabel("Preview AI and OCR results", subtitle: "Review the output before it's pasted.")
                }
                Toggle(isOn: $settings.value.useSelectedText) {
                    RowLabel("Use selected text", subtitle: "Copy the current selection before running a shortcut; falls back to the clipboard.")
                }
                Toggle(isOn: $settings.value.restoreClipboard) {
                    RowLabel("Keep the original clipboard", subtitle: "Put what you copied back on the clipboard after pasting a converted version.")
                }
            }

            Section("Actions") {
                actionRow(.plainText, subtitle: Text("Removes all formatting."))
                actionRow(.markdown, subtitle: Text("Converts HTML and rich text: headings, lists, links, emphasis, code, tables, images."))
                actionRow(.json, subtitle: Text("Converts CSV/TSV, XML, YAML and key=value text; pretty-prints JSON."))
                actionRow(.imageToText, subtitle: Text("On-device text recognition."))
                actionRow(.txtFile, subtitle: Text("Pastes a file into Finder or any file field."))
                actionRow(.htmlFile)
                actionRow(.pngFile)
                actionRow(.transcodeM4A, subtitle: Text("Audio or video on the clipboard, converted with AVFoundation."))
                actionRow(.transcodeMP4, subtitle: Text("H.264 video with AAC audio, keeping dimensions and metadata."))
                actionRow(.transcodeMP3, subtitle: mp3Subtitle)
            }

            aiSection
            if settings.value.aiEnabled { customActionsSection }

            Section("Clipboard history") {
                LabeledContent {
                    Button("Clear history") { history.clear() }.disabled(history.items.allSatisfy(\.pinned))
                } label: {
                    RowLabel(title: Text("\(history.items.count) items", comment: "Clipboard history: number of saved entries"),
                             subtitle: Text("Password managers and concealed copies are never recorded."))
                }
            }
        }
        .onAppear { apiKey = Keychain.get(settings.value.provider.keychainAccount) ?? "" }
        .onChange(of: settings.value.provider.kind) { _, _ in
            apiKey = Keychain.get(settings.value.provider.keychainAccount) ?? ""
            testResult = nil
        }
    }

    private var mp3Subtitle: Text {
        if MediaTranscoder.tool("ffmpeg") != nil || MediaTranscoder.tool("lame") != nil {
            let encoder = MediaTranscoder.tool("ffmpeg") != nil ? "ffmpeg" : "LAME"
            return Text("Encoded with \(encoder).", comment: "%@ is the MP3 encoder program in use: ffmpeg or LAME")
        }
        return Text("Needs ffmpeg or LAME (brew install lame); macOS has no MP3 encoder.")
    }

    private func actionRow(_ action: Action, subtitle: Text? = nil) -> some View {
        let binding = Binding<ActionPrefs>(
            get: { settings.value.prefs(action) },
            set: { settings.value.actions[action.name] = $0 })
        return LabeledContent {
            HStack(spacing: 10) {
                ShortcutRecorder(shortcut: binding.shortcut)
                Toggle("", isOn: binding.enabled).labelsHidden().toggleStyle(.switch)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol).foregroundStyle(.secondary).frame(width: 18)
                RowLabel(title: action == .plainText ? Text("Paste as plain text") : Text(verbatim: action.title), subtitle: subtitle)
            }
        }
    }

    private var aiSection: some View {
        Section("Paste with AI") {
            Toggle(isOn: $settings.value.aiEnabled) {
                RowLabel("Paste with AI", subtitle: "Transform clipboard text with your own instructions and saved actions.")
            }
            InfoBar(.info, title: "Privacy",
                    message: "Nothing leaves this Mac until you run an AI action. Then the clipboard text (or the text recognized in an image) and your instructions are sent to the provider below. Choose Ollama to keep everything local.")
            if settings.value.aiEnabled {
                Picker("Provider", selection: Binding(
                    get: { settings.value.provider.kind },
                    set: { kind in
                        var p = AIProvider.preset(kind)
                        p.systemPrompt = settings.value.provider.systemPrompt
                        settings.value.provider = p
                    })) {
                    ForEach(AIProvider.Kind.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                LabeledContent {
                    TextField("", text: $settings.value.provider.endpoint, prompt: Text(verbatim: "https://…"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 300)
                } label: {
                    RowLabel(title: settings.value.provider.kind == .azureOpenAI
                                 ? Text("Endpoint", comment: "Azure OpenAI: the resource URL")
                                 : Text("Base URL", comment: "AI provider: URL the API paths are appended to"),
                             subtitle: Text("Requests go to …/chat/completions."))
                }
                LabeledContent {
                    TextField("", text: $settings.value.provider.model, prompt: Text("model", comment: "Placeholder: AI model name"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 300)
                } label: {
                    RowLabel(title: settings.value.provider.kind == .azureOpenAI
                                 ? Text("Deployment name", comment: "Azure OpenAI: name of the model deployment")
                                 : Text("Model", comment: "AI model name, e.g. gpt-4o-mini"))
                }
                if settings.value.provider.kind == .azureOpenAI {
                    LabeledContent {
                        TextField("", text: $settings.value.provider.apiVersion, prompt: Text(verbatim: "2024-10-21"))
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 300)
                    } label: { RowLabel("API version") }
                }
                LabeledContent {
                    SecureField("", text: $apiKey, prompt: settings.value.provider.requiresKey
                                ? Text("Required", comment: "Placeholder: an API key must be entered")
                                : Text("Optional", comment: "Placeholder: an API key may be left empty"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 300)
                        .onChange(of: apiKey) { _, new in Keychain.set(new, for: settings.value.provider.keychainAccount) }
                } label: {
                    RowLabel("API key", subtitle: "Stored in your login keychain.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    RowLabel("System prompt", subtitle: "Optional. Replaces the built-in instructions for every AI action.")
                    TextEditor(text: $settings.value.provider.systemPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 54)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                Toggle(isOn: $settings.value.showPromptBox) {
                    RowLabel("Show the AI prompt box", subtitle: "Turn off to use AI only through saved actions.")
                }
                LabeledContent {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        Button("Test connection", action: test).disabled(testing)
                    }
                } label: {
                    if let testResult {
                        Label { Text(verbatim: testResult.message) } icon: {
                            Image(systemName: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        }
                            .foregroundStyle(testResult.ok ? .green : .red)
                            .font(.system(size: 12))
                            .lineLimit(3)
                    } else {
                        RowLabel("Connection", subtitle: "Sends a one-word request.")
                    }
                }
            }
        }
    }

    private var customActionsSection: some View {
        Section("Custom actions") {
            ForEach($settings.value.customActions) { $action in
                CustomActionEditor(action: $action) {
                    settings.value.customActions.removeAll { $0.id == action.id }
                }
            }
            Button {
                settings.value.customActions.append(CustomAction(
                    name: String(localized: "New action", comment: "Name of a newly added custom AI action"), prompt: ""))
            } label: {
                Label("Add custom action", systemImage: "plus")
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let provider = settings.value.provider
        let key = apiKey
        Task {
            do {
                let reply = try await AIClient.complete(provider: provider, apiKey: key, instructions: "Reply with the single word OK.",
                                                        content: "ping")
                testResult = (true, String(localized: "Connected · \(String(reply.prefix(40)))",
                                           comment: "AI connection test passed; %@ is the start of the provider's reply"))
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

private struct CustomActionEditor: View {
    @Binding var action: CustomAction
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $action.name).textFieldStyle(.roundedBorder)
                TextField("Prompt, e.g. “Rewrite as a friendly email”", text: $action.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                HStack {
                    Text("Shortcut", comment: "Label next to the shortcut recorder of a custom AI action").foregroundStyle(.secondary)
                    ShortcutRecorder(shortcut: $action.shortcut)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Tint.purple.color)
                RowLabel(title: action.name.isEmpty ? Text("Untitled", comment: "Custom AI action without a name") : Text(verbatim: action.name),
                         subtitle: action.prompt.isEmpty ? Text("No prompt yet") : Text(verbatim: action.prompt))
                Spacer()
                if action.shortcut != nil { Keycaps(action.shortcut) }
                Toggle("", isOn: $action.isEnabled).labelsHidden().toggleStyle(.switch).help("Show in the window")
            }
        }
    }
}
