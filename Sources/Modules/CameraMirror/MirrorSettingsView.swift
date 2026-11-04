import AppKit
import AVFoundation
import MacToysCore
import SwiftUI

struct MirrorSettingsView: View {
    let module: CameraMirrorModule
    @Bindable var s: Persisted<MirrorSettings>
    var camera: MirrorCamera

    init(module: CameraMirrorModule) {
        self.module = module
        self.s = module.settings
        self.camera = module.camera
    }

    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    var body: some View {
        SettingsPage(module: module) {
            MirrorHero(module: module)
        } content: {
            Section("Opening the mirror") {
                Toggle(isOn: $s.value.showMenuBarIcon) {
                    RowLabel("Show in the menu bar", subtitle: "Click the camera icon to open the mirror; right-click for more.")
                }
                ShortcutRow("Show or hide the mirror", subtitle: "Also from the MacToys menu and the Command Palette.",
                            shortcut: $s.value.activation)
                Picker(selection: $s.value.placement) {
                    ForEach(MirrorPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("The mirror opens", subtitle: "Under the camera puts it right where you look on a laptop.")
                }
                Toggle(isOn: $s.value.openFromNotch) {
                    RowLabel(title: Text("Click the notch to open the mirror"),
                             subtitle: hasNotch ? Text("Clicking the empty menu bar in front of the camera opens the mirror under it.")
                                                : Text("Only on Macs whose display has a notch."))
                }
                .disabled(!hasNotch)
            }

            Section("Picture") {
                Picker(selection: $s.value.cameraID) {
                    Text("Automatic", comment: "Camera choice: the camera macOS prefers").tag(String?.none)
                    if !camera.devices.isEmpty { Divider() }
                    ForEach(camera.devices) { d in
                        Label { Text(verbatim: d.name) } icon: { Image(systemName: d.symbol) }.tag(Optional(d.id))
                    }
                } label: {
                    RowLabel("Camera", subtitle: "Automatic follows the camera macOS picks, such as an iPhone you bring close.")
                }
                Toggle(isOn: $s.value.mirrored) {
                    RowLabel("Mirror the picture", subtitle: "Like a mirror: raise your right hand and it moves on the right. Others in a call see you unmirrored.")
                }
                FramingEditor(settings: s)
                Toggle(isOn: $s.value.lightCheck) {
                    RowLabel("Check the light", subtitle: "Says when your face is too dark, too bright or lit from behind.")
                }
                Toggle(isOn: $s.value.showGrid) {
                    RowLabel("Show a grid", subtitle: "Rule-of-thirds lines to line up your eyes and the camera.")
                }
            }

            Section("Floating window") {
                Picker(selection: $s.value.shape) {
                    ForEach(MirrorShape.allCases, id: \.self) { shape in
                        Label(shape.title, systemImage: shape.symbol).tag(shape)
                    }
                } label: {
                    RowLabel("Shape", subtitle: "Click the float button in the mirror or press D. Double-click the window to put it back.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $s.value.aspect) {
                    ForEach(MirrorAspect.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                } label: {
                    RowLabel("Proportions", subtitle: "Of the menu bar mirror and of rounded and rectangular windows. A circle is always round.")
                }
                .pickerStyle(.segmented)
                SliderRow("Opacity", value: $s.value.opacity, in: 0.25...1, step: 0.05,
                          format: { $0.formatted(.percent.precision(.fractionLength(0))) })
                Toggle(isOn: $s.value.floatOnTop) {
                    RowLabel("Keep on top of other windows")
                }
                LabeledContent {
                    Button("Reset Size and Position") { s.value.floatingFrame = nil }
                        .disabled(s.value.floatingFrame == nil)
                } label: {
                    RowLabel("Size and position", subtitle: "Drag the window anywhere; drag its corner grip to resize it.")
                }
            }

            Section("Photos") {
                Picker(selection: $s.value.photoFolder) {
                    ForEach(PhotoFolder.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Save photos to", subtitle: "Photos keep the mirror’s zoom and framing, at the camera’s full resolution.")
                }
                Toggle(isOn: $s.value.photoMirrored) {
                    RowLabel("Save photos mirrored", subtitle: "Off saves them as others see you, so text reads the right way.")
                }
                Toggle(isOn: $s.value.shutterSound) {
                    RowLabel("Play the shutter sound")
                }
            }

            Section("Keys in the mirror") {
                MirrorKeyRow(title: Text("Take a photo"), keys: [String(localized: "Space", comment: "Key name: space bar")])
                MirrorKeyRow(title: Text("Mirror the picture"), keys: ["M"])
                MirrorKeyRow(title: Text("Show or hide the grid"), keys: ["G"])
                MirrorKeyRow(title: Text("Zoom in or out"), keys: ["+", "−"])
                MirrorKeyRow(title: Text("Show the whole picture"), keys: ["0"])
                MirrorKeyRow(title: Text("Float in a window"), keys: ["D"])
                MirrorKeyRow(title: Text("Close the mirror"), keys: ["esc"])
                Text("When zoomed in, drag the picture to frame your face, or pinch on the trackpad. The camera turns on only while a mirror is open, and nothing leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { camera.refreshDevices() }
    }
}

private struct MirrorKeyRow: View {
    let title: Text
    let keys: [String]

    var body: some View {
        LabeledContent { Keycaps(keys) } label: { title }
    }
}

/// Zoom slider plus the whole camera picture with the part the mirror shows; drag the frame to move it.
private struct FramingEditor: View {
    @Bindable var settings: Persisted<MirrorSettings>
    @State private var dragStart: MirrorFraming?

    private let boxWidth: CGFloat = 224
    private var boxSize: CGSize { CGSize(width: boxWidth, height: boxWidth * 9 / 16) }
    /// The menu bar mirror's picture area (its proportions decide the frame's shape).
    private var viewSize: CGSize { CGSize(width: 344, height: 344 / settings.value.aspect.ratio) }

    var body: some View {
        let s = settings.value
        let source = SamplePortrait.sourceSize
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                RowLabel("Framing", subtitle: "Zoom in to fill the mirror with your face, then drag the frame where your face is. Saved for every mirror and photo.")
                Spacer(minLength: 8)
                ZStack(alignment: .topLeading) {
                    SamplePortrait()
                        .scaleEffect(x: s.mirrored ? -1 : 1, y: 1)
                        .frame(width: boxSize.width, height: boxSize.height)
                    let v = s.framing.visibleRect(source: source, view: viewSize)
                    let x = (s.mirrored ? 1 - v.maxX : v.minX) * boxSize.width
                    let r = CGRect(x: x, y: v.minY * boxSize.height, width: v.width * boxSize.width, height: v.height * boxSize.height)
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: boxSize))
                        p.addRoundedRect(in: r, cornerSize: CGSize(width: 5, height: 5))
                    }
                    .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white, lineWidth: 2)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                .frame(width: boxSize.width, height: boxSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let start = dragStart ?? s.framing
                    dragStart = start
                    // Dragging the frame moves the center the opposite way of panning the picture.
                    let delta = CGSize(width: -g.translation.width * viewSize.width / (boxSize.width * start.visibleRect(source: source, view: viewSize).width),
                                       height: -g.translation.height * viewSize.height / (boxSize.height * start.visibleRect(source: source, view: viewSize).height))
                    settings.value.setFraming(start.panned(by: delta, source: source, view: viewSize, mirrored: s.mirrored))
                }.onEnded { _ in dragStart = nil })
                .accessibilityLabel(Text("Framing"))
                .accessibilityHint(Text("Drag to move the part of the picture the mirror shows"))
            }
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { s.zoom }, set: { z in
                    settings.value.setFraming(MirrorFraming(zoom: z, center: s.framing.center).clamped(source: source, view: viewSize))
                }), in: 1...3)
                .labelsHidden()
                .accessibilityLabel(Text("Zoom"))
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Text(verbatim: s.zoom.formatted(.number.precision(.fractionLength(1))) + "×")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
                Button("Reset") {
                    settings.value.setFraming(MirrorFraming(zoom: 1, center: CGPoint(x: 0.5, y: 0.45)))
                }
                .disabled(s.zoom <= 1.001)
            }
        }
    }
}

