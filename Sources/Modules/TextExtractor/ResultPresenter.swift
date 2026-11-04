import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Where the result card goes, in Cocoa coordinates.
enum CardPlacement {
    /// Below the selection and aligned with its left edge; above it when there's no room below;
    /// beside it when there's room nowhere else; always inside `visible`. Without a selection, the
    /// top-right corner of `visible`, where notifications appear.
    static func origin(for size: CGSize, near selection: CGRect?, in visible: CGRect, gap: CGFloat = 12) -> CGPoint {
        let margin: CGFloat = 8
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX + margin), visible.maxX - size.width - margin) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY + margin), visible.maxY - size.height - margin) }
        guard let s = selection else {
            return CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        }
        let below = s.minY - gap - size.height
        if below >= visible.minY + margin { return CGPoint(x: clampX(s.minX), y: below) }
        let above = s.maxY + gap
        if above + size.height <= visible.maxY - margin { return CGPoint(x: clampX(s.minX), y: above) }
        if s.maxX + gap + size.width <= visible.maxX - margin { return CGPoint(x: s.maxX + gap, y: clampY(s.maxY - size.height)) }
        if s.minX - gap - size.width >= visible.minX + margin {
            return CGPoint(x: s.minX - gap - size.width, y: clampY(s.maxY - size.height))
        }
        return CGPoint(x: clampX(s.minX), y: clampY(visible.minY + margin))
    }
}

/// Turns recognized text into a result: copies it (or adds it to the collection), remembers it,
/// reads it aloud, and shows the card or a notice. Also reads files and clipboard images.
@MainActor
final class ResultPresenter {
    let settings: Persisted<TextExtractorSettings>
    let history: CaptureHistory
    let card: CardModel
    private let log = Log.for("textextractor")
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var copiedWork: DispatchWorkItem?
    private var hovering = false
    private var engaged = false
    private var additive = AdditiveClipboard()
    /// How the shown capture can be laid out again (Join Lines / Keep Lines).
    private var layout: CaptureLayout?
    private var work: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?

    /// The text behind a capture, kept so its lines can be joined or kept again.
    enum CaptureLayout {
        /// Recognized boxes, page by page.
        case boxes([[TextBox]])
        /// Plain text with its original line breaks.
        case text(String)
    }

    init(settings: Persisted<TextExtractorSettings>, history: CaptureHistory) {
        self.settings = settings
        self.history = history
        card = CardModel(history: history)
        card.target = Translator.target(settings.value.translateTarget)
        card.onAction = { [weak self] in self?.handle($0) }
    }

    /// Captures collected on the clipboard right now.
    var addedCount: Int {
        additive.isCurrent(changeCount: NSPasteboard.general.changeCount) ? additive.pieces.count : 0
    }

    // MARK: Delivering

    /// A finished recognition. `pages` are boxes in reading order (one entry per image or PDF page);
    /// `anchor` is the selection in Cocoa coordinates, nil for files and the clipboard.
    func deliver(pages: [[TextBox]], barcodes: [Barcode], mode requested: TextExtractorSettings.Mode, source: Capture.Source,
                 intent: CaptureIntent, anchor: CGRect?, screen: NSScreen?) {
        let s = settings.value
        let mode = intent.mode ?? requested
        let text = Self.text(pages, mode: mode)
        let codes = s.detectBarcodes ? barcodes : []
        var capture = Capture(text: text, mode: mode, source: source, language: LanguageDetector.dominant(text), barcodes: codes)
        capture.barcodeFirst = Capture.prefersBarcodes(text: text, barcodes: codes)
        guard !capture.isEmpty else {
            showEmpty(String(localized: "No text found"), anchor: anchor, screen: screen)
            return
        }
        layout = capture.barcodeFirst || mode == .table ? nil : .boxes(pages)
        publish(capture, add: intent.add ?? s.additive)
        if intent.speak || s.speakAfterCapture { speak(capture.copiedText, id: "capture:\(capture.id)", language: capture.language) }
        if s.openLinks, capture.barcodeFirst, case .link(let url) = capture.barcodes[0].content {
            NSWorkspace.shared.open(url)
        }
        guard s.showConfirmation || intent.translate else { return }
        if s.feedback == .notice && !intent.translate {
            Self.notice(for: capture)
            return
        }
        showCard(capture, anchor: anchor, screen: screen)
        if intent.translate, !capture.barcodeFirst { startTranslation() }
    }

