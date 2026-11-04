import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

public struct TextExtractorSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case lines, paragraphs, table, singleLine

        public var title: String {
            switch self {
            case .lines: String(localized: "Lines", comment: "Text Extractor mode: keep the line breaks")
            case .paragraphs: String(localized: "Paragraphs", comment: "Text Extractor mode: join wrapped lines, keep paragraph breaks")
            case .table: String(localized: "Table", comment: "Text Extractor mode: rows and columns separated by tabs")
            case .singleLine: String(localized: "Single line", comment: "Text Extractor mode: join everything into one line")
            }
        }

        public var detail: String {
            switch self {
            case .lines: String(localized: "One line of text per line on screen.")
            case .paragraphs: String(localized: "Wrapped lines are joined and hyphenated words rejoined; paragraphs, lists and short lines stay apart.")
            case .table: String(localized: "Rows and columns separated by tabs, ready for Numbers or Excel.")
            case .singleLine: String(localized: "Everything joined into one line; hyphenated line breaks are rejoined.")
            }
        }

        /// Key that picks the mode in the overlay.
        var key: String {
            switch self {
            case .lines: "L"
            case .paragraphs: "P"
            case .table: "T"
            case .singleLine: "S"
            }
        }
    }

    /// What appears after a capture (when `showConfirmation` is on).
    public enum Feedback: String, Codable, CaseIterable, Sendable {
        case card, notice
    }

    public var activation: Shortcut? = Shortcut(kVK_ANSI_T, [.control, .option])
    public var mode = Mode.lines
    /// Vision language code; nil detects the language automatically. Changing it in the overlay updates this.
    public var language: String?
    public var languageCorrection = true
    public var showConfirmation = true
    public var feedback = Feedback.card
    /// Seconds the card stays when the pointer isn't on it.
    public var cardSeconds = 8.0
    // QR codes and barcodes
    public var detectBarcodes = true
    /// Open web links found in a QR code right away.
    public var openLinks = false
    // Additive clipboard
    public var additive = false
    public var separator = CaptureSeparator.newline
    // Read aloud
    public var speakAfterCapture = false
    /// A voice identifier; nil uses the best voice for the text's language.
    public var voice: String?
    /// Multiplier of the normal speaking rate (0.5…2).
    public var speechRate = 1.0
    // Translate
    /// BCP 47 language to translate into; nil is the Mac's language.
    public var translateTarget: String?
    // Recent captures
    public var keepRecent = true
    public var saveRecent = false
    // More shortcuts (unassigned by default)
    public var captureParagraphs: Shortcut?
    public var captureAdding: Shortcut?
    public var captureSpeaking: Shortcut?
    public var captureTranslating: Shortcut?
    public var capturePrevious: Shortcut?
    public var captureClipboard: Shortcut?
    public var showRecent: Shortcut?
    public var stopSpeaking: Shortcut?

    public init() {}
}

/// What a capture should do besides copying: set by the shortcut or URL that started it.
struct CaptureIntent: Equatable, Sendable {
    var mode: TextExtractorSettings.Mode?
    /// nil follows the setting; ⌥ at release inverts it.
    var add: Bool?
    var speak = false
    var translate = false

    static let standard = CaptureIntent()
}

/// Text Extractor: ⌃⌥T freezes the screens, drag over text (Shift moves the selection), and
/// the recognized text — or a QR code's payload — is copied. A card next to the selection shows
/// it, joins lines, translates, reads aloud, opens links and keeps the recent captures. Images
/// and PDFs (Finder, drag and drop, the clipboard) are read the same way.
///
/// URL actions: `open` / `capture` / `show` with optional `mode=lines|paragraphs|table|singleLine`,
/// `add=1`, `speak=1`, `translate=1` and `file=…` (recognizes the files instead of the screen);
/// `recognize?file=…`, `clipboard`, `previous`, `recent`, `choose` (open panel), `clear-added`,
/// `stop-speaking`, `cancel`.
@MainActor
public final class TextExtractorModule: ToyModule {
    public let info = ModuleInfo(
        id: "textextractor", name: "Text Extractor",
        summary: "Copy text, QR codes and barcodes from anywhere on screen or in images and PDFs, on device.",
        symbol: "text.viewfinder", tint: .mint, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["ocr", "text", "grab", "screen", "copy", "table", "vision", "qr", "barcode", "translate", "speak", "pdf"])

    public let settings = Persisted("textextractor", default: TextExtractorSettings())
    let history = CaptureHistory(file: Paths.data(for: "textextractor").appendingPathComponent("recent.json"))
    lazy var presenter = ResultPresenter(settings: settings, history: history)
    lazy var controller = TextExtractorController(settings: settings, presenter: presenter)
    private var running = false