/// The hero: a miniature screen with the mirror dropping from the menu bar and a floating
/// mirror in the chosen shape, drawn from the current settings.
private struct MirrorHero: View {
    let module: CameraMirrorModule
    var settings: Persisted<MirrorSettings>

    init(module: CameraMirrorModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        HeroCard(tint: .mint) {
            HStack(alignment: .center, spacing: 20) {
                MirrorMiniScreen(settings: settings.value)
                    .frame(width: 280, height: 170)
                VStack(alignment: .leading, spacing: 8) {
                    Text("See yourself before the call starts").font(.system(size: 14, weight: .semibold))
                    Text("Click the camera in the menu bar, or use the shortcut. The camera turns on only while the mirror is open and stops when you close it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Show Mirror") { module.showPanel() }
                            .buttonStyle(.borderedProminent)
                            .tint(Tint.mint.color)
                        Button("Float") { module.detach() }
                        if let shortcut = settings.value.activation { Keycaps(shortcut) }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A tiny desktop: menu bar with the camera icon, the dropped mirror under it, a floating mirror.
struct MirrorMiniScreen: View {
    let settings: MirrorSettings

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Menu bar.
                HStack(spacing: 6) {
                    Capsule().fill(.white.opacity(0.7)).frame(width: 14, height: 3)
                    Capsule().fill(.white.opacity(0.45)).frame(width: 22, height: 3)
                    Spacer()
                    Image(systemName: "web.camera").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 11)
                        .background(Capsule().fill(.white.opacity(0.25)))
                    Capsule().fill(.white.opacity(0.45)).frame(width: 10, height: 3)
                    Capsule().fill(.white.opacity(0.7)).frame(width: 26, height: 3)
                }
                .padding(.horizontal, 8)
                .frame(width: w, height: 13)
                .background(.black.opacity(0.25))
                // The dropped mirror.
                let pw: CGFloat = 132, ph = (pw - 8) / settings.aspect.ratio
                VStack(spacing: 4) {
                    MirrorVideo(feed: .sample(.good), framing: settings.framing, mirrored: settings.mirrored, showGrid: settings.showGrid)
                        .frame(width: pw - 8, height: ph)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    HStack(spacing: 3) {
                        Capsule().fill(.white.opacity(0.18)).frame(width: 36, height: 8)
                        Spacer()
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.18)).frame(width: 8, height: 8) }
                        Circle().fill(.white).frame(width: 8, height: 8)
                    }
                }
                .padding(4)
                .frame(width: pw)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.12).opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .offset(x: w - pw - 22, y: 18)
                // The floating mirror.
                let ratio = FloatingGeometry.ratio(shape: settings.shape, aspect: settings.aspect)
                let fw: CGFloat = ratio >= 1 ? 74 * min(ratio, 1.5) : 64, fh = fw / ratio
                MirrorVideo(feed: .sample(.good), framing: settings.framing, mirrored: settings.mirrored)
                    .frame(width: fw, height: fh)
                    .clipShape(MirrorOutline(shape: settings.shape, size: CGSize(width: fw, height: fh)))
                    .overlay(MirrorOutline(shape: settings.shape, size: CGSize(width: fw, height: fh)).stroke(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                    .opacity(settings.opacity)
                    .offset(x: 18, y: h - fh - 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
        .animation(.smooth(duration: 0.25), value: settings)
        .accessibilityHidden(true)
    }
}
