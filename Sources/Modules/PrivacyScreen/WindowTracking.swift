import AppKit
import CoreGraphics
import MacToysCore

extension WindowScene {
    /// The on-screen windows from the window server: bounds, owner pid and level only. Window
    /// titles and contents are never read (and need no permission this way).
    static func current() -> WindowScene {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return WindowScene(windows: [], frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        var windows: [WindowSample] = []
        windows.reserveCapacity(list.count)
        for d in list {
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 8, frame.height >= 8 else { continue }
            if let alpha = d[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            windows.append(WindowSample(id: id, pid: pid, layer: layer, frame: frame))
        }
        return WindowScene(windows: windows, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
}

/// Samples the window list while some mode needs it (Focus Blur, Private Apps, App Lock): about 30
/// times a second while windows move, 8 times a second when nothing changed for a moment, and not at
/// all when nobody subscribes.
@MainActor
final class WindowPoller {
    /// `changed` is true when the scene differs from the previous sample.
    typealias Handler = @MainActor (_ scene: WindowScene, _ changed: Bool) -> Void

    static let fastInterval: TimeInterval = 1.0 / 30
    static let slowInterval: TimeInterval = 1.0 / 8
    /// Stay fast this long after the last change.
    static let settle: TimeInterval = 0.8

    private var handlers: [String: Handler] = [:]
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private(set) var scene = WindowScene()
    private var lastChange = Date.distantPast
    private var activationObserver: NSObjectProtocol?

    var isRunning: Bool { timer != nil }

    func subscribe(_ id: String, _ handler: @escaping Handler) {
        handlers[id] = handler
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poke() }
            }
        }
        tick(force: true)
    }

    func unsubscribe(_ id: String) {
        guard handlers.removeValue(forKey: id) != nil, handlers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        interval = 0
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        scene = WindowScene()
    }

    /// Samples now (after an app switch or a display change).
    func poke() {
        guard !handlers.isEmpty else { return }
        tick(force: true)
    }

    private func tick(force: Bool = false) {
        guard !handlers.isEmpty else { return }
        let next = WindowScene.current()
        let changed = force || next != scene
        let now = Date()
        if changed {
            scene = next
            lastChange = now
        }
        for handler in handlers.values { handler(scene, changed) }
        schedule(now.timeIntervalSince(lastChange) < Self.settle ? Self.fastInterval : Self.slowInterval)
    }

    private func schedule(_ wanted: TimeInterval) {
        guard timer == nil || wanted != interval else { return }
        timer?.invalidate()
        interval = wanted
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = wanted * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
