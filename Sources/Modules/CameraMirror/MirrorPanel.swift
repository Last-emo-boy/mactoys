import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Transient UI state shared by the panel and the floating window.
@MainActor
@Observable
final class MirrorUIState {
    var pickerOpen = false
    /// The white flash after taking a photo.
    var flash = false
    /// The last photo saved, shown as a small "Saved" chip for a few seconds.
    var savedPhoto: URL?
    /// The pointer is over the floating window (controls are shown).
    var hovering = false
    /// Drives the drop-in animation each time the panel opens.
    var presented = false
    /// Size of the picture area, for cropping photos like the view.
    var videoSize = CGSize(width: 344, height: 258)
}

/// The panel that drops from the menu bar: key-capable glass, closes when you click elsewhere or press Esc.
@MainActor
final class MirrorDropPanel: FloatingPanel {
    weak var module: CameraMirrorModule?
    private var pinnedTop: CGFloat?

    init(module: CameraMirrorModule) {
        self.module = module
        super.init(size: CGSize(width: MirrorPanelView.width, height: 320))
        isMovable = false
        isMovableByWindowBackground = false
        hasShadow = true
        animationBehavior = .none
    }

    /// Shows the content below `anchor` (a status item button), or under the camera at the top of the screen.
    func present(below button: NSStatusBarButton?, placement: MirrorPlacement) {
        guard let module else { return }
        let host = NSHostingView(rootView: MirrorPanelView(module: module, feed: .live(module.camera))
            .fixedSize(horizontal: false, vertical: true))
        contentView = host
        let width = MirrorPanelView.width
        let height = max(160, host.fittingSize.height)
        let origin: CGPoint
        if placement == .underIcon, let button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = min(max(r.midX - width / 2, vf.minX + 8), vf.maxX - width - 8)
            pinnedTop = r.minY - 6
            origin = CGPoint(x: x, y: r.minY - 6 - height)
        } else {
            let screen = Self.cameraScreen
            let top = screen.frame.maxY - max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY) - 6
            pinnedTop = top
            origin = CGPoint(x: screen.frame.midX - width / 2, y: top - height)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// The screen with the built-in camera (the notch), else the one under the pointer.
    static var cameraScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first { $0.isBuiltIn }
            ?? NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Content height changes (picker, states) keep the top edge in place.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTop { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }

    override func keyDown(with event: NSEvent) {
        guard let module, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ", "\r": module.takePhoto()
        case "m": module.settings.value.mirrored.toggle()
        case "g": module.settings.value.showGrid.toggle()
        case "d": module.detach()
        case "+", "=": module.zoom(by: 1.25)
        case "-": module.zoom(by: 0.8)
        case "0": module.resetFraming()
        default: super.keyDown(with: event)
        }
    }
}

/// The dropped mirror: the picture, a light hint, and a toolbar (camera, mirror, grid, zoom, float, photo).
struct MirrorPanelView: View {
    static let width: CGFloat = 384
    let module: CameraMirrorModule
    let feed: MirrorFeed
    @Bindable var settings: Persisted<MirrorSettings>
    var camera: MirrorCamera
    var ui: MirrorUIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(module: CameraMirrorModule, feed: MirrorFeed) {
        self.module = module
        self.feed = feed
        self.settings = module.settings
        self.camera = module.camera
        self.ui = module.ui
    }

    private var videoHeight: CGFloat { ((Self.width - 16) / settings.value.aspect.ratio).rounded() }

