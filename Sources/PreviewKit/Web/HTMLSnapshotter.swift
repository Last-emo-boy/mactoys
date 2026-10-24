import AppKit
import WebKit

/// Renders HTML to an image with an offscreen `WKWebView` (JavaScript off). Used for SVGs that
/// `NSImage` can't draw, Markdown thumbnails and offscreen UI snapshots.
@MainActor
public final class HTMLSnapshotter: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    private init(size: CGSize) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `html` at `size` (points) and returns a bitmap at `scale` × size, or nil on failure/timeout.
    public static func snapshot(html: String, size: CGSize, scale: CGFloat = 2, timeout: TimeInterval = 10) async -> CGImage? {
        let s = HTMLSnapshotter(size: size)
        s.window.orderFrontRegardless()
        defer { s.window.orderOut(nil) }
        let loaded = await s.load(html, timeout: timeout)
        guard loaded else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(size.width))
        config.afterScreenUpdates = true
        do {
            let image = try await s.webView.takeSnapshot(configuration: config)
            var rect = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } catch {
            return nil
        }
    }

    /// Blocks the main thread (spinning its run loop) until the snapshot is done.
    /// Only for offscreen rendering paths that are synchronous by design (preview scenes).
    public static func snapshotBlocking(html: String, size: CGSize, scale: CGFloat = 2, timeout: TimeInterval = 10) -> CGImage? {
        var result: CGImage?
        var finished = false
        Task { @MainActor in
            result = await snapshot(html: html, size: size, scale: scale, timeout: timeout)
            finished = true
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return result
    }

    private func load(_ html: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ ok: Bool) {
        guard let c = continuation else { return }
        continuation = nil
        if ok {
            // Give layout and image decoding a moment before the snapshot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { c.resume(returning: true) }
        } else {
            c.resume(returning: false)
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(true) }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }
}
