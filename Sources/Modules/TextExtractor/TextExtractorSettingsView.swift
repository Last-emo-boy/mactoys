import AppKit
import MacToysCore
import SwiftUI
import Translation

struct TextExtractorSettingsView: View {
    let module: TextExtractorModule
    @Bindable var settings: Persisted<TextExtractorSettings>
    @State private var targets: [String] = Translator.commonTargets
    @State private var voices: [(language: String, voices: [(id: String, name: String)])] = []

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .mint) {
                HStack(spacing: 18) {
                    TextExtractorHero(settings: settings.value)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Drag over any text, QR code or barcode").font(.system(size: 14, weight: .semibold))
                        Text("Hold ⇧ to move the selection, ⌥ to add to the clipboard, click a word to copy just that word. Images and PDFs work too: drop them on the card or use Finder’s Services menu.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Try It") { module.controller.begin() }.buttonStyle(.borderedProminent)
                            Button("Open File…") { module.presenter.chooseFiles() }
                            Keycaps(settings.value.activation)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", shortcut: $settings.value.activation)
            }
            recognition
            clipboard
            feedback
            readAloud
            translation
            recent
            filesSection
            shortcuts
        }
        .task {
            let supported = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
            if !supported.isEmpty {
                targets = Array(Set(supported)).sorted {
                    Translator.name(Locale.Language(identifier: $0)).localizedStandardCompare(Translator.name(Locale.Language(identifier: $1))) == .orderedAscending
                }
            }
            voices = Dictionary(grouping: Speaker.voices, by: { $0.name.components(separatedBy: " — ").last ?? "" })
                .map { (language: $0.key, voices: $0.value) }
                .sorted { $0.language.localizedStandardCompare($1.language) == .orderedAscending }
        }
    }

    private var recognition: some View {
        Section("Recognition") {
            Picker(selection: $settings.value.mode) {
                ForEach(TextExtractorSettings.Mode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel(title: Text("Default mode"), subtitle: Text(verbatim: settings.value.mode.detail))
            }
            Picker(selection: $settings.value.language) {
                Text("Automatic", comment: "Recognition language: detect it automatically").tag(String?.none)
                Divider()
                ForEach(TextRecognizer.languages, id: \.code) { Text(verbatim: $0.name).tag(Optional($0.code)) }
            } label: {
                RowLabel("Preferred language", subtitle: "Recognized on this Mac. Also changes when you pick a language in the overlay.")
            }
            Toggle(isOn: $settings.value.languageCorrection) {
                RowLabel("Language correction", subtitle: "Fixes likely misreadings of words. Turn off for code, serial numbers and IDs.")
            }
            Toggle(isOn: $settings.value.detectBarcodes) {
                RowLabel("Read QR codes and barcodes", subtitle: "A code in the selection is copied instead of a short caption next to it.")
            }
            Toggle(isOn: $settings.value.openLinks) {
                RowLabel("Open links from QR codes right away", subtitle: "Only web links; anything else is copied and shown on the card.")
            }
            .disabled(!settings.value.detectBarcodes)
        }
    }

    private var clipboard: some View {
        Section("Clipboard") {
            Toggle(isOn: $settings.value.additive) {
                RowLabel("Add captures to the clipboard",
                         subtitle: "Each capture is appended to the ones before, until you copy something else. Hold ⌥ while releasing the selection to switch for one capture.")
            }
            Picker(selection: $settings.value.separator) {
                ForEach(CaptureSeparator.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Separate added captures with")
            }
        }
    }

    private var feedbackChoice: Binding<Int> {
        Binding(get: {
            let s = settings.value
            return !s.showConfirmation ? 2 : s.feedback == .card ? 0 : 1
        }, set: { v in
            settings.update { s in
                s.showConfirmation = v != 2
                if v != 2 { s.feedback = v == 0 ? .card : .notice }
            }
        })
    }

    private var feedback: some View {
        Section("After Copying") {
            Picker(selection: feedbackChoice) {
                Text("The result card").tag(0)
                Text("A brief notice").tag(1)
                Text("Nothing", comment: "After copying, show nothing").tag(2)
            } label: {
                RowLabel("Show", subtitle: "The card has the text, its language, translation, read aloud, links and your recent captures.")
            }
            SliderRow(label: RowLabel("Keep the card for", subtitle: "Longer while the pointer is on it or you use it."),
                      value: $settings.value.cardSeconds, in: 3...30, step: 1,
                      format: { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .abbreviated)) })
                .disabled(!settings.value.showConfirmation || settings.value.feedback != .card)
            Toggle(isOn: $settings.value.speakAfterCapture) {
                RowLabel("Read the text aloud", subtitle: "Press R in the overlay to switch it for one capture.")
            }
        }
    }

    private var readAloud: some View {
        Section("Read Aloud") {
            Picker(selection: $settings.value.voice) {
                Text("Automatic: a voice for the text’s language").tag(String?.none)
                ForEach(voices, id: \.language) { group in
                    Section(group.language) {
                        ForEach(group.voices, id: \.id) { v in
                            Text(verbatim: v.name.components(separatedBy: " — ").first ?? v.name).tag(Optional(v.id))
                        }
                    }
                }
            } label: {
                RowLabel("Voice", subtitle: "More voices: System Settings › Accessibility › Spoken Content.")
            }
            SliderRow("Speaking rate", value: $settings.value.speechRate, in: 0.5...2, step: 0.1,
                      format: { "\($0.formatted(.number.precision(.fractionLength(1))))×" })
            LabeledContent {
                let speaking = Speaker.shared.speakingID == "preview"
                Button {
                    if speaking { Speaker.shared.stop(); return }
                    let sample = String(localized: "Text Extractor reads what you capture in this voice.")
                    Speaker.shared.speak(sample, id: "preview", language: Locale.current.language.minimalIdentifier,
                                         voice: settings.value.voice, rate: settings.value.speechRate)
                } label: {
                    speaking ? Text("Stop", comment: "Card tile: stop reading aloud") : Text("Listen", comment: "Button: hear a sample of the voice")
                }
            } label: {
                RowLabel("Try the voice")
            }
        }
    }

    private var translation: some View {
        Section("Translation") {
            Picker(selection: $settings.value.translateTarget) {
                Text("This Mac’s language (\(Translator.name(Translator.target(nil))))",
                     comment: "Translation target menu item; %@ is a language").tag(String?.none)
                Divider()
                ForEach(targets, id: \.self) { Text(verbatim: Translator.name(Locale.Language(identifier: $0))).tag(Optional($0)) }
            } label: {
                RowLabel("Translate into", subtitle: "Translation runs on this Mac. Each language is downloaded once, the first time you use it.")
            }
            LabeledContent {
                Button("Language Settings…") { Translator.openLanguageSettings() }
            } label: {
                RowLabel("Downloaded languages", subtitle: "Manage them in System Settings › General › Language & Region.")
            }
        }
    }

    private var recent: some View {
        Section("Recent Captures") {
            Toggle(isOn: $settings.value.keepRecent) {
                RowLabel("Keep recent captures", subtitle: "The last 20, listed on the card. A click copies one again.")
            }
            Toggle(isOn: $settings.value.saveRecent) {
                RowLabel("Keep them after quitting", subtitle: "Saved on this Mac only. Off: forgotten when MacToys quits.")
            }
            .disabled(!settings.value.keepRecent)
            LabeledContent {
                HStack {
                    Button("Show") { module.presenter.showRecent() }
                    Button("Clear") { module.history.clear() }.disabled(module.history.items.isEmpty)
                }
            } label: {
                RowLabel(title: Text("Recent captures"), subtitle: Text("\(module.history.items.count) captures", comment: "How many recent captures are kept"))
            }
        }
    }

    private var filesSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Open File…") { module.presenter.chooseFiles() }
                    Button("Clipboard Image") { module.presenter.recognizeClipboard() }
                }
            } label: {
                RowLabel("Images and PDFs", subtitle: "PDF pages with text are read exactly; scanned pages and images are recognized. Drop files on the card, or use Services › Extract Text in Finder.")
            }
        } header: {
            Text("Files and Clipboard")
        }
    }

    private var shortcuts: some View {
        Section {
            ShortcutRow("Extract text as paragraphs", shortcut: $settings.value.captureParagraphs)
            ShortcutRow("Extract and add to the clipboard", shortcut: $settings.value.captureAdding)
            ShortcutRow("Extract and read aloud", shortcut: $settings.value.captureSpeaking)
            ShortcutRow("Extract and translate", shortcut: $settings.value.captureTranslating)
            ShortcutRow("Extract text from the previous area", subtitle: "Reads the area you dragged last time again, without the overlay.",
                        shortcut: $settings.value.capturePrevious)
            ShortcutRow("Extract text from the clipboard image", shortcut: $settings.value.captureClipboard)
            ShortcutRow("Show recent captures", shortcut: $settings.value.showRecent)
            ShortcutRow("Stop speaking", shortcut: $settings.value.stopSpeaking)
        } header: {
            Text("More Shortcuts")
        } footer: {
            Text("In the overlay: L, P, T and S pick the mode, A adds to the clipboard, R reads aloud, esc cancels.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The settings hero: a miniature of the overlay and the card, drawn from the current settings.
struct TextExtractorHero: View {
    let settings: TextExtractorSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.16) : .white)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .frame(width: 168, height: 118)
            document.offset(x: 14, y: 16)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Tint.mint.color.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Tint.mint.color, lineWidth: 1.5))
                .frame(width: 112, height: 40)
                .offset(x: 9, y: 36)
            miniCard.offset(x: 96, y: 58)
        }
        .frame(width: 236, height: 136, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(70, weight: 0.5)
            ForEach([132, 118, 128, 60, 104], id: \.self) { bar(CGFloat($0)) }
        }
    }

    private func bar(_ width: CGFloat, weight: Double = 0.18) -> some View {
        Capsule().fill(Color.primary.opacity(weight)).frame(width: width, height: 5)
    }

    /// The card with the text laid out the way the default mode copies it.
    private var miniCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ModuleIcon(symbol: settings.additive ? "text.badge.plus" : "doc.on.doc.fill", tint: .mint, size: 14)
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: 56, height: 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                switch settings.mode {
                case .lines:
                    ForEach([96, 84, 92], id: \.self) { textBar(CGFloat($0)) }
                case .paragraphs:
                    textBar(116); textBar(116); textBar(48)
                case .singleLine:
                    textBar(116)
                case .table:
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 6) { textBar(34); textBar(30); textBar(36) }
                    }
                }
            }
            .padding(6)
            .frame(width: 128, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 4) {
                ForEach(["doc.on.doc", "text.justify.left", "translate", settings.speakAfterCapture ? "speaker.wave.2.fill" : "speaker.wave.2"],
                        id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(symbol.hasSuffix(".fill") && symbol.hasPrefix("speaker") ? Tint.mint.color : Color.primary.opacity(0.6))
                        .frame(width: 29, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.22) : Color(white: 0.985)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .opacity(settings.showConfirmation && settings.feedback == .card ? 1 : 0.35)
    }

    private func textBar(_ width: CGFloat) -> some View {
        Capsule().fill(Tint.mint.color.opacity(0.55)).frame(width: width, height: 3.5)
    }
}