    /// The toolbar only makes sense while there is a picture (not for permission or error states).
    private var showsPicture: Bool {
        switch camera.status {
        case .needsPermission, .noCamera, .failed: false
        default: true
        }
    }

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(spacing: 8) {
                stage
                    .frame(height: videoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
                if showsPicture { MirrorToolbar(module: module) }
            }
            .padding(8)
            .foregroundStyle(.white)
        }
        .frame(width: Self.width)
        .scaleEffect(ui.presented || reduceMotion ? 1 : 0.94, anchor: .top)
        .opacity(ui.presented ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.24)) { ui.presented = true }
        }
    }

    @ViewBuilder private var stage: some View {
        switch (camera.status, feed) {
        case (.needsPermission(let denied), _):
            MirrorMessage(symbol: "video.slash.fill", title: Text("Camera access needed"),
                          message: Text("Camera Mirror shows your camera only while the mirror is open. Nothing is recorded or sent anywhere."),
                          actionTitle: denied ? Text("Open System Settings") : Text("Allow Camera Access")) {
                if denied { PermissionCenter.shared.openSettings(.camera) } else { module.requestAccess() }
            }
        case (.noCamera, _):
            MirrorMessage(symbol: "web.camera", title: Text("No camera found"),
                          message: Text("Connect a camera, or bring your iPhone close to use it as a webcam."),
                          actionTitle: nil, action: nil)
        case (.failed(let message), _):
            MirrorMessage(symbol: "exclamationmark.triangle.fill", title: Text("The camera didn’t start"),
                          message: Text(verbatim: message), actionTitle: Text("Try Again")) { module.restartCamera() }
        default:
            MirrorStage(module: module, feed: feed)
        }
    }
}

/// The picture with its overlays: light hint, zoom badge, camera picker, flash and the saved chip.
/// Drag to move the framing when zoomed in; pinch or scroll to zoom.
struct MirrorStage: View {
    let module: CameraMirrorModule
    let feed: MirrorFeed
    var compact = false
    @Bindable var settings: Persisted<MirrorSettings>
    var camera: MirrorCamera
    var ui: MirrorUIState
    @State private var dragStart: MirrorFraming?
    @State private var pinchStart: MirrorFraming?

    init(module: CameraMirrorModule, feed: MirrorFeed, compact: Bool = false) {
        self.module = module
        self.feed = feed
        self.compact = compact
        self.settings = module.settings
        self.camera = module.camera
        self.ui = module.ui
    }

    private var sourceSize: CGSize {
        if case .live(let c) = feed { return c.sourceSize }
        return SamplePortrait.sourceSize
    }

    var body: some View {
        GeometryReader { geo in
            let s = settings.value
            ZStack {
                MirrorVideo(feed: feed, framing: s.framing, mirrored: s.mirrored, showGrid: s.showGrid)
                    .overlay {
                        if camera.status == .starting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(panGesture(view: geo.size))
                    .simultaneousGesture(pinchGesture(view: geo.size))
                if ui.flash { Color.white.transition(.opacity) }
                if !compact { overlays(s) }
            }
            .onAppear { ui.videoSize = geo.size }
            .onChange(of: geo.size) { _, new in ui.videoSize = new }
        }
    }

    @ViewBuilder private func overlays(_ s: MirrorSettings) -> some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if s.lightCheck && camera.status != .starting && !ui.pickerOpen { LightChip(hint: camera.hint) }
                Spacer()
                if s.zoom > 1.01 {
                    Button { module.resetFraming() } label: {
                        Text(verbatim: s.zoom.formatted(.number.precision(.fractionLength(0...1))) + "×")
                    }
                    .buttonStyle(MirrorChipStyle())
                    .help("Zoom; click to show the whole picture")
                }
            }
            Spacer()
            if let saved = ui.savedPhoto {
                SavedChip(url: saved)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(10)
        .overlay(alignment: .bottomLeading) {
            if ui.pickerOpen {
                CameraPicker(module: module)
                    .padding(8)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
    }

    private func panGesture(view: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                guard settings.value.zoom > 1.01 else { return }
                let start = dragStart ?? settings.value.framing
                dragStart = start
                let next = start.panned(by: g.translation, source: sourceSize, view: view, mirrored: settings.value.mirrored)
                settings.value.setFraming(next)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func pinchGesture(view: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let start = pinchStart ?? settings.value.framing
                pinchStart = start
                settings.value.setFraming(start.zoomed(by: g.magnification, source: sourceSize, view: view))
            }
            .onEnded { _ in pinchStart = nil }
    }
}

/// Icon buttons under the picture.
private struct MirrorToolbar: View {
    let module: CameraMirrorModule
    @Bindable var settings: Persisted<MirrorSettings>
    var camera: MirrorCamera
    var ui: MirrorUIState

    init(module: CameraMirrorModule) {
        self.module = module
        self.settings = module.settings
        self.camera = module.camera
        self.ui = module.ui
    }

    var body: some View {
        let running = camera.status == .running || camera.status == .starting
        HStack(spacing: 5) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { ui.pickerOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: camera.activeDevice?.symbol ?? "web.camera")
                    Text(verbatim: camera.activeDevice?.name ?? String(localized: "Camera", comment: "Camera picker button when no camera is active"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(ui.pickerOpen ? 0.18 : 0.08)))
            }
            .buttonStyle(.plain)
            .disabled(camera.devices.count < 1)
            .help("Choose a camera")
            .layoutPriority(1)
            Spacer(minLength: 0)
            ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: settings.value.mirrored,
                       help: Text("Mirror the picture (M)")) { settings.value.mirrored.toggle() }
            ToolButton(symbol: "squareshape.split.3x3", on: settings.value.showGrid, help: Text("Show a grid (G)")) {
                settings.value.showGrid.toggle()
            }
            ToolButton(symbol: settings.value.zoom > 1.01 ? "minus.magnifyingglass" : "plus.magnifyingglass",
                       on: settings.value.zoom > 1.01, help: Text("Zoom in on the center (+ and −)")) {
                module.cycleZoom()
            }
            ToolButton(symbol: "pip.exit", on: false, help: Text("Float in a window (D)")) { module.detach() }
            ShutterButton { module.takePhoto() }
                .disabled(!running || camera.status == .starting)
                .help(Text("Take a photo (Space)"))
        }
        .disabled(!running && camera.status != .noCamera)
    }
}