    public init() {
        settings.onChange { [weak self] _ in
            guard let self else { return }
            self.applyHistorySettings()
            if self.running { self.registerHotkeys() }
        }
        applyHistorySettings()
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "textextractor.")
        controller.cancel()
        presenter.close()
        Speaker.shared.stop()
    }

    private func applyHistorySettings() {
        let s = settings.value
        history.setPersistence(s.keepRecent && s.saveRecent)
        if !s.keepRecent, !history.items.isEmpty { history.clear() }
    }

    private func registerHotkeys() {
        let s = settings.value
        let center = HotkeyCenter.shared
        center.register("textextractor.activate", s.activation) { [weak self] in self?.controller.begin() }
        center.register("textextractor.paragraphs", s.captureParagraphs) { [weak self] in
            self?.controller.begin(CaptureIntent(mode: .paragraphs))
        }
        center.register("textextractor.add", s.captureAdding) { [weak self] in self?.controller.begin(CaptureIntent(add: true)) }
        center.register("textextractor.speak", s.captureSpeaking) { [weak self] in self?.controller.begin(CaptureIntent(speak: true)) }
        center.register("textextractor.translate", s.captureTranslating) { [weak self] in
            self?.controller.begin(CaptureIntent(translate: true))
        }
        center.register("textextractor.previous", s.capturePrevious) { [weak self] in self?.controller.capturePreviousArea() }
        center.register("textextractor.clipboard", s.captureClipboard) { [weak self] in self?.presenter.recognizeClipboard() }
        center.register("textextractor.recent", s.showRecent) { [weak self] in self?.presenter.showRecent() }
        center.register("textextractor.stop-speaking", s.stopSpeaking) { Speaker.shared.stop() }
    }

    public func settingsView() -> AnyView {
        AnyView(TextExtractorSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "textextractor.capture", title: "Text Extractor", symbol: info.symbol, tint: info.tint,
                        shortcut: settings.value.activation) { [weak self] in self?.controller.begin() },
            QuickAction(id: "textextractor.file", title: "Extract Text from File…", symbol: "doc.text.viewfinder", tint: info.tint) { [weak self] in
                self?.presenter.chooseFiles()
            },
            QuickAction(id: "textextractor.clipboard", title: "Extract Text from Clipboard Image", symbol: "doc.on.clipboard",
                        tint: info.tint, shortcut: settings.value.captureClipboard) { [weak self] in
                self?.presenter.recognizeClipboard()
            },
            QuickAction(id: "textextractor.recent", title: "Recent Captures", symbol: "clock.arrow.circlepath", tint: info.tint,
                        shortcut: settings.value.showRecent) { [weak self] in self?.presenter.showRecent() },
            QuickAction(id: "textextractor.additive", title: "Add Captures to Clipboard", symbol: "text.badge.plus", tint: info.tint,
                        isOn: { [weak self] in self?.settings.value.additive ?? false },
                        detail: { [weak self] in
                            guard let self else { return "" }
                            let count = self.presenter.addedCount
                            return count > 0 ? String(localized: "\(count) captures collected", comment: "Additive clipboard state")
                                : String(localized: "Each capture is appended", comment: "Additive clipboard state")
                        }) { [weak self] in self?.settings.value.additive.toggle() },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Extract text from screen", s.activation),
                    ShortcutBinding("Add to the clipboard instead of replacing", keys: ["⌥", String(localized: "Release", comment: "Key hint: release the mouse button")])]
        let more: [(String.LocalizationValue, Shortcut?)] = [
            ("Extract text as paragraphs", s.captureParagraphs),
            ("Extract and add to the clipboard", s.captureAdding),
            ("Extract and read aloud", s.captureSpeaking),
            ("Extract and translate", s.captureTranslating),
            ("Extract text from the previous area", s.capturePrevious),
            ("Extract text from the clipboard image", s.captureClipboard),
            ("Show recent captures", s.showRecent),
            ("Stop speaking", s.stopSpeaking),
        ]
        for (title, shortcut) in more where shortcut != nil { list.append(ShortcutBinding(title, shortcut)) }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        let p = command.parameters
        func flag(_ key: String) -> Bool { ["1", "true", "yes"].contains(p[key]?.lowercased() ?? "") }
        let intent = CaptureIntent(mode: p["mode"].flatMap(TextExtractorSettings.Mode.init(rawValue:)),
                                   add: p["add"].map { _ in flag("add") }, speak: flag("speak"), translate: flag("translate"))
        switch command.action {
        case "open", "capture", "show":
            guard isEnabled else { return false }
            if command.files.isEmpty {
                controller.begin(intent)
            } else {
                presenter.recognize(files: command.files, intent: intent)
            }
            return true
        case "recognize":
            guard isEnabled, !command.files.isEmpty else { return false }
            presenter.recognize(files: command.files, intent: intent)
            return true
        case "clipboard":
            guard isEnabled else { return false }
            presenter.recognizeClipboard(intent: intent)
            return true
        case "previous":
            guard isEnabled else { return false }
            controller.capturePreviousArea(intent)
            return true
        case "recent":
            guard isEnabled else { return false }
            presenter.showRecent()
            return true
        case "choose":
            guard isEnabled else { return false }
            presenter.chooseFiles()
            return true
        case "clear-added":
            presenter.startOver()
            return true
        case "stop-speaking":
            Speaker.shared.stop()
            return true
        case "cancel":
            controller.cancel()
            presenter.close()
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { TextExtractorPreviews.scenes(for: self) }
}
