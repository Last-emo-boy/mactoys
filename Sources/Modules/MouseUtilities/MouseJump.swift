import AppKit
import Carbon.HIToolbox
import CoreImage
import MacToysCore
import Observation
import SwiftUI
import VideoToolbox

/// Everything the Mouse Jump popup shows.
@MainActor
@Observable
final class MouseJumpModel {
    struct Display: Identifiable {
        let id: Int
        let frame: CGRect
        let displayID: CGDirectDisplayID
        /// 1-based, left to right then top to bottom.
        let number: Int
        let isPrimary: Bool
        let name: String
    }

    let layout: JumpLayout
    let displays: [Display]
    let settings: MouseJumpSettings
    let metrics: JumpLayout.Metrics
    var thumbnails: [Int: CGImage] = [:]
    var wallpapers: [Int: NSImage] = [:]
    /// The pointer, in preview coordinates.
    var pointer: CGPoint?
    var hovered: Int?
    @ObservationIgnored var onJump: ((CGPoint, _ close: Bool) -> Void)?

    init(frames: [(frame: CGRect, displayID: CGDirectDisplayID, name: String)], primary: Int, pointer: CGPoint,
         settings: MouseJumpSettings, maxSize: CGSize) {
        self.settings = settings
        metrics = Self.metrics(for: settings)
        layout = JumpLayout(displays: frames.map(\.frame), maxSize: maxSize, metrics: metrics)
        let order = frames.indices.sorted { a, b in
            let fa = frames[a].frame, fb = frames[b].frame
            return fa.minX != fb.minX ? fa.minX < fb.minX : fa.minY < fb.minY
        }
        displays = frames.indices.map { i in
            Display(id: i, frame: frames[i].frame, displayID: frames[i].displayID,
                    number: (order.firstIndex(of: i) ?? i) + 1, isPrimary: i == primary, name: frames[i].name)
        }
        self.pointer = layout.previewPoint(for: pointer)
    }

    static func metrics(for s: MouseJumpSettings) -> JumpLayout.Metrics {
        switch s.style {
        case .compact: JumpLayout.Metrics(padding: 6, margin: 2, bezel: 0)
        case .bezelled: JumpLayout.Metrics(padding: 12, margin: 12, bezel: 5)
        case .custom: JumpLayout.Metrics(padding: 12, margin: CGFloat(s.customMargin), bezel: CGFloat(s.customBezel))
        }
    }

    /// Displays in numbering order.
    var ordered: [Display] { displays.sorted { $0.number < $1.number } }

    func click(_ p: CGPoint) {
        guard let g = layout.globalPoint(for: p) else { return }
        onJump?(g, true)
    }

    func hover(_ p: CGPoint?) {
        hovered = p.flatMap(layout.index(at:))
    }

    /// Center of a display, for keyboard selection.
    func center(of display: Display) -> CGPoint { CGPoint(x: display.frame.midX, y: display.frame.midY) }

    func movePointer(to g: CGPoint) { pointer = layout.previewPoint(for: g) }

    /// Keyboard: 1–9 pick a display, ←/→ cycle, Home/End first/last, P primary, ↩/esc close.
    /// Returns false for keys it doesn't use.
    func key(_ code: Int, current: CGPoint) -> Bool {
        let list = ordered
        guard !list.isEmpty else { return false }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if let n = digits.firstIndex(of: code) ?? keypad.firstIndex(of: code) {
            guard n < list.count else { return true }
            onJump?(center(of: list[n]), true)
            return true
        }
        let currentIndex = list.firstIndex { $0.frame.contains(current) } ?? 0
        switch code {
        case kVK_LeftArrow, kVK_RightArrow:
            let step = code == kVK_LeftArrow ? -1 : 1
            let next = list[(currentIndex + step + list.count) % list.count]
            onJump?(center(of: next), false)
        case kVK_Home:
            onJump?(center(of: list[0]), true)
        case kVK_End:
            onJump?(center(of: list[list.count - 1]), true)
        case kVK_ANSI_P:
            if let primary = list.first(where: \.isPrimary) { onJump?(center(of: primary), true) }
        default:
            return false
        }
        return true
    }
}

/// The popup window; it takes keyboard focus and closes when it loses it.
final class MouseJumpPanel: OverlayPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onClose?()
            return
        }
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }
}

/// Mouse Jump: a preview of all displays; click a spot (or press a display's number) to move
/// the pointer there.
@MainActor
final class MouseJump {
    static let hotkeyID = "mouseutils.jump"

    private(set) var settings: MouseJumpSettings
    private var running = false
    private var panel: MouseJumpPanel?
    private var model: MouseJumpModel?
    private var captures: [LiveCapture] = []
    private var previousApp: NSRunningApplication?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let log = Log.for("mouseutils")

    init(settings: MouseJumpSettings) { self.settings = settings }

    var isOpen: Bool { panel != nil }

    func update(_ s: MouseJumpSettings) {
        let shortcutChanged = s.shortcut != settings.shortcut
        settings = s
        if running && shortcutChanged { registerHotkey() }
    }

    func start() {
        guard !running else { return }
        running = true
        registerHotkey()
    }

