import AppKit
import AVFoundation
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// ZoomIt: zoom (⌃⌥1), draw (⌃⌥2), break timer (⌃⌥3), Live Zoom (⌃⌥4), record (⌃⌥5, region ⌃⌥⇧5,
/// window ⌃⌥⌘5), snip (⌃⌥6, save ⌃⌥⇧6, Space while dragging to dictate) and DemoType (⌃⌥7,
/// back ⌃⌥⇧7).
///
/// URL actions: `zoom`, `draw`, `break`, `livezoom`, `record`, `record-region`, `record-window`,
/// `stop-recording`, `snip`, `snip-save`, `demotype`, `demotype-back`.
@MainActor
public final class ZoomItModule: ToyModule {
    public let info = ModuleInfo(
        id: "zoomit", name: "ZoomIt",
        summary: "Zoom, annotate, time breaks and record the screen for presentations.",
        symbol: "plus.magnifyingglass", tint: .red, category: .systemTools,
        permissions: [.screenRecording, .accessibility], enabledByDefault: true,
        keywords: ["zoom", "draw", "annotate", "presentation", "break", "timer", "record", "snip", "demotype", "screenshot"])

    public let settings = Persisted("zoomit", default: ZoomItSettings())
    private var running = false
    private var session: ZoomDrawSession?
    private var liveZoom: LiveZoomController?
    private var breakTimer: BreakTimerController?
    private var snip: SnipController?
    private let recorder = ScreenRecorder()
    private var recordingBusy = false
    private var indicator: OverlayPanel?
    private var regionFrame: OverlayPanel?
    private var regionSelector: RegionSelector?
    private let indicatorModel = RecordingIndicatorModel()
    private var indicatorTimer: Timer?
    private let demoType = DemoTypeController()
    private let log = Log.for("zoomit")

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkeys()
        }
        recorder.onInterrupted = { [weak self] in self?.stopRecording() }
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "zoomit.")
        session?.close()
        session = nil
        stopLiveZoom()
        breakTimer?.stop()
        breakTimer = nil
        snip?.cancel()
        snip = nil
        regionSelector?.close()
        regionSelector = nil
        demoType.reset()
        if recorder.isRecording { stopRecording() }
    }

    public func settingsView() -> AnyView {
        AnyView(ZoomItSettingsView(module: self, settings: settings))
    }

    // MARK: Shortcuts

    private func registerHotkeys() {
        let s = settings.value
        let bindings: [(String, Shortcut?, () -> Void)] = [
            ("zoom", s.zoomShortcut, { [weak self] in self?.toggleZoom() }),
            ("draw", s.drawShortcut, { [weak self] in self?.draw() }),
            ("break", s.breakShortcut, { [weak self] in self?.toggleBreak() }),
            ("livezoom", s.liveZoomShortcut, { [weak self] in self?.toggleLiveZoom() }),
            ("record", s.recordShortcut, { [weak self] in self?.record(.fullScreen) }),
            ("record-region", s.recordRegionShortcut, { [weak self] in self?.record(.region) }),
            ("record-window", s.recordWindowShortcut, { [weak self] in self?.record(.window) }),
            ("snip", s.snipShortcut, { [weak self] in self?.startSnip(save: false) }),
            ("snip-save", s.snipSaveShortcut, { [weak self] in self?.startSnip(save: true) }),
            ("demotype", s.demoTypeShortcut, { [weak self] in self?.typeNextSegment() }),
            ("demotype-back", s.demoTypeBackShortcut, { [weak self] in self?.demoTypeBack() }),
        ]
        for (name, shortcut, action) in bindings {
            HotkeyCenter.shared.register("zoomit.\(name)", shortcut, onPress: action)
        }
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [
            ShortcutBinding("Zoom", s.zoomShortcut),
            ShortcutBinding("Draw", s.drawShortcut),
            ShortcutBinding("Break timer", s.breakShortcut),
            ShortcutBinding("Live Zoom", s.liveZoomShortcut),
            ShortcutBinding("Record screen", s.recordShortcut),
            ShortcutBinding("Record region", s.recordRegionShortcut),
            ShortcutBinding("Record window", s.recordWindowShortcut),
            ShortcutBinding("Snip to clipboard", s.snipShortcut),
            ShortcutBinding("Snip to file", s.snipSaveShortcut),
            ShortcutBinding("DemoType", s.demoTypeShortcut),
            ShortcutBinding("DemoType: previous segment", s.demoTypeBackShortcut),
            ShortcutBinding("Draw: pen colors", keys: ["R", "G", "B", "Y", "O", "P"]),
            ShortcutBinding("Draw: line, rectangle, ellipse, arrow", keys: ["⇧", "⌃", "Tab", "⌃⇧"]),
            ShortcutBinding("Draw: undo / erase all", keys: ["⌘Z", "E"]),
            ShortcutBinding("Draw: whiteboard / blackboard", keys: ["W", "K"]),
            ShortcutBinding("Draw: text", keys: ["T"]),
        ]
    }

    public var quickActions: [QuickAction] {
        let s = settings.value
        return [
            QuickAction(id: "zoomit.zoom", title: "Zoom", symbol: "plus.magnifyingglass", tint: .red,
                        shortcut: s.zoomShortcut) { [weak self] in self?.toggleZoom() },
            QuickAction(id: "zoomit.draw", title: "Draw on Screen", symbol: "pencil.tip.crop.circle", tint: .red,
                        shortcut: s.drawShortcut) { [weak self] in self?.draw() },
            QuickAction(id: "zoomit.break", title: "Break Timer", symbol: "timer", tint: .red,
                        shortcut: s.breakShortcut) { [weak self] in self?.toggleBreak() },
            QuickAction(id: "zoomit.snip", title: "Snip", symbol: "scissors", tint: .red,
                        shortcut: s.snipShortcut) { [weak self] in self?.startSnip(save: false) },
            QuickAction(id: "zoomit.livezoom", title: "Live Zoom", symbol: "magnifyingglass.circle.fill", tint: .red,
                        shortcut: s.liveZoomShortcut, isOn: { [weak self] in self?.liveZoom != nil },
                        detail: { "Magnified, still clickable" }) { [weak self] in self?.toggleLiveZoom() },
            QuickAction(id: "zoomit.record", title: "Record Screen", symbol: "record.circle", tint: .red,
                        shortcut: s.recordShortcut, isOn: { [weak self] in self?.recorder.isRecording ?? false },
                        detail: { [weak self] in
                            guard let self, self.recorder.isRecording else { return "Full screen · \(s.recordFormat.title)" }
                            return "Recording · \(self.indicatorModel.elapsed)"
                        }) { [weak self] in self?.record(.fullScreen) },
            QuickAction(id: "zoomit.demotype", title: "DemoType", symbol: "keyboard", tint: .red,
                        shortcut: s.demoTypeShortcut) { [weak self] in self?.typeNextSegment() },
        ]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "zoom": toggleZoom()
        case "draw": draw()
        case "break": toggleBreak()
        case "livezoom": toggleLiveZoom()
        case "record": record(.fullScreen)
        case "record-region": record(.region)
        case "record-window": record(.window)
        case "stop-recording": if recorder.isRecording { stopRecording() }
        case "snip": startSnip(save: false)
        case "snip-save": startSnip(save: true)
        case "demotype": typeNextSegment()
        case "demotype-back": demoTypeBack()
        default: return false
        }
        return true
    }

    // MARK: Zoom and draw

    func toggleZoom() {
        if let session { session.end(); return }
        stopLiveZoom()
        openSession(zoom: true)
    }

    /// Draw mode: on the zoomed image when zoomed, over Live Zoom when it's on, else on a frozen screen.
    func draw() {
        if let session {
            if session.isDrawing { session.end() } else { session.startDrawing() }
            return
        }
        if let live = liveZoom {
            live.setPanLocked(true)
            present(ZoomDrawSession(screen: live.screen, background: .live, zoom: false, settings: settings.value)) { [weak live] in
                live?.setPanLocked(false)
            }
            return
        }
        openSession(zoom: false)
    }

    private func openSession(zoom: Bool) {
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        guard CGPreflightScreenCaptureAccess() else {
            if zoom {
                HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.screenRecording)
            } else {
                // Drawing works without a capture, straight over the live screen.
                present(ZoomDrawSession(screen: screen, background: .live, zoom: false, settings: settings.value))
            }
            return
        }
        Task { @MainActor [weak self] in
            do {
                let image = try await ScreenCapture.image(of: screen)
                guard let self, self.running, self.session == nil else { return }
                self.present(ZoomDrawSession(screen: screen, background: .frozen(image), zoom: zoom, settings: self.settings.value))
            } catch {
                self?.log.error("ZoomIt capture failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func present(_ s: ZoomDrawSession, onEnd: (() -> Void)? = nil) {
        let previous = NSWorkspace.shared.frontmostApplication
        session = s
        s.state.isRecording = recorder.isRecording
        s.onRecord = { [weak self] in self?.record(.fullScreen) }
        s.onEnd = { [weak self, weak s] in
            onEnd?()
            if let self, self.session === s { self.session = nil }
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate() }
        }
        s.begin()
    }

    // MARK: Live Zoom

    func toggleLiveZoom() {
        if liveZoom != nil { stopLiveZoom(); return }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        session?.close()
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        let live = LiveZoomController(screen: screen, level: settings.value.liveZoomLevel, smooth: settings.value.smoothImage)
        live.onStop = { [weak self, weak live] in
            if let self, self.liveZoom === live { self.liveZoom = nil }
        }
        liveZoom = live
        Task { @MainActor [weak self] in
            do { try await live.start() } catch {
                self?.log.error("Live Zoom failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Live Zoom couldn’t start", symbol: "exclamationmark.triangle")
                live.stop()
            }
        }
    }

    private func stopLiveZoom() {
        if session?.screen == liveZoom?.screen, session?.startedAsZoom == false { session?.close() }
        liveZoom?.stop()
        liveZoom = nil
    }

    // MARK: Break timer

    func toggleBreak() {
        if let timer = breakTimer {
            if timer.isVisible { timer.hide() } else { timer.show() }
            return
        }
        let timer = BreakTimerController(settings: settings.value)
        timer.onEnd = { [weak self, weak timer] in
            if let self, self.breakTimer === timer { self.breakTimer = nil }
        }
        breakTimer = timer
        timer.start()
    }

    // MARK: Snip

    func startSnip(save: Bool) {
        guard snip == nil else { return }
        let s = SnipController(settings: settings.value, save: save)
        s.onEnd = { [weak self, weak s] in
            if let self, self.snip === s { self.snip = nil }
        }
        snip = s
        s.start()
    }

    // MARK: DemoType

    func typeNextSegment() { demoType.trigger(settings: settings.value) }
    func demoTypeBack() { demoType.back(settings: settings.value) }

    // MARK: Recording

    enum RecordKind { case fullScreen, region, window }

    func record(_ kind: RecordKind) {
        if recorder.isRecording { stopRecording(); return }
        guard !recordingBusy, regionSelector == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        let screen = session?.screen ?? liveZoom?.screen ?? NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        switch kind {
        case .fullScreen:
            beginRecording(.display(screen), on: screen)
        case .window:
            let mouse = ScreenGeometry.toAX(NSEvent.mouseLocation)
            guard let window = WindowInfo.onScreen().first(where: { $0.frame.contains(mouse) }) else {
                HUD.show("Point at a window to record it", symbol: "macwindow")
                return
            }
            beginRecording(.window(window.id), on: ScreenGeometry.screen(forAX: window.frame) ?? screen)
        case .region:
            let selector = RegionSelector(screen: screen, frozen: nil,
                                          aspect: settings.value.lockRegionTo16x9 ? 16.0 / 9.0 : nil)
            regionSelector = selector
            selector.onEscape = { [weak self] in
                self?.regionSelector?.close()
                self?.regionSelector = nil
            }
            selector.onFinish = { [weak self] rect, _ in
                guard let self else { return }
                self.regionSelector?.close(restoreFocus: true)
                self.regionSelector = nil
                guard let rect else { return }
                self.beginRecording(.region(screen, rect), on: screen)
            }
            selector.show()
        }
    }

    private func beginRecording(_ target: ScreenRecorder.Target, on screen: NSScreen) {
        recordingBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var wantsMic = self.settings.value.captureMicrophone
            if wantsMic {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: break
                case .notDetermined: wantsMic = await AVCaptureDevice.requestAccess(for: .audio)
                default: wantsMic = false
                }
                if !wantsMic { HUD.show("Recording without the microphone (no access)", symbol: "mic.slash") }
            }
            var config = self.settings.value
            config.captureMicrophone = wantsMic
            self.showIndicator(on: screen, region: { if case .region(_, let r) = target { r } else { nil } }())
            var excluded = [self.indicator?.windowNumber, self.regionFrame?.windowNumber, self.session?.toolbarWindowNumber]
                .compactMap { $0 }
            if let selector = self.regionSelector { excluded.append(selector.windowNumber) }
            do {
                try await self.recorder.start(target, settings: config, excluding: excluded)
            } catch where config.captureMicrophone || config.captureSystemAudio {
                // Keep recording the screen when an audio source can't be opened.
                self.log.error("Recording with audio failed: \(error.localizedDescription, privacy: .public)")
                config.captureMicrophone = false
                config.captureSystemAudio = false
                do {
                    try await self.recorder.start(target, settings: config, excluding: excluded)
                    HUD.show("Recording without audio (it couldn’t be captured)", symbol: "speaker.slash")
                } catch {
                    self.recordingFailed(error)
                    return
                }
            } catch {
                self.recordingFailed(error)
                return
            }
            self.recordingBusy = false
            // ZoomIt may have been turned off while a permission prompt held this start.
            guard self.running else { self.stopRecording(); return }
            self.session?.state.isRecording = true
        }
    }

    private func recordingFailed(_ error: Error) {
        log.error("Recording failed: \(error.localizedDescription, privacy: .public)")
        HUD.show("Recording couldn’t start", symbol: "exclamationmark.triangle")
        recordingBusy = false
        hideIndicator()
    }

    func stopRecording() {
        guard recorder.isRecording, !recordingBusy else { return }
        recordingBusy = true
        session?.state.isRecording = false
        hideIndicator()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let movie = try await self.recorder.stop()
                self.recordingBusy = false
                self.saveRecording(movie)
            } catch {
                self.recordingBusy = false
                self.log.error("Finishing the recording failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("The recording couldn’t be saved", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func saveRecording(_ movie: URL) {
        let s = settings.value
        let ext = s.recordFormat == .gif ? "gif" : movie.pathExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [s.recordFormat == .gif ? .gif : s.recordFormat == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = "ZoomIt Recording \(ZoomDrawSession.stamp()).\(ext)"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else {
                    try? FileManager.default.removeItem(at: movie)
                    return
                }
                self?.write(movie, to: url, gif: s.recordFormat == .gif, fps: min(15, s.frameRate),
                            gifScale: s.gifScaling / max(0.1, s.recordScaling))
            }
        }
    }

    private func write(_ movie: URL, to url: URL, gif: Bool, fps: Int, gifScale: Double) {
        let fm = FileManager.default
        if !gif {
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.moveItem(at: movie, to: url)
                HUD.show("Recording saved", symbol: "checkmark.circle")
            } catch {
                log.error("Saving the recording failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("The recording couldn’t be saved", symbol: "exclamationmark.triangle")
            }
            return
        }
        HUD.show("Exporting GIF…", symbol: "photo.stack", duration: 30)
        Task.detached {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try await GIFExporter.export(movie: movie, to: url, fps: fps, scale: min(1, gifScale))
                try? FileManager.default.removeItem(at: movie)
                await MainActor.run { HUD.show("GIF saved", symbol: "checkmark.circle") }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    Log.for("zoomit").error("GIF export failed: \(message, privacy: .public)")
                    HUD.show("The GIF couldn’t be exported", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private func showIndicator(on screen: NSScreen, region: CGRect?) {
        indicatorModel.elapsed = "00:00"
        let host = FirstClickHostingView(rootView: RecordingIndicator(model: indicatorModel) { [weak self] in self?.stopRecording() })
        let fit = host.fittingSize
        let vf = screen.visibleFrame
        let p = OverlayPanel(frame: CGRect(x: vf.maxX - fit.width - 16, y: vf.maxY - fit.height - 12, width: fit.width, height: fit.height),
                             interactive: true, acceptsKey: false,
                             level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        host.frame = CGRect(origin: .zero, size: fit)
        p.contentView = host
        p.orderFrontRegardless()
        indicator = p
        if let region {
            let cocoa = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                               width: region.width, height: region.height).insetBy(dx: -3, dy: -3)
            let frame = OverlayPanel(frame: cocoa, interactive: false, level: .screenSaver)
            let border = NSView(frame: CGRect(origin: .zero, size: cocoa.size))
            border.wantsLayer = true
            border.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
            border.layer?.borderWidth = 2
            border.layer?.cornerRadius = 3
            frame.contentView = border
            frame.orderFrontRegardless()
            regionFrame = frame
        }
        let start = Date()
        indicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.indicatorModel.elapsed = BreakTimerFormat.clock(Int(Date().timeIntervalSince(start)))
            }
        }
    }

    private func hideIndicator() {
        indicatorTimer?.invalidate()
        indicatorTimer = nil
        indicator?.orderOut(nil)
        indicator = nil
        regionFrame?.orderOut(nil)
        regionFrame = nil
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [
            PreviewScene("draw", size: CGSize(width: 1000, height: 600), wallpaper: false) {
                AnyView(DrawPreview().frame(maxWidth: .infinity, maxHeight: .infinity).background(PreviewWallpaper()).ignoresSafeArea())
            },
            PreviewScene("break", size: CGSize(width: 900, height: 560), wallpaper: false) { AnyView(BreakPreview()) },
            PreviewScene("recording", size: CGSize(width: 420, height: 160), wallpaper: false) {
                let model = RecordingIndicatorModel()
                model.elapsed = "01:24"
                return AnyView(RecordingIndicator(model: model) {}.fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(PreviewWallpaper()).ignoresSafeArea())
            },
        ]
    }
}

