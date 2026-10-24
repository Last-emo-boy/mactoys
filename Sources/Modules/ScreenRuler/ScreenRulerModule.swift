import AppKit
import MacToysCore
import SwiftUI

/// Screen Ruler: ⌃⌥M opens a toolbar with Bounds, Spacing, Horizontal and Vertical tools that
/// measure the screen with edge detection.
///
/// URL actions: `mactoys://screenruler/open` (also `show`, `toggle`), and
/// `…/measure?tool=bounds|spacing|horizontal|vertical`.
@MainActor
public final class ScreenRulerModule: ToyModule {
    public let info = ModuleInfo(
        id: "screenruler", name: "Screen Ruler",
        summary: "Measure pixels on screen with edge detection.",
        symbol: "ruler.fill", tint: .teal, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["measure", "pixels", "distance", "spacing", "bounds"])

    public let settings = Persisted("screenruler", default: ScreenRulerSettings())
    private var session: RulerSession?
    private var running = false
    private static let hotkeyID = "screenruler.activate"

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkey()
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
        session?.end()
        session = nil
    }

    public func settingsView() -> AnyView {
        AnyView(ScreenRulerSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "screenruler.open", title: "Screen Ruler", symbol: "ruler.fill", tint: .teal,
                     shortcut: settings.value.activationShortcut) { [weak self] in self?.toggle() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Screen Ruler", settings.value.activationShortcut),
         ShortcutBinding("Ruler: pick a tool", keys: ["⌘", "1–4"]),
         ShortcutBinding("Ruler: keep a measurement", keys: ["⇧", "Click"])]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show": open(tool: settings.value.defaultMode.tool)
        case "toggle": toggle()
        case "measure": open(tool: command.parameters["tool"].flatMap(RulerTool.init(rawValue:)) ?? .spacing)
        case "close": session?.end()
        default: return false
        }
        return true
    }

    /// The shortcut: opens the toolbar, or closes it when it's already up.
    func toggle() {
        if let session { session.end() } else { open(tool: settings.value.defaultMode.tool) }
    }

    func open(tool: RulerTool?) {
        if let session {
            if let tool { session.select(tool) }
            return
        }
        let s = RulerSession(settings: settings.value) { [weak self] in self?.session = nil }
        session = s
        s.begin(tool: tool)
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activationShortcut) { [weak self] in self?.toggle() }
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [PreviewScene("toolbar", size: CGSize(width: 760, height: 470), wallpaper: false) { [settings] in
            AnyView(RulerPreview(settings: settings.value))
        }]
    }
}

/// The design 06 board: a page, the toolbar with Spacing on, and a real edge-detected measurement.
struct RulerPreview: View {
    let settings: ScreenRulerSettings

    var body: some View {
        let size = CGSize(width: 760, height: 470)
        ZStack(alignment: .top) {
            if let image = Self.render(size: size, settings: settings) {
                Image(decorative: image, scale: 2)
            }
            RulerToolbar(model: { let m = RulerToolbarModel(); m.tool = .spacing; return m }(), select: { _ in }, close: {})
                .fixedSize()
                .padding(.top, 14)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .ignoresSafeArea()
    }

    /// Draws a page at 2×, measures it with `EdgeDetector`, and draws the measurement on top.
    static func render(size: CGSize, settings: ScreenRulerSettings) -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        func fill(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat), radius: CGFloat = 0) {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        fill(CGRect(origin: .zero, size: size), (0.97, 0.97, 0.98))
        fill(CGRect(x: 40, y: 70, width: 680, height: 120), (1, 0.37, 0.29), radius: 12)
        let cards: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [(40, (0.37, 0.36, 0.9)), (270, (0.2, 0.78, 0.35)), (500, (0.04, 0.52, 1))]
        for (x, c) in cards {
            fill(CGRect(x: x, y: 214, width: 220, height: 150), (0.88, 0.88, 0.91), radius: 10)
            fill(CGRect(x: x + 14, y: 228, width: 192, height: 70), c, radius: 6)
            fill(CGRect(x: x + 14, y: 312, width: 120, height: 7), (0.82, 0.82, 0.85))
        }
        guard let page = ctx.makeImage(), let pixels = PixelBuffer(image: page) else { return nil }
        // Measure the space under the first card's image, edge to edge.
        let probe = (x: Int(200 * scale), y: Int(336 * scale))
        let rect = EdgeDetector.edges(in: pixels, x: probe.x, y: probe.y, tolerance: Int(settings.pixelTolerance),
                                      perChannel: settings.perChannelDetection)
        let gap = RulerMark(tool: .spacing, rect: rect, anchorX: probe.x, anchorY: probe.y)
        let card = PixelRect(left: Int(54 * scale), top: Int(228 * scale), right: Int(246 * scale) - 1, bottom: Int(298 * scale) - 1)
        let kept = RulerMark(tool: .bounds, rect: card, anchorX: card.right, anchorY: card.bottom)
        let style = RulerStyle(color: settings.lineColor.nsColor, drawFeet: settings.drawFeet, extraUnit: settings.extraUnit)
        let metrics = DisplayMetrics(pixelsPerPoint: Double(scale), pixelsPerInch: 254)
        RulerDrawing.draw([kept, gap], in: ctx, scale: scale, bounds: CGRect(origin: .zero, size: size), style: style,
                          metrics: metrics)
        return ctx.makeImage()
    }
}
