import AppKit
import CoreImage
import MacToysCore
import Observation
import SwiftUI

@MainActor
@Observable
final class BreakTimerModel {
    var text = "10:00"
    var expired = false
    var position: TimerPosition = .center
    var background: NSImage?
    var scaleBackground = false
    /// Darkens the background (plain dark screen, or a faded desktop).
    var dim: Double = 1
}

/// Design 06 break card on a full-screen backdrop.
struct BreakTimerView: View {
    let model: BreakTimerModel

    var body: some View {
        ZStack {
            backdrop
            card
                .padding(64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var backdrop: some View {
        ZStack {
            Color.black
            if let image = model.background {
                if model.scaleBackground {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: image)
                }
            }
            Color.black.opacity(model.background == nil ? 0 : 1 - model.dim)
        }
        .clipped()
    }

    private var card: some View {
        VStack(spacing: 6) {
            Text(model.expired ? "Break over" : "Break")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .kerning(0.3)
            Text(model.text)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(model.expired ? Color(red: 1, green: 0.42, blue: 0.38) : .white)
                .contentTransition(.numericText())
            Text("↑ ↓ adjust · H hide · Esc to end")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 22)
        .frame(minWidth: 300)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }

    private var alignment: Alignment {
        switch model.position {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .left: .leading
        case .center: .center
        case .right: .trailing
        case .bottomLeft: .bottomLeading
        case .bottom: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

/// Receives the timer's keys and scroll.
final class BreakTimerEventView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        if abs(dy) >= 1 { onScroll?(dy) }
    }
}

/// The break timer: a full-screen countdown that keeps running while hidden.
@MainActor
final class BreakTimerController {
    let model = BreakTimerModel()
    var onEnd: (() -> Void)?

    private let settings: ZoomItSettings
    private var clock: BreakClock
    private var panel: OverlayPanel?
    private var timer: Timer?
    private var played = false
    private var ended = false
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(settings: ZoomItSettings) {
        self.settings = settings
        self.clock = BreakClock(start: Date(), minutes: settings.breakMinutes)
        model.position = settings.timerPosition
        model.scaleBackground = settings.scaleBackgroundImage
        update()
    }

    func start() {
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        let p = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .screenSaver)
        let root = BreakTimerEventView(frame: CGRect(origin: .zero, size: screen.frame.size))
        root.onKey = { [weak self] in self?.key($0) ?? false }
        root.onScroll = { [weak self] dy in self?.adjust(dy > 0 ? 1 : -1) }
        let host = NSHostingView(rootView: BreakTimerView(model: model))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        p.contentView = root
        p.alphaValue = CGFloat(min(1, max(0.1, settings.timerOpacity)))
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        loadBackground(for: screen)
        show()
    }

    /// Brings the timer back after H (the shortcut does this too).
    func show() {
        guard let panel, !ended else { return }
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        panel.present()
        panel.makeFirstResponder(panel.contentView)
    }

    /// Hides without stopping the countdown.
    func hide() {
        panel?.orderOut(nil)
        restoreFocus()
    }

    func stop() {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        restoreFocus()
        onEnd?()
        onEnd = nil
    }

    private func restoreFocus() {
        if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        previousApp = nil
    }

    private func key(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 53: stop()                                                   // esc
        case 126: adjust(1)                                               // ↑
        case 125: adjust(-1)                                              // ↓
        case 4: hide()                                                    // H
        default: return false
        }
        return true
    }

    private func adjust(_ minutes: Int) {
        let wasExpired = clock.isExpired(at: Date())
        clock.adjust(minutes: minutes, at: Date())
        if wasExpired && !clock.isExpired(at: Date()) { played = false }
        update()
    }

    private func update() {
        let remaining = clock.remaining(at: Date())
        let shown = BreakTimerFormat.display(remaining: remaining, showElapsed: settings.showElapsedAfterExpiry)
        if model.text != shown.text { model.text = shown.text }
        if model.expired != shown.expired { model.expired = shown.expired }
        if shown.expired, !played {
            played = true
            if settings.playSoundOnExpiry { playSound() }
        }
    }

    private func playSound() {
        let name = settings.expirySound
        let sound = name.hasPrefix("/") ? NSSound(contentsOf: URL(fileURLWithPath: name), byReference: true)
                                        : NSSound(named: NSSound.Name(name))
        (sound ?? NSSound(named: "Glass"))?.play()
    }

    private func loadBackground(for screen: NSScreen) {
        switch settings.breakBackground {
        case .none:
            model.background = nil
        case .image:
            let path = (settings.backgroundImagePath as NSString).expandingTildeInPath
            model.background = path.isEmpty ? nil : NSImage(contentsOfFile: path)
            model.dim = 0.85
        case .fadedDesktop, .blurredDesktop:
            guard CGPreflightScreenCaptureAccess() else { return }
            let blur = settings.breakBackground == .blurredDesktop
            model.dim = blur ? 0.7 : 0.45
            Task { @MainActor [weak self] in
                guard let image = try? await ScreenCapture.image(of: screen) else { return }
                let final = blur ? Self.blurred(image) ?? image : image
                self?.model.background = NSImage(cgImage: final, size: screen.frame.size)
            }
        }
    }

    nonisolated static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(Double(image.width) / 80, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: nil).createCGImage(out, from: input.extent)
    }
}