/// Sample annotations over a sample window, with the toolbar on top (design 06).
struct DrawPreview: View {
    var body: some View {
        let size = CGSize(width: 1000, height: 600)
        ZStack(alignment: .top) {
            if let image = Self.render(size: size) { Image(decorative: image, scale: 2) }
            DrawToolbar(state: {
                let s = DrawState()
                s.drawing = true
                s.tool = .arrow
                s.canUndo = true
                return s
            }(), actions: DrawToolbarActions())
            .fixedSize()
            .padding(.top, 16)
        }
        .frame(width: size.width, height: size.height)
    }

    static func render(size: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        // A window with a code-like body.
        let window = CGRect(x: 120, y: 110, width: 760, height: 430)
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: window.minX + 16 + CGFloat(i) * 20, y: window.minY + 14, width: 12, height: 12))
        }
        let widths: [CGFloat] = [420, 300, 520, 260, 470, 380, 210, 500, 330]
        for (i, w) in widths.enumerated() {
            ctx.setFillColor(NSColor(srgbRed: 0.84, green: 0.85, blue: 0.88, alpha: 1).cgColor)
            ctx.fill(CGRect(x: window.minX + 40 + (i % 3 == 1 ? 24 : 0), y: window.minY + 60 + CGFloat(i) * 36, width: w, height: 12))
        }
        let items = [
            Annotation(shape: .ellipse(CGPoint(x: 150, y: 152), CGPoint(x: 600, y: 210)), color: PenColor.red.rgba, width: 5),
            Annotation(shape: .arrow(CGPoint(x: 820, y: 420), CGPoint(x: 640, y: 330)), color: PenColor.red.rgba, width: 5),
            Annotation(shape: .line(CGPoint(x: 160, y: 340), CGPoint(x: 560, y: 340)), color: PenColor.yellow.rgba,
                       width: Annotation.strokeWidth(pen: 5, highlighter: true), highlighter: true),
            Annotation(shape: .rectangle(CGPoint(x: 150, y: 380), CGPoint(x: 400, y: 420)), color: PenColor.blue.rgba, width: 4),
            Annotation(shape: .pen([CGPoint(x: 420, y: 398), CGPoint(x: 432, y: 412), CGPoint(x: 444, y: 424),
                                    CGPoint(x: 462, y: 398), CGPoint(x: 490, y: 364)]), color: PenColor.green.rgba, width: 6),
            Annotation(shape: .text(TextItem(text: "Fix this call", origin: CGPoint(x: 640, y: 440), fontName: "", size: 30,
                                             rightAligned: false)), color: PenColor.red.rgba, width: 1),
        ]
        AnnotationRenderer.draw(items, in: ctx, blurred: nil, canvas: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}

/// The design boards' wallpaper, filling the safe area too.
struct PreviewWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// The break card over a faded desktop.
struct BreakPreview: View {
    var body: some View {
        let model = BreakTimerModel()
        model.text = "09:42"
        model.background = NSImage(size: NSSize(width: 900, height: 560), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.13, blue: 0.36, alpha: 1),
                                NSColor(srgbRed: 0.6, green: 0.25, blue: 0.53, alpha: 1),
                                NSColor(srgbRed: 0.88, green: 0.54, blue: 0.42, alpha: 1)])?.draw(in: rect, angle: -35)
            return true
        }
        model.scaleBackground = true
        model.dim = 0.55
        return BreakTimerView(model: model)
    }
}