struct ToolButton: View {
    let symbol: String
    let on: Bool
    let help: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The round white shutter release.
struct ShutterButton: View {
    var size: CGFloat = 30
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                Circle().fill(.white).padding(4)
            }
            .frame(width: size, height: size)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Take a photo"))
    }
}

/// The light hint in a small capsule over the picture.
struct LightChip: View {
    let hint: LightHint

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: hint.symbol).symbolRenderingMode(.hierarchical)
            Text(hint.title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(hint == .good ? Color.white : Color(red: 1, green: 0.84, blue: 0.4))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(.black.opacity(0.38)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .help(hint.advice)
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.3), value: hint)
    }
}

struct MirrorChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.black.opacity(configuration.isPressed ? 0.5 : 0.38)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

/// "Saved to Desktop · Show" after a photo.
private struct SavedChip: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved to \(url.deletingLastPathComponent().lastPathComponent)",
                     comment: "Camera Mirror: a photo was saved; the placeholder is a folder name like Desktop")
                Text("Show in Finder").foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.black.opacity(0.45)))
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The camera list that drops over the picture.
struct CameraPicker: View {
    let module: CameraMirrorModule
    var camera: MirrorCamera
    @Bindable var settings: Persisted<MirrorSettings>

    init(module: CameraMirrorModule) {
        self.module = module
        self.camera = module.camera
        self.settings = module.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Camera").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            ForEach(camera.devices) { d in
                Button { module.selectCamera(d.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: d.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(verbatim: d.name).lineLimit(1)
                        Spacer(minLength: 12)
                        if camera.activeDevice?.id == d.id {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(camera.activeDevice?.id == d.id ? Color.white.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !MirrorCamera.continuityAllowed || camera.devices.allSatisfy({ $0.kind != .continuity }) {
                Divider().opacity(0.4).padding(.vertical, 3)
                Text("An iPhone near this Mac, signed in to the same Apple Account, appears here as a camera.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11).opacity(0.94)))
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}

/// A state the mirror can be in instead of showing the picture.
struct MirrorMessage: View {
    let symbol: String
    let title: Text
    let message: Text
    let actionTitle: Text?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tint.mint.color)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Tint.mint.color.opacity(0.14)))
            title.font(.system(size: 15, weight: .semibold))
            message.font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
            if let actionTitle, let action {
                Button(action: action) { actionTitle }
                    .buttonStyle(MirrorProminentStyle())
                    .focusEffectDisabled()
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
    }
}

/// A filled mint capsule for the one action of a state screen.
struct MirrorProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(Tint.mint.color.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}
