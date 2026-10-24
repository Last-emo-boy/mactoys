import AppKit
import AVFoundation
import MacToysCore
import Speech
import UniformTypeIdentifiers

/// Snip dictation: listens on the microphone and transcribes on this Mac only
/// (`SFSpeechRecognizer` with `requiresOnDeviceRecognition`).
@MainActor
final class SnipDictation {
    var onText: ((String) -> Void)?
    var onStatus: ((DictationBadgeModel.Status) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finalWaiter: CheckedContinuation<Void, Never>?
    private var isFinal = false
    private var cancelled = false
    /// Set by `finish()` or `cancel()`: a setup still waiting on a permission prompt must not start the mic.
    private var stopped = false
    private var tapInstalled = false
    private let log = Log.for("zoomit")

    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        onStatus?(.preparing)
        Task { @MainActor [weak self] in await self?.prepare() }
    }

    private func prepare() async {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard !stopped else { return }
        guard speech == .authorized else { return unavailable("Speech recognition is turned off for MacToys") }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard !stopped else { return }
        guard microphone else { return unavailable("Microphone access is turned off for MacToys") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            return unavailable("Dictation isn't available")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return unavailable("On-device dictation isn't available for \(recognizer.locale.localizedString(forIdentifier: recognizer.locale.identifier) ?? "this language")")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return unavailable("No microphone found") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        guard !stopped else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log.error("Dictation audio failed: \(error.localizedDescription, privacy: .public)")
            return unavailable("The microphone couldn’t be started")
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.received(text, final: final || failed) }
        }
        onStatus?(.listening)
    }

    private func received(_ text: String?, final: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            onText?(text)
        }
        if final { isFinal = true; resumeWaiter() }
    }

    private func unavailable(_ reason: String) {
        stopAudio()
        isFinal = true
        onStatus?(.unavailable(reason))
        resumeWaiter()
    }

    /// Stops listening and waits up to `grace` seconds for the final words. `nil` when cancelled.
    func finish(grace: TimeInterval = 2.5) async -> String? {
        guard isActive else { return "" }
        stopped = true
        onStatus?(.transcribing)
        stopAudio()
        request?.endAudio()
        if !isFinal {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finalWaiter = c
                DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
                    MainActor.assumeIsolated { self?.resumeWaiter() }
                }
            }
        }
        task?.finish()
        isActive = false
        return cancelled ? nil : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        cancelled = true
        stopped = true
        stopAudio()
        task?.cancel()
        isActive = false
        resumeWaiter()
    }

    private func resumeWaiter() {
        finalWaiter?.resume()
        finalWaiter = nil
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
}

/// Snip: select a region of the frozen screen and copy it (or save it), optionally with a
/// dictated note — press Space while dragging and speak.
@MainActor
final class SnipController {
    var onEnd: (() -> Void)?

    private let settings: ZoomItSettings
    private let save: Bool
    private var selector: RegionSelector?
    private var dictation: SnipDictation?
    private var image: CGImage?
    private var transcribing = false
    private var ended = false

    init(settings: ZoomItSettings, save: Bool) {
        self.settings = settings
        self.save = save
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            finish()
            return
        }
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        Task { @MainActor [weak self] in
            do {
                let image = try await ScreenCapture.image(of: screen)
                self?.present(image, on: screen)
            } catch {
                Log.for("zoomit").error("Snip capture failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle")
                self?.finish()
            }
        }
    }

    func cancel() {
        dictation?.cancel()
        selector?.close()
        finish()
    }

    private func present(_ image: CGImage, on screen: NSScreen) {
        guard !ended else { return }
        self.image = image
        let selector = RegionSelector(screen: screen, frozen: image)
        self.selector = selector
        selector.onSpace = { [weak self] in self?.startDictation() }
        selector.onEscape = { [weak self] in self?.cancel() }
        selector.onFinish = { [weak self] rect, flags in self?.selected(rect, shift: flags.contains(.shift)) }
        if settings.dictateEverySnip && settings.snipDictation {
            selector.onDragStart = { [weak self] in self?.startDictation() }
        }
        selector.show()
    }

    private func startDictation() {
        guard settings.snipDictation, dictation == nil, let selector else { return }
        let d = SnipDictation()
        d.onStatus = { [weak selector] status in
            selector?.badge.status = status
            selector?.refreshBadge()
        }
        d.onText = { [weak selector] text in
            selector?.badge.text = text
            selector?.refreshBadge()
        }
        dictation = d
        selector.showBadge()
        d.start()
    }

    private func selected(_ rect: CGRect?, shift: Bool) {
        guard let rect, let image, let selector else { cancel(); return }
        let scale = CGFloat(image.width) / selector.screen.frame.width
        guard let cropped = image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                      width: rect.width * scale, height: rect.height * scale).integral) else {
            cancel()
            return
        }
        let saving = save || shift
        guard let dictation, dictation.isActive else {
            selector.close(restoreFocus: !saving)
            publish(cropped, text: nil, saving: saving)
            return
        }
        transcribing = true
        selector.locked = true
        Task { @MainActor [weak self] in
            let transcript = await dictation.finish()
            guard let self else { return }
            self.transcribing = false
            selector.close(restoreFocus: !saving)
            guard let transcript else { self.finish(); return }
            var note = transcript
            if !note.isEmpty, !self.settings.dictationPrefix.isEmpty { note = self.settings.dictationPrefix + " " + note }
            self.publish(cropped, text: note.isEmpty ? nil : note, saving: saving)
        }
    }

    private func publish(_ image: CGImage, text: String?, saving: Bool) {
        if saving {
            saveToFile(image, text: text)
        } else {
            SnipPasteboard.write(image, text: text)
            HUD.show(text == nil ? "Snip copied" : "Snip and dictation copied", symbol: "scissors")
            finish()
        }
    }

    private func saveToFile(_ image: CGImage, text: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Snip \(ZoomDrawSession.stamp()).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = panel.url {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let jpeg = url.pathExtension.lowercased().hasPrefix("jp")
                    do {
                        try rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:])?
                            .write(to: url)
                    } catch {
                        Log.for("zoomit").error("Saving snip failed: \(error.localizedDescription, privacy: .public)")
                        HUD.show("Couldn’t save the snip", symbol: "exclamationmark.triangle")
                    }
                    if self.settings.copyWhenSaving || text != nil {
                        SnipPasteboard.write(self.settings.copyWhenSaving ? image : nil, text: text)
                    }
                }
                self.finish()
            }
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
        onEnd = nil
    }
}

/// Puts a snip on the pasteboard in every useful flavor: PNG and TIFF for image apps, RTFD and
/// HTML (image followed by the note) for rich-text apps, and plain text for the note alone.
enum SnipPasteboard {
    static func write(_ image: CGImage?, text: String?) {
        let item = NSPasteboardItem()
        var png: Data?
        if let image {
            let rep = NSBitmapImageRep(cgImage: image)
            png = rep.representation(using: .png, properties: [:])
            if let text, let png {
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = "Snip.png"
                let rich = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
                rich.append(NSAttributedString(string: "\n" + text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                if let rtfd = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
                    item.setData(rtfd, forType: .rtfd)
                }
                item.setString(html(png: png, text: text), forType: .html)
            }
            if let png { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        if let text { item.setString(text, forType: .string) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func html(png: Data, text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        return "<img src=\"data:image/png;base64,\(png.base64EncodedString())\"><p>\(escaped)</p>"
    }
}
