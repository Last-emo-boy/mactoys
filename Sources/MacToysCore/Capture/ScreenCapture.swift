import AppKit
import CoreMedia
import ScreenCaptureKit

public enum CaptureError: Error, LocalizedError {
    case notPermitted
    case notFound
    public var errorDescription: String? {
        switch self {
        case .notPermitted: "Screen Recording permission is required."
        case .notFound: "The display or window is no longer available."
        }
    }
}

/// Still captures through ScreenCaptureKit. Needs Screen Recording permission.
public enum ScreenCapture {
    /// Captures a whole display (or a sub-rect in display-local points) at native pixel scale.
    /// MacToys' own windows are excluded so overlays don't capture themselves.
    public static func image(of screen: NSScreen, rect: CGRect? = nil, includeOwnWindows: Bool = false) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.notFound }
        let own = includeOwnWindows ? [] : content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        let area = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        config.sourceRect = area
        config.width = Int(area.width * scale)
        config.height = Int(area.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures a single window by CoreGraphics id, at native scale.
    public static func image(windowID: CGWindowID, scale: CGFloat = 2) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.notFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Snapshot of every display, keyed by screen, for overlays that work on a frozen image.
    public static func allScreens() async -> [(NSScreen, CGImage)] {
        var result: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            if let img = try? await image(of: screen) { result.append((screen, img)) }
        }
        return result
    }
}

/// A live ScreenCaptureKit stream of one window or a display region, delivering frames
/// on the main thread. Used for mirrors (Always On Top, Crop And Lock) and Live Zoom.
@MainActor
public final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public enum Source {
        case window(CGWindowID)
        case display(CGDirectDisplayID)
    }

    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onStop: ((Error?) -> Void)?
    private var stream: SCStream?
    /// The running stream's configuration, so `update` keeps frame rate, cursor and shadow settings.
    private var config: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "com.w33d.mactoys.capture")

    public override init() { super.init() }

    /// `sourceRect` is in points, relative to the window/display; `scale` multiplies output pixels.
    public func start(_ source: Source, sourceRect: CGRect? = nil, fps: Int = 30, scale: CGFloat = 2,
                      showsCursor: Bool = false) async throws {
        stop()
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        var size: CGSize
        switch source {
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound }
            filter = SCContentFilter(desktopIndependentWindow: w)
            size = w.frame.size
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.notFound }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            size = CGSize(width: d.width, height: d.height)
        }
        let config = SCStreamConfiguration()
        if let r = sourceRect {
            config.sourceRect = r
            size = r.size
        }
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        if case .window = source {
            // Mirrors must line up with the window frame: drop the drop shadow around it.
            config.ignoreShadowsSingleWindow = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.config = config
    }

    /// Changes the cropped area of a running stream.
    public func update(sourceRect: CGRect, scale: CGFloat = 2) async {
        guard let stream else { return }
        let config = self.config ?? SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(2, Int(sourceRect.width * scale))
        config.height = max(2, Int(sourceRect.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        try? await stream.updateConfiguration(config)
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        self.config = nil
        Task { try? await stream.stopCapture() }
    }

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                   of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        nonisolated(unsafe) let frame = buffer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFrame?(frame) }
        }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.stream = nil
                self?.config = nil
                self?.onStop?(error)
            }
        }
    }
}

extension CGImage {
    /// Color of one pixel (pixel coordinates, origin top-left).
    public func color(atPixel x: Int, _ y: Int) -> RGBA? {
        guard x >= 0, y >= 0, x < width, y < height,
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: -x, y: y - height + 1, width: width, height: height))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return RGBA(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255, alpha: 1)
    }

    public var pngData: Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }

    public var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}
