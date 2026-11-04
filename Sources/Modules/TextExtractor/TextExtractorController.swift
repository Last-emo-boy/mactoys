import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Freezes every display, lets the user drag over text, recognizes it and hands it to the presenter.
@MainActor
final class TextExtractorController {
    private let settings: Persisted<TextExtractorSettings>
    private let presenter: ResultPresenter
    private let log = Log.for("textextractor")
    private var panels: [(screen: NSScreen, panel: OverlayPanel, image: CGImage, model: SelectionModel)] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var starting = false
    private var intent = CaptureIntent.standard
    /// The last dragged area, for "extract text from the previous area".
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)?

    init(settings: Persisted<TextExtractorSettings>, presenter: ResultPresenter) {
        self.settings = settings
        self.presenter = presenter
    }

    var isActive: Bool { !panels.isEmpty || starting }

    func begin(_ intent: CaptureIntent = .standard) {
        guard !isActive else { cancel(); return }
        guard ensurePermission() else { return }
        starting = true
        self.intent = intent
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { [weak self] in
            let shots = await ScreenCapture.allScreens()
            // Cancelled (hotkey pressed again, module stopped) while capturing.
            guard let self, self.starting else { return }
            self.starting = false
            guard !shots.isEmpty else {
                HUD.show("The screen couldn't be captured", symbol: "exclamationmark.triangle")
                return
            }
            self.present(shots)
        }
    }

    /// Recognizes the area dragged last time again, without the overlay.
    func capturePreviousArea(_ intent: CaptureIntent = .standard) {
        guard !isActive, ensurePermission() else { return }
        guard let area = lastArea, let screen = NSScreen.screens.first(where: { $0.displayID == area.display }) else {
            HUD.show("Drag over some text first", symbol: "text.viewfinder")
            return
        }
        starting = true
        Task { [weak self] in
            let image = try? await ScreenCapture.image(of: screen)
            guard let self, self.starting else { return }
            self.starting = false
            guard let image else {
                HUD.show("The screen couldn't be captured", symbol: "exclamationmark.triangle")
                return
            }
            let s = self.settings.value
            self.recognize(image: image, screen: screen, rect: area.rect, click: nil, mode: intent.mode ?? s.mode,
                           language: s.language, intent: intent)
        }
    }

    private func ensurePermission() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return false
        }
        return true
    }

    private func present(_ shots: [(NSScreen, CGImage)]) {
        let s = settings.value
        for (screen, image) in shots {
            let model = SelectionModel(mode: intent.mode ?? s.mode, language: s.language)
            model.add = intent.add ?? s.additive
            model.speak = intent.speak || s.speakAfterCapture
            let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
            let frozen = Image(nsImage: NSImage(cgImage: image, size: screen.frame.size))
            panel.setContent(TextExtractorOverlay(
                model: model,
                background: frozen.resizable(),
                onFinish: { [weak self, weak model] rect, click in
                    guard let self, let model else { return }
                    self.finish(on: screen, model: model, rect: rect, click: click)
                },
                onSettingsChange: { [weak self] model in
                    self?.sync(from: model)
                }))
            panels.append((screen, panel, image, model))
        }
        NSApp.activate()
        for entry in panels {
            if entry.screen == NSScreen.underMouse { entry.panel.makeKeyAndOrderFront(nil) } else { entry.panel.orderFrontRegardless() }
        }
        NSCursor.crosshair.set()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Esc cancels; L, P, T, S pick the mode; A toggles adding to the clipboard, R reading aloud.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.uppercased(), let model = panels.first?.model else { return false }
        if let mode = TextExtractorSettings.Mode.allCases.first(where: { $0.key == key }) {
            model.mode = mode
        } else if key == "A" {
            model.add.toggle()
        } else if key == "R" {
            model.speak.toggle()
        } else {
            return false
        }
        sync(from: model)
        return true
    }

    /// Keeps every screen's overlay in step; the language choice is remembered.
    private func sync(from source: SelectionModel) {
        if settings.value.language != source.language { settings.value.language = source.language }
        for entry in panels where entry.model !== source {
            entry.model.mode = source.mode
            entry.model.language = source.language
            entry.model.add = source.add
            entry.model.speak = source.speak
        }
    }

    func cancel() {
        starting = false
        close()
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard !panels.isEmpty else { return }
        for entry in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        if let previousApp, !previousApp.isTerminated, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
    }

    private func finish(on screen: NSScreen, model: SelectionModel, rect: CGRect?, click: CGPoint?) {
        guard let entry = panels.first(where: { $0.model === model }) else { return }
        // ⌥ at release adds to the clipboard instead of replacing it (or the other way round).
        var intent = self.intent
        intent.add = NSEvent.modifierFlags.contains(.option) ? !model.add : model.add
        intent.speak = model.speak
        intent.mode = model.mode
        if let rect { lastArea = (screen.displayID, rect) }
        let image = entry.image
        close()
        recognize(image: image, screen: screen, rect: rect, click: click, mode: model.mode, language: model.language, intent: intent)
    }

    /// Recognizes `rect` (or a strip around `click`) of a screen image; points are screen-local, top-left.
    private func recognize(image: CGImage, screen: NSScreen, rect: CGRect?, click: CGPoint?,
                           mode: TextExtractorSettings.Mode, language: String?, intent: CaptureIntent) {
        let scale = CGFloat(image.width) / screen.frame.width
        let s = settings.value
        var options = TextRecognizer.Options(language: language, languageCorrection: s.languageCorrection)
        let region: CGRect
        let clickInRegion: CGPoint?
        if let rect {
            region = rect
            clickInRegion = nil
            options.words = mode == .table
        } else if let click {
            // Click a word: read a strip around the click and pick the word under it.
            region = CGRect(x: click.x - 360, y: click.y - 90, width: 720, height: 180)
                .intersection(CGRect(origin: .zero, size: screen.frame.size))
            clickInRegion = CGPoint(x: (click.x - region.minX) * scale, y: (click.y - region.minY) * scale)
            options.words = true
        } else {
            return
        }
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return }
        let anchor = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                            width: region.width, height: region.height)
        let opts = options
        let barcodes = s.detectBarcodes && clickInRegion == nil
        Task.detached(priority: .userInitiated) { [log, presenter] in
            var boxes: [TextBox] = []
            var codes: [Barcode] = []
            do {
                (boxes, codes) = try TextRecognizer.analyze(crop, options: opts, barcodes: barcodes)
            } catch {
                log.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            }
            let found = boxes
            let foundCodes = codes
            await MainActor.run {
                if let p = clickInRegion {
                    presenter.deliverWord(TextLayout.word(at: p, in: found, tolerance: 12 * scale), anchor: anchor, screen: screen)
                } else {
                    presenter.deliver(pages: [found], barcodes: foundCodes, mode: mode, source: .screen, intent: intent,
                                      anchor: anchor, screen: screen)
                }
            }
        }
    }
}
