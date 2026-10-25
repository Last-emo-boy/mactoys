import AppKit
import MacToysCore
import SwiftUI

/// Color Picker: ⌃⌥C freezes the screens and shows a loupe; a click copies the color in the
/// default format and (optionally) opens the editor with history, shades and every format.
///
/// URL actions: `mactoys://colorpicker/pick`, `…/editor` (also `open`, `show`).
@MainActor
public final class ColorPickerModule: ToyModule {
    public let info = ModuleInfo(
        id: "colorpicker", name: "Color Picker",
        summary: "Pick a color from anywhere on screen and copy it in the format you need.",
        symbol: "eyedropper", tint: .pink, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["eyedropper", "hex", "rgb", "hsl", "oklch", "swiftui", "color"])

    public let settings = Persisted("colorpicker", default: ColorPickerSettings())
    let history: ColorHistory
    private lazy var editor = ColorEditorWindow(model: makeEditorModel())
    private var session: PickerSession?
    private var sampler: NSColorSampler?
    private var running = false
    private var capturing = false
    private let log = Log.for("colorpicker")
    private static let hotkeyID = "colorpicker.activate"

    public init() {
        history = ColorHistory(file: Paths.data(for: "colorpicker").appendingPathComponent("history.json"),
                               limit: settings.value.historyLimit)
        let normalized = settings.value.formats.normalized()
        if normalized != settings.value.formats { settings.value.formats = normalized }
        settings.onChange { [weak self] value in
            guard let self else { return }
            if self.history.limit != value.historyLimit { self.history.limit = value.historyLimit }
            if self.running { self.registerHotkey() }
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        session?.tearDown()
        session = nil
        editor.close()
    }

    public func settingsView() -> AnyView {
        AnyView(ColorPickerSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "colorpicker.pick", title: "Pick Color", symbol: "eyedropper", tint: .pink,
                        shortcut: settings.value.activationShortcut) { [weak self] in self?.activate() },
            QuickAction(id: "colorpicker.editor", title: "Color Editor", symbol: "paintpalette.fill", tint: .pink) { [weak self] in
                self?.openEditor()
            },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Pick a color", settings.value.activationShortcut)]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "pick": pick(fromEditor: false)
        case "editor", "open", "show": openEditor()
        case "activate": activate()
        default: return false
        }
        return true
    }

    // MARK: Actions

    /// What the activation shortcut does, per the activation behavior setting.
    func activate() {
        if settings.value.activation == .openEditor { openEditor() } else { pick(fromEditor: false) }
    }

    func openEditor(selecting color: ColorValue? = nil) {
        editor.show(selecting: color)
    }

    /// Freezes the screens and starts the loupe. Picking from the editor always returns to it.
    func pick(fromEditor: Bool) {
        guard session == nil, !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            sampleWithSystemPicker(fromEditor: fromEditor)
            return
        }
        let editorWasOpen = fromEditor || editor.isVisible
        let previousApp = NSWorkspace.shared.frontmostApplication
        if editorWasOpen { editor.hide() }
        capturing = true
        Task { @MainActor [weak self] in
            let captures = await ScreenCapture.allScreens()
            guard let self else { return }
            self.capturing = false
            guard self.running else { if editorWasOpen { self.editor.show() }; return }
            let current = self.settings.value
            let session = PickerSession(settings: current) { [weak self] outcome in
                self?.finish(outcome, fromEditor: editorWasOpen, previousApp: previousApp)
            }
            self.session = session
            if !session.begin(captures) {
                self.session = nil
                self.log.error("Color Picker could not capture any screen")
                HUD.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle")
                if editorWasOpen { self.editor.show() }
            }
        }
    }

    private func finish(_ outcome: PickerSession.Outcome, fromEditor: Bool, previousApp: NSRunningApplication?) {
        session = nil
        switch outcome {
        case .cancelled:
            if fromEditor { editor.show() } else { restore(previousApp) }
        case .picked(let color, let action):
            record(color)
            if fromEditor || action == .pickThenEditor {
                editor.show(selecting: color)
            } else {
                HUD.show("Copied \(ColorFormatter.format(color, settings.value.copyFormat.format))", symbol: "eyedropper")
                restore(previousApp)
            }
        }
    }

    /// Without Screen Recording, macOS' own sampler still lets the user pick (no loupe controls).
    private func sampleWithSystemPicker(fromEditor: Bool) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampler = nil
                guard let color else { return }
                let value = ColorValue(RGBA(color))
                self.record(value)
                if fromEditor || self.settings.value.leftClick == .pickThenEditor || self.settings.value.activation == .pickThenEditor {
                    self.editor.show(selecting: value)
                }
            }
        }
    }

    /// Copies in the default format and adds to the history.
    private func record(_ color: ColorValue) {
        copy(ColorFormatter.format(color, settings.value.copyFormat.format))
        history.add(color)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func restore(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        app.activate()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activationShortcut) { [weak self] in
            self?.activate()
        }
    }

    private func makeEditorModel() -> ColorEditorModel {
        let model = ColorEditorModel(history: history, settings: settings)
        model.onPick = { [weak self] in self?.pick(fromEditor: true) }
        model.onCopy = { [weak self] text in self?.copy(text) }
        return model
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [
            PreviewScene("picker", size: CGSize(width: 760, height: 470), wallpaper: false) {
                AnyView(PickerPreview())
            },
            PreviewScene("editor", size: CGSize(width: 580, height: 420), wallpaper: false) { [settings] in
                let history = ColorHistory(file: nil)
                history.replace(with: ["#FF5F4A", "#0A84FF", "#34C759", "#5E5CE6", "#F5B800", "#1C1C1E"]
                    .compactMap { ColorValue(hex: $0) })
                let model = ColorEditorModel(history: history, settings: settings)
                return AnyView(ColorEditorView(model: model))
            },
        ]
    }
}

