import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Freezes every display, lets the user drag over text, recognizes it and copies it.
@MainActor
final class TextExtractorController {
    private let settings: Persisted<TextExtractorSettings>
    private let log = Log.for("textextractor")
    private var panels: [(screen: NSScreen, panel: OverlayPanel, image: CGImage, model: SelectionModel)] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var starting = false

    init(settings: Persisted<TextExtractorSettings>) {
        self.settings = settings
    }

    var isActive: Bool { !panels.isEmpty || starting }

    func begin(mode: TextExtractorSettings.Mode? = nil) {
        guard !isActive else { cancel(); return }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        starting = true
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
            self.present(shots, mode: mode ?? self.settings.value.mode)
        }
    }

    private func present(_ shots: [(NSScreen, CGImage)], mode: TextExtractorSettings.Mode) {
        let s = settings.value
        for (screen, image) in shots {
            let model = SelectionModel(mode: mode, language: s.language)
            let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
            let frozen = Image(nsImage: NSImage(cgImage: image, size: screen.frame.size))
            panel.setContent(TextExtractorOverlay(
                model: model,
                background: frozen.resizable(),
                onFinish: { [weak self, weak model] rect, click in
                    guard let self, let model else { return }
                    self.finish(on: screen, model: model, rect: rect, click: click)
                },
                onSettingsChange: { [weak self] mode, language in
                    guard let self else { return }
                    self.settings.value.language = language
                    for entry in self.panels { entry.model.mode = mode; entry.model.language = language }
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
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancel()
                return nil
            }
            return event
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
        let image = entry.image
        let scale = CGFloat(image.width) / screen.frame.width
        let s = settings.value
        let mode = model.mode
        var options = TextRecognizer.Options(language: model.language, languageCorrection: s.languageCorrection)
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
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { close(); return }
        close()
        let notify = s.showConfirmation
        let opts = options
        Task.detached(priority: .userInitiated) { [log] in
            let result: String?
            do {
                let boxes = try TextRecognizer.recognize(crop, options: opts)
                if let p = clickInRegion {
                    result = TextLayout.word(at: p, in: boxes, tolerance: 12 * scale)
                } else {
                    switch mode {
                    case .lines: result = TextLayout.lines(boxes)
                    case .singleLine: result = TextLayout.singleLine(boxes)
                    case .table: result = TextLayout.table(boxes)
                    }
                }
            } catch {
                log.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                result = nil
            }
            await MainActor.run { Self.deliver(result, notify: notify, word: clickInRegion != nil) }
        }
    }

    private static func deliver(_ text: String?, notify: Bool, word: Bool) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if notify { HUD.show(word ? "No word under the pointer" : "No text found", symbol: "text.viewfinder") }
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard notify else { return }
        if word {
            HUD.show("Copied “\(text)”", symbol: "doc.on.doc")
        } else {
            let lines = text.split(whereSeparator: \.isNewline).count
            HUD.show(lines > 1 ? "Copied \(lines) lines" : "Copied text", symbol: "doc.on.doc")
        }
    }
}