    func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        close()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.shortcut) { [weak self] in self?.toggle() }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard panel == nil else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let pointer = MouseSynth.location
        let current = ScreenGeometry.screen(containingAX: pointer) ?? screens[0]
        let visible = current.visibleFrame
        let maxSize = CGSize(width: min(CGFloat(max(settings.maxWidth, 160)), visible.width * 0.7),
                             height: min(CGFloat(max(settings.maxHeight, 120)), visible.height * 0.7))
        let model = MouseJumpModel(
            frames: screens.map { ($0.axFrame, $0.displayID, $0.localizedName) }, primary: 0, pointer: pointer,
            settings: settings, maxSize: maxSize)
        model.onJump = { [weak self] point, close in self?.jump(to: point, close: close) }
        self.model = model

        let size = model.layout.size
        let cocoaPointer = ScreenGeometry.toCocoa(pointer)
        var origin = CGPoint(x: cocoaPointer.x - size.width / 2, y: cocoaPointer.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let panel = MouseJumpPanel(frame: CGRect(origin: origin, size: size), interactive: true, acceptsKey: true,
                                   level: .popUpMenu)
        panel.setContent(MouseJumpView(model: model))
        panel.onKey = { [weak model] event in
            model?.key(Int(event.keyCode), current: MouseSynth.location) ?? false
        }
        panel.onClose = { [weak self] in self?.close() }
        previousApp = NSWorkspace.shared.frontmostApplication
        self.panel = panel
        panel.present()
        loadImages(for: model, screens: screens)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onClose = nil
        panel.orderOut(nil)
        for c in captures { c.stop() }
        captures = []
        model = nil
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp.activate() }
        previousApp = nil
    }

    private func jump(to point: CGPoint, close shouldClose: Bool) {
        MouseSynth.warp(to: point)
        MouseSynth.move(to: point)
        model?.movePointer(to: point)
        if shouldClose { close() }
    }

    // MARK: - Thumbnails

    private func loadImages(for model: MouseJumpModel, screens: [NSScreen]) {
        // Desktop pictures first (no permission needed); live frames replace them when allowed.
        for (i, screen) in screens.enumerated() {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            Task.detached(priority: .userInitiated) {
                guard let image = NSImage(contentsOf: url) else { return }
                await MainActor.run { [weak model] in model?.wallpapers[i] = image }
            }
        }
        guard settings.liveThumbnails, CGPreflightScreenCaptureAccess() else { return }
        for (i, screen) in screens.enumerated() {
            let capture = LiveCapture()
            let imageWidth = model.layout.images[i].width
            let scale = min(max(imageWidth * 2 / max(screen.frame.width, 1), 0.1), 2)
            capture.onFrame = { [weak self, weak model] buffer in
                guard let self, let model else { return }
                if let image = self.cgImage(buffer) { model.thumbnails[i] = image }
            }
            captures.append(capture)
            Task { [log] in
                do { try await capture.start(.display(screen.displayID), fps: 8, scale: scale) }
                catch { log.error("Mouse Jump capture failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        if let image { return image }
        return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0,
                                                                                 width: CVPixelBufferGetWidth(buffer),
                                                                                 height: CVPixelBufferGetHeight(buffer)))
    }
}

/// The glass preview: every display in its real arrangement, numbered, with the pointer.
struct MouseJumpView: View {
    let model: MouseJumpModel

    var body: some View {
        let s = model.settings
        let size = model.layout.size
        let content = canvas
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { model.click($0.location) })
            .onContinuousHover { phase in
                if case .active(let p) = phase { model.hover(p) } else { model.hover(nil) }
            }
        switch s.style {
        case .custom:
            content
                .background(s.customBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(s.customCornerRadius) + 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CGFloat(s.customCornerRadius) + 6, style: .continuous)
                    .strokeBorder(s.customBorderColor.color, lineWidth: CGFloat(s.customBorderWidth)))
                .environment(\.colorScheme, .dark)
        case .compact:
            GlassPanel(cornerRadius: 10) { content }
        case .bezelled:
            GlassPanel(cornerRadius: 18) { content }
        }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.displays) { d in
                thumbnail(d)
            }
            if let p = model.pointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
                    .position(x: p.x + 4, y: p.y + 7)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func thumbnail(_ d: MouseJumpModel.Display) -> some View {
        let s = model.settings
        let slot = model.layout.slots[d.id]
        let image = model.layout.images[d.id]
        let bezelRadius: CGFloat = s.style == .compact ? 3 : (s.style == .custom ? CGFloat(s.customCornerRadius) : 9)
        let hovered = model.hovered == d.id
        ZStack {
            if s.style != .compact {
                RoundedRectangle(cornerRadius: bezelRadius, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: bezelRadius, style: .continuous)
                        .strokeBorder(s.style == .custom ? s.customBorderColor.color : Color.white.opacity(0.12), lineWidth: 1))
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
            }
            screenImage(d)
                .frame(width: image.width, height: image.height)
                .clipShape(RoundedRectangle(cornerRadius: max(bezelRadius - 4, 2), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: max(bezelRadius - 4, 2), style: .continuous)
                    .strokeBorder(hovered ? Color.accentColor : Color.clear, lineWidth: 2))
                .position(x: image.midX, y: image.midY)
            Text("\(d.number)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.65)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                .position(x: image.minX + 16, y: image.minY + 16)
        }
    }

    @ViewBuilder private func screenImage(_ d: MouseJumpModel.Display) -> some View {
        if let cg = model.thumbnails[d.id] {
            Image(decorative: cg, scale: 1).resizable().interpolation(.medium)
        } else if let wallpaper = model.wallpapers[d.id] {
            Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.5), Color(red: 0.45, green: 0.25, blue: 0.62),
                                    Color(red: 0.92, green: 0.56, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
