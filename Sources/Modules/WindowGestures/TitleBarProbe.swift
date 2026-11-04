import AppKit
import ApplicationServices
import MacToysCore

/// Carbon also declares a `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Finds and remembers where each window's title bar ends, from where its close button sits.
///
/// A lookup is a few Accessibility calls to the window's app, made only when a gesture begins near
/// the top of a window whose band isn't known yet, with a short messaging timeout so a hung app
/// can't stall the event tap. Results are kept per window (and refreshed after a while, since
/// toolbars can be shown or hidden). The front window's band is looked up ahead of time whenever
/// an app becomes active.
@MainActor
final class TitleBarProbe {
    private struct Entry {
        var band: CGFloat
        var time: TimeInterval
        /// The window didn't say (or its app didn't answer): look again sooner.
        var guessed: Bool
    }

    private var cache: [CGWindowID: Entry] = [:]
    private static let lifetime: TimeInterval = 120
    private static let guessLifetime: TimeInterval = 15
    private static let capacity = 96
    private static let timeout: Float = 0.08

    /// The title bar height of `entry`, from the cache or looked up now.
    func band(for entry: WindowEntry, fallback: CGFloat) -> CGFloat {
        let now = ProcessInfo.processInfo.systemUptime
        if let e = cache[entry.id], now - e.time < (e.guessed ? Self.guessLifetime : Self.lifetime) {
            return e.guessed ? fallback : e.band
        }
        let band = lookUp(pid: entry.pid, windowID: entry.id, frame: entry.frame)
        remember(entry.id, band: band ?? fallback, guessed: band == nil, now: now)
        return band ?? fallback
    }

    /// Looks up the focused window of `app` ahead of the first gesture on it.
    func prewarm(_ app: NSRunningApplication?, fallback: CGFloat) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted() else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Self.timeout)
        guard let window: AXUIElement = axApp.ax(kAXFocusedWindowAttribute) else { return }
        let w = WindowRef(element: window, pid: app.processIdentifier)
        AXUIElementSetMessagingTimeout(window, Self.timeout)
        guard let id = w.windowID, let frame = w.frame else { return }
        let band = SurfaceHitTest.band(window: frame, closeButton: Self.closeButtonFrame(of: window))
        remember(id, band: band ?? fallback, guessed: band == nil, now: ProcessInfo.processInfo.systemUptime)
    }

    func clear() { cache.removeAll() }

    private func remember(_ id: CGWindowID, band: CGFloat, guessed: Bool, now: TimeInterval) {
        if cache.count >= Self.capacity {
            // Drop the oldest half; the windows still in use come back on their next gesture.
            let cutoff = cache.values.map(\.time).sorted()[cache.count / 2]
            cache = cache.filter { $0.value.time > cutoff }
        }
        cache[id] = Entry(band: band, time: now, guessed: guessed)
    }

    /// The band from the window's close button; nil when it has none or its app doesn't answer.
    private func lookUp(pid: pid_t, windowID: CGWindowID, frame: CGRect) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.timeout)
        let windows: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
        guard let window = windows.first(where: { WindowRef(element: $0, pid: pid).windowID == windowID }) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, Self.timeout)
        return SurfaceHitTest.band(window: frame, closeButton: Self.closeButtonFrame(of: window))
    }

    private static func closeButtonFrame(of window: AXUIElement) -> CGRect? {
        guard let button: AXUIElement = window.ax(kAXCloseButtonAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(button, timeout)
        return WindowRef(element: button, pid: 0).frame
    }
}