    /// A single word picked with a click.
    func deliverWord(_ word: String?, anchor: CGRect?, screen: NSScreen?) {
        guard let word, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if settings.value.showConfirmation { HUD.show("No word under the pointer", symbol: "text.viewfinder") }
            return
        }
        let capture = Capture(text: word, mode: .singleLine, source: .screen, language: LanguageDetector.dominant(word))
        layout = nil
        publish(capture, add: settings.value.additive)
        guard settings.value.showConfirmation else { return }
        if settings.value.feedback == .notice {
            HUD.show(String(localized: "Copied “\(word)”", comment: "Text Extractor copied one word; %@ is the word"), symbol: "doc.on.doc")
        } else {
            showCard(capture, anchor: anchor, screen: screen)
        }
    }

    static func text(_ pages: [[TextBox]], mode: TextExtractorSettings.Mode) -> String {
        pages.map { TextRecognizer.text($0, mode: mode) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Copies (or adds) the capture and remembers it.
    private func publish(_ capture: Capture, add: Bool) {
        let pb = NSPasteboard.general
        let combined: String
        if add {
            combined = additive.add(capture.copiedText, changeCount: pb.changeCount, separator: settings.value.separator)
        } else {
            additive.reset()
            combined = capture.copiedText
        }
        write(combined)
        if add { additive.didWrite(changeCount: pb.changeCount) }
        if settings.value.keepRecent { history.add(capture) }
        card.addedCount = add ? additive.pieces.count : 0
    }

    private func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// The brief notice used instead of the card.
    private static func notice(for capture: Capture) {
        if capture.barcodeFirst {
            HUD.show(capture.barcodes.count > 1 ? String(localized: "\(capture.barcodes.count) codes copied", comment: "Card title: several QR codes or barcodes")
                     : String(localized: "Copied “\(BarcodeView.headline(capture.barcodes[0].content))”",
                              comment: "Text Extractor copied one word; %@ is the word"),
                     symbol: capture.barcodes[0].isMatrix ? "qrcode" : "barcode")
            return
        }
        let lines = capture.lineCount
        if lines > 1 {
            HUD.show(String(localized: "Copied \(lines) lines", comment: "Text Extractor copied several lines of text"), symbol: "doc.on.doc")
        } else {
            HUD.show("Copied text", symbol: "doc.on.doc")
        }
    }

    private func showEmpty(_ message: String, anchor: CGRect?, screen: NSScreen?) {
        guard settings.value.showConfirmation else { return }
        if settings.value.feedback == .notice {
            HUD.show(message, symbol: "text.viewfinder")
            return
        }
        resetCard()
        card.phase = .empty(message)
        present(anchor: anchor, screen: screen)
    }

    private func showCard(_ capture: Capture, anchor: CGRect?, screen: NSScreen?) {
        resetCard()
        card.capture = capture
        card.phase = .result
        card.canJoin = layout != nil
        present(anchor: anchor, screen: screen)
    }

    private func resetCard() {
        translationTask?.cancel()
        card.translation = .hidden
        card.downloadRequest = nil
        card.justCopied = nil
        card.showRecent = false
        card.target = Translator.target(settings.value.translateTarget)
    }

    // MARK: Files and the clipboard

    /// Reads images and PDFs (Finder, a drop, a URL); the card shows progress.
    func recognize(files: [URL], intent: CaptureIntent = .standard) {
        let supported = files.filter(FileRecognizer.isSupported)
        guard !supported.isEmpty else {
            let name = files.first?.lastPathComponent ?? ""
            fail(RecognitionError.unsupported(name).localizedDescription)
            return
        }
        let s = settings.value
        let options = TextRecognizer.Options(language: s.language, languageCorrection: s.languageCorrection)
        let barcodes = s.detectBarcodes
        let name = supported.count == 1 ? supported[0].lastPathComponent
            : String(localized: "\(supported.count) files", comment: "Where a capture came from: several files")
        resetCard()
        card.capture = nil
        card.phase = .working(String(localized: "Reading “\(name)”…", comment: "Card title while reading a file; %@ is its name"), detail: nil)
        present(anchor: nil, screen: nil)
        work?.cancel()
        let card = self.card
        work = Task { [weak self] in
            var pages: [[TextBox]] = []
            var codes: [Barcode] = []
            for (i, url) in supported.enumerated() {
                let progress: @Sendable (Int, Int) -> Void = { page, count in
                    guard count > 1 || supported.count > 1 else { return }
                    let detail = count > 1 ? String(localized: "Page \(page) of \(count)", comment: "Progress while reading a PDF")
                        : String(localized: "File \(i + 1) of \(supported.count)", comment: "Progress while reading several files")
                    Task { @MainActor in
                        guard case .working(let title, _) = card.phase else { return }
                        card.phase = .working(title, detail: detail)
                    }
                }
                let result: Result<[FileRecognizer.Page], Error> = await background {
                    Result { try FileRecognizer.recognize(url, options: options, barcodes: barcodes, progress: progress) }
                }
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .success(let list):
                    pages += list.map(\.boxes)
                    codes += list.flatMap(\.barcodes).filter { !codes.contains($0) }
                case .failure(let error):
                    self.log.error("Reading \(url.path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                    if supported.count == 1 { self.fail(error.localizedDescription); return }
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.deliver(pages: pages, barcodes: codes, mode: self.settings.value.mode, source: .file(name), intent: intent,
                         anchor: nil, screen: nil)
        }
    }

    /// Reads the image on the clipboard (or image and PDF files copied in Finder).
    func recognizeClipboard(intent: CaptureIntent = .standard) {
        let files = FileRecognizer.clipboardFileURLs()
        if !files.isEmpty { recognize(files: files, intent: intent); return }
        guard let image = FileRecognizer.clipboardImage() else {
            HUD.show(RecognitionError.noImageOnClipboard.localizedDescription, symbol: "doc.on.clipboard")
            return
        }
        let s = settings.value
        let options = TextRecognizer.Options(language: s.language, languageCorrection: s.languageCorrection, words: s.mode == .table)
        let barcodes = s.detectBarcodes
        work?.cancel()
        work = Task { [weak self] in
            let result: Result<FileRecognizer.Page, Error> = await background {
                Result { try FileRecognizer.recognize(image, options: options, barcodes: barcodes) }
            }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let page):
                self.deliver(pages: [page.boxes], barcodes: page.barcodes, mode: self.settings.value.mode, source: .clipboard,
                             intent: intent, anchor: nil, screen: nil)
            case .failure(let error):
                self.log.error("Clipboard recognition failed: \(error.localizedDescription, privacy: .public)")
                self.fail(error.localizedDescription)
            }
        }
    }

    /// The open panel for images and PDFs.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileRecognizer.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = String(localized: "Extract Text from Images or PDFs", comment: "Open panel title")
        panel.prompt = String(localized: "Extract Text", comment: "Open panel button: read the text of the chosen files")
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        recognize(files: panel.urls)
    }

    /// The card with the newest capture and the recent list open.
    func showRecent() {
        resetCard()
        card.capture = history.items.first
        card.phase = card.capture == nil ? .empty(String(localized: "No recent captures")) : .result
        layout = card.capture.flatMap { $0.mode == .lines && !$0.barcodeFirst ? CaptureLayout.text($0.text) : nil }
        card.canJoin = layout != nil
        card.addedCount = addedCount
        card.showRecent = true
        present(anchor: nil, screen: nil)
        engaged = true
    }

    /// Empties the additive collection.
    func startOver() {
        additive.reset()
        card.addedCount = 0
    }

    private func fail(_ message: String) {
        if settings.value.feedback == .notice || !settings.value.showConfirmation {
            HUD.show(message, symbol: "exclamationmark.triangle")
            return
        }
        resetCard()
        card.capture = nil
        card.phase = .failed(message)
        present(anchor: nil, screen: nil)
    }

    // MARK: Card actions

    private func handle(_ action: CardAction) {
        switch action {
        case .hover, .close: break
        default: engaged = true
        }
        switch action {
        case .copy:
            guard let c = card.capture else { return }
            write(c.copiedText)
            additive.reset()
            card.addedCount = 0
            flashCopied("capture")
        case .copyText(let text):
            write(text)
            flashCopied(text)
        case .toggleJoin:
            toggleJoin()
        case .translate:
            if card.translation == .hidden { startTranslation() } else { translationTask?.cancel(); card.translation = .hidden }
        case .setTarget(let code):
            settings.value.translateTarget = code
            card.target = Translator.target(code)
            startTranslation()
        case .openLanguageSettings:
            Translator.openLanguageSettings()
        case .speak(let text, let id, let language):
            if Speaker.shared.speakingID == id { Speaker.shared.stop() } else { speak(text, id: id, language: language) }
        case .open(let url):
            NSWorkspace.shared.open(url)
            close()
        case .barcode(let code):
            perform(code)
        case .show(let capture):
            card.capture = capture
            card.phase = .result
            card.translation = .hidden
            layout = capture.mode == .lines && !capture.barcodeFirst ? .text(capture.text) : nil
            card.canJoin = layout != nil
            write(capture.copiedText)
            additive.reset()
            card.addedCount = 0
            flashCopied("capture")
        case .clearRecent:
            history.clear()
            card.showRecent = false
        case .startOver:
            startOver()
        case .close:
            close()
        case .drop(let urls):
            recognize(files: urls)
        case .hover(let inside):
            hovering = inside
            if inside { hideWork?.cancel() } else { scheduleHide(after: engaged ? 20 : 3) }
        case .engage:
            break
        }
    }

    private func flashCopied(_ id: String) {
        card.justCopied = id
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.card.justCopied == id { self?.card.justCopied = nil } }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func toggleJoin() {
        guard var c = card.capture, let layout else { return }
        let joined = c.mode == .paragraphs || c.mode == .singleLine
        let mode: TextExtractorSettings.Mode = joined ? .lines : .paragraphs
        switch layout {
        case .boxes(let pages): c.text = Self.text(pages, mode: mode)
        case .text(let lines): c.text = mode == .lines ? lines : TextJoiner.joinLines(lines)
        }
        c.mode = mode
        let pb = NSPasteboard.general
        if additive.isCurrent(changeCount: pb.changeCount) {
            write(additive.replaceLast(c.copiedText, separator: settings.value.separator))
            additive.didWrite(changeCount: pb.changeCount)
        } else {
            write(c.copiedText)
        }
        card.capture = c
        history.update(c)
        if card.translation != .hidden { startTranslation() }
    }

    private func startTranslation() {
        guard let c = card.capture, !c.text.isEmpty else { return }
        translationTask?.cancel()
        card.downloadRequest = nil
        card.translation = .working
        let target = card.target
        translationTask = Task { [weak self] in
            let outcome = await Translator.translate(c.text, source: c.language, target: target)
            guard !Task.isCancelled, let self, self.card.capture?.id == c.id else { return }
            switch outcome {
            case .translated(let text): self.card.translation = .done(text)
            case .sameLanguage: self.card.translation = .sameLanguage
            case .needsDownload: self.card.translation = .needsDownload
            case .unsupported: self.card.translation = .unsupported
            case .failed(let message): self.card.translation = .failed(message)
            }
        }
    }

    private func speak(_ text: String, id: String, language: String?) {
        let s = settings.value
        Speaker.shared.speak(text, id: id, language: language, voice: s.voice, rate: s.speechRate)
    }

    /// The action that fits a code: open a link, write an email, add a contact or event.
    private func perform(_ code: Barcode) {
        let content = code.content
        if let url = content.openURL {
            NSWorkspace.shared.open(url)
            close()
            return
        }
        let ext: String
        switch content {
        case .contact: ext = "vcf"
        case .event: ext = "ics"
        default: return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacToys-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try code.payload.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
            close()
        } catch {
            log.error("Could not write \(ext, privacy: .public) file: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The panel

    /// Shows the card near `anchor` (Cocoa coordinates) on `screen`. Without an anchor it stays
    /// where it is when it's already up (a file dropped on it), else goes to the corner of the screen
    /// under the pointer.
    private func present(anchor: CGRect?, screen: NSScreen?) {
        let p = panel ?? makePanel()
        let size = fittingSize(p)
        let target = screen ?? anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? NSScreen.underMouse
            ?? NSScreen.main
        let visible = target?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var frame: CGRect
        if anchor == nil, p.isVisible {
            frame = CGRect(x: p.frame.minX, y: p.frame.maxY - size.height, width: size.width, height: size.height)
        } else {
            frame = CGRect(origin: CardPlacement.origin(for: size, near: anchor, in: visible), size: size)
        }
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        let appearing = !p.isVisible
        p.setFrame(frame, display: true)
        p.invalidateShadow()
        if appearing {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.05 : 0.18
                p.animator().alphaValue = 1
            }
        }
        hovering = false
        engaged = engaged && !appearing
        scheduleHide(after: settings.value.cardSeconds)
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(frame: CGRect(x: 0, y: 0, width: ResultCard.width, height: 200), interactive: true,
                             acceptsKey: false, level: .floating)
        p.hasShadow = true
        p.setContent(CardHost(model: card) { [weak self] size in self?.contentSizeChanged(size) })
        panel = p
        return p
    }

    private func fittingSize(_ p: OverlayPanel) -> CGSize {
        let fit = p.contentView?.fittingSize ?? CGSize(width: ResultCard.width, height: 200)
        return CGSize(width: ResultCard.width, height: max(60, ceil(fit.height)))
    }

    /// The card grew or shrank (translation, recent list): keep its top edge in place.
    private func contentSizeChanged(_ size: CGSize) {
        guard let p = panel, p.isVisible, abs(p.frame.height - size.height) > 0.5 else { return }
        var frame = p.frame
        let top = frame.maxY
        frame.size = CGSize(width: ResultCard.width, height: ceil(size.height))
        frame.origin.y = top - frame.height
        if let visible = p.screen?.visibleFrame, frame.minY < visible.minY + 8 { frame.origin.y = visible.minY + 8 }
        p.setFrame(frame, display: true)
        p.invalidateShadow()
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep it while it's busy or being used.
                if self.hovering || self.isBusy { self.scheduleHide(after: 3); return }
                self.close()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 1), execute: work)
    }

    private var isBusy: Bool {
        if case .working = card.phase { return true }
        if card.translation == .working || card.downloadRequest != nil { return true }
        if card.dropTargeted { return true }
        if let id = card.capture?.id, Speaker.shared.speakingID?.hasSuffix(id.uuidString) == true { return true }
        return false
    }

    func close() {
        hideWork?.cancel()
        work?.cancel()
        translationTask?.cancel()
        engaged = false
        hovering = false
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if p.alphaValue < 0.01 { p.orderOut(nil) }
            }
        })
    }
}

/// The card in its panel: reports its size so the panel fits it, and appears with a short spring.
struct CardHost: View {
    let model: CardModel
    let onSize: (CGSize) -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ResultCard(model: model)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .onAppear { withAnimation(.snappy(duration: 0.22)) { shown = true } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Runs blocking work off the main actor.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}