/// A design-06-like page under the loupe, drawn in code so the scene needs no capture.
struct PickerPreview: View {
    private static let page: ScreenPixels? = {
        let size = CGSize(width: 760, height: 470)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let banner = CGRect(x: 30, y: 30, width: 700, height: 150)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: banner, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.clip()
        // Diagonal stripes make the magnified pixel grid readable, like the design's gradient edge.
        if let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.18, blue: 0.33, alpha: 1),
                                                                  CGColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: banner.minX, y: 0), end: CGPoint(x: banner.maxX, y: 0), options: [])
        }
        // Hard-edged diagonal stripes give the loupe distinct pixels, like the design's gradient edge.
        ctx.setShouldAntialias(false)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 95 / 255, blue: 74 / 255, alpha: 1))
        for i in stride(from: -200, to: 900, by: 8) {
            ctx.move(to: CGPoint(x: CGFloat(i), y: banner.maxY))
            ctx.addLine(to: CGPoint(x: CGFloat(i) + 150, y: banner.minY))
            ctx.addLine(to: CGPoint(x: CGFloat(i) + 154, y: banner.minY))
            ctx.addLine(to: CGPoint(x: CGFloat(i) + 4, y: banner.maxY))
            ctx.fillPath()
        }
        ctx.setShouldAntialias(true)
        ctx.restoreGState()
        let cards: [(CGFloat, CGColor)] = [(30, CGColor(srgbRed: 0.37, green: 0.36, blue: 0.9, alpha: 1)),
                                           (265, CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
                                           (500, CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))]
        for (x, color) in cards {
            ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 200, width: 230, height: 150), cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x + 14, y: 214, width: 202, height: 70), cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(CGColor(srgbRed: 0.82, green: 0.82, blue: 0.85, alpha: 1))
            ctx.fill(CGRect(x: x + 14, y: 298, width: 120, height: 7))
            ctx.fill(CGRect(x: x + 14, y: 314, width: 80, height: 7))
        }
        return ctx.makeImage().flatMap(ScreenPixels.init)
    }()

    var body: some View {
        let pixels = Self.page
        let stripe = ColorValue(red: 255, green: 95, blue: 74)
        // Center the loupe on a stripe pixel so the chip shows the design's #FF5F4A.
        let x = (590...620).first { pixels?.color(x: $0, y: 110) == stripe } ?? 600
        let point = CGPoint(x: CGFloat(x), y: 110)
        let color = pixels?.color(x: x, y: 110) ?? stripe
        ZStack(alignment: .topLeading) {
            if let pixels { Image(decorative: pixels.image, scale: 1) }
            LoupeView(patch: pixels?.patch(centerX: Int(point.x), centerY: Int(point.y), size: 13), cells: 13,
                      color: color, label: color.hex, name: nil)
                .position(point)
            ColorChip(color: color, label: color.hex, name: ColorNames.displayName(for: color))
                .position(x: point.x, y: point.y + LoupeView.diameter / 2 + 26)
        }
        .frame(width: 760, height: 470)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .ignoresSafeArea()
    }
}
