import AppKit
import CoreGraphics
import MacToysCore
import ScreenCaptureKit

/// Still captures for Screenshot, through ScreenCaptureKit. Unlike Core's `ScreenCapture`, it can
/// leave Finder's desktop icons out and keeps MacToys' normal windows (Settings, pins) in the shot
/// while its overlays (selection, Quick Access cards, HUDs) stay out.
enum Capturer {
    struct Options: Sendable {
        var hideDesktopIcons = false
        var includePointer = false
    }

    /// A display, or a rect of it in its points (top-left origin). Returns the image and its pixels per point.
    static func display(_ screen: NSScreen, rect: CGRect? = nil, options: Options) async throws -> (CGImage, CGFloat) {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.notFound }
        let filter = SCContentFilter(display: display, excludingWindows: excluded(content.windows, options: options))
        let scale = CGFloat(filter.pointPixelScale)
        let full = CGRect(origin: .zero, size: screen.frame.size)
        let area = (rect ?? full).intersection(full)
        guard area.width >= 1, area.height >= 1 else { throw CaptureError.notFound }
        let px = AreaGeometry.pixelRect(area, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
        config.width = Int(px.width)
        config.height = Int(px.height)
        config.showsCursor = options.includePointer
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// One window without its shadow (transparent rounded corners), at the display's scale.
    static func window(_ id: CGWindowID, options: Options) async throws -> (CGImage, CGFloat) {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((window.frame.width * scale).rounded()))
        config.height = max(2, Int((window.frame.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.showsCursor = options.includePointer
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Windows a display capture leaves out: MacToys' overlays, and the desktop icons when asked.
    private static func excluded(_ windows: [SCWindow], options: Options) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let overlayLevel = NSWindow.Level.statusBar.rawValue
        return windows.filter { w in
            let app = w.owningApplication
            if app?.processID == pid && w.windowLayer >= overlayLevel { return true }
            if options.hideDesktopIcons && app?.bundleIdentifier == "com.apple.finder" && w.windowLayer == iconLevel { return true }
            return false
        }
    }
}

/// Puts a captured window on a transparent canvas, with a window-style shadow and optional padding.
enum WindowFramer {
    /// Room the shadow needs around the window, in points.
    static let shadowMargin: CGFloat = 56

    /// The canvas and where the window sits on it, in points.
    static func layout(window size: CGSize, shadow: Bool, padding: CGFloat) -> (canvas: CGSize, window: CGRect) {
        let margin = max(0, padding) + (shadow ? shadowMargin : 0)
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        return (canvas, CGRect(x: margin, y: margin, width: size.width, height: size.height))
    }

    /// The framed window, or the image itself when there is nothing to add.
    static func compose(_ image: CGImage, scale: CGFloat, shadow: Bool, padding: CGFloat) -> CGImage? {
        guard shadow || padding > 0 else { return image }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let layout = layout(window: size, shadow: shadow, padding: padding)
        let px = AreaGeometry.pixelRect(CGRect(origin: .zero, size: layout.canvas), scale: scale)
        guard let ctx = RenderContext.make(width: Int(px.width), height: Int(px.height), scale: scale) else { return nil }
        if shadow {
            // A wide soft shadow around a tight contact shadow, like the window server draws.
            // Nested layers draw the window once, so its antialiased corners don't darken.
            ctx.setShadow(offset: CGSize(width: 0, height: -20 * scale), blur: 46 * scale,
                          color: NSColor.black.withAlphaComponent(0.42).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 3 * scale,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            RenderContext.drawUpright(image, in: layout.window, ctx: ctx)
            ctx.endTransparencyLayer()
            ctx.endTransparencyLayer()
        } else {
            RenderContext.drawUpright(image, in: layout.window, ctx: ctx)
        }
        return ctx.makeImage()
    }
}
