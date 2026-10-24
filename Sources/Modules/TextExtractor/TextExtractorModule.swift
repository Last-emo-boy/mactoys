import Carbon.HIToolbox
import MacToysCore
import SwiftUI

public struct TextExtractorSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case lines, table, singleLine

        public var title: String {
            switch self {
            case .lines: "Lines"
            case .table: "Table"
            case .singleLine: "Single line"
            }
        }

        public var detail: String {
            switch self {
            case .lines: "One line of text per line on screen."
            case .table: "Rows and columns separated by tabs, ready for Numbers or Excel."
            case .singleLine: "Everything joined into one line; hyphenated line breaks are rejoined."
            }
        }
    }

    public var activation: Shortcut? = Shortcut(kVK_ANSI_T, [.control, .option])
    public var mode = Mode.lines
    /// Vision language code; nil detects the language automatically. Changing it in the overlay updates this.
    public var language: String?
    public var languageCorrection = true
    public var showConfirmation = true

    public init() {}
}

/// Text Extractor: ⌃⌥T freezes the screens, drag over text (Shift moves the selection), and
/// the recognized text is copied. Click without dragging to copy a single word.
///
/// URL actions: `open` / `capture` with optional `mode=lines|table|singleLine`, `cancel`.
@MainActor
public final class TextExtractorModule: ToyModule {
    public let info = ModuleInfo(
        id: "textextractor", name: "Text Extractor",
        summary: "Copy text from anywhere on screen with on-device OCR.",
        symbol: "text.viewfinder", tint: .mint, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["ocr", "text", "grab", "screen", "copy", "table", "vision"])

    public let settings = Persisted("textextractor", default: TextExtractorSettings())
    lazy var controller = TextExtractorController(settings: settings)
    private var running = false

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkey()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister("textextractor.activate")
        controller.cancel()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register("textextractor.activate", settings.value.activation) { [weak self] in
            self?.controller.begin()
        }
    }

    public func settingsView() -> AnyView {
        AnyView(TextExtractorSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "textextractor.capture", title: "Text Extractor", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.activation) { [weak self] in self?.controller.begin() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Extract text from screen", settings.value.activation)]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "capture", "show":
            guard isEnabled else { return false }
            controller.begin(mode: command.parameters["mode"].flatMap(TextExtractorSettings.Mode.init(rawValue:)))
            return true
        case "cancel":
            controller.cancel()
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("selection", size: CGSize(width: 1100, height: 640), wallpaper: false) {
            let model = SelectionModel(mode: .lines, language: "en-US")
            model.begin(at: CGPoint(x: 236, y: 152))
            model.update(to: CGPoint(x: 676, y: 318), moving: false)
            return AnyView(TextExtractorOverlay(model: model, background: SampleScreen(),
                                                languages: [("en-US", "English (United States)")]))
        }]
    }
}

/// A desktop with a document window, standing in for the frozen screen in previews.
private struct SampleScreen: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.42, green: 0.22, blue: 0.55),
                                    Color(red: 0.88, green: 0.54, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                Text("Release notes 0.102").font(.system(size: 26, weight: .bold))
                Text("Mouse Button Lock and CursorHide join\nthe mouse utilities family.").font(.system(size: 15))
                Text("Quick Accent gains Belarusian and Pitjantjatjara sets.").font(.system(size: 15)).padding(.top, 30)
            }
            .foregroundStyle(.white)
            .padding(.leading, 250)
            .padding(.top, 170)
        }
    }
}

struct TextExtractorSettingsView: View {
    let module: TextExtractorModule
    @Bindable var settings: Persisted<TextExtractorSettings>

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .mint) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drag over any text on screen").font(.system(size: 14, weight: .semibold))
                        Text("Hold ⇧ while dragging to move the selection, click a single word to copy just that word, press esc to cancel.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Try it") { module.controller.begin() }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", shortcut: $settings.value.activation)
            }
            Section("Recognition") {
                Picker(selection: $settings.value.mode) {
                    ForEach(TextExtractorSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Default mode", subtitle: settings.value.mode.detail)
                }
                Picker(selection: $settings.value.language) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(TextRecognizer.languages, id: \.code) { Text($0.name).tag(Optional($0.code)) }
                } label: {
                    RowLabel("Preferred language", subtitle: "Recognized on this Mac. Also changes when you pick a language in the overlay.")
                }
                Toggle(isOn: $settings.value.languageCorrection) {
                    RowLabel("Language correction", subtitle: "Fixes likely misreadings of words. Turn off for code, serial numbers and IDs.")
                }
            }
            Section("Feedback") {
                Toggle(isOn: $settings.value.showConfirmation) {
                    RowLabel("Show a confirmation after copying", subtitle: "A brief notice with what was copied, or that no text was found.")
                }
            }
        }
    }
}
