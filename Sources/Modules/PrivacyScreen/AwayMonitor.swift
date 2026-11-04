import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import MacToysCore

/// Power assertions that keep the display awake (video playback, calls, presentations).
enum PowerAssertions {
    /// Assertion types that prevent display sleep.
    static let displayTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypeNoDisplaySleep as String,
    ]

    /// Whether any process except `excluding` holds an active display-sleep assertion.
    /// - Parameter byProcess: `IOPMCopyAssertionsByProcess` output: pid → assertion dictionaries.
    static func keepsDisplayAwake(_ byProcess: [Int32: [[String: Any]]], excluding pid: Int32) -> Bool {
        for (owner, assertions) in byProcess where owner != pid {
            for a in assertions {
                guard let type = a["AssertType"] as? String, displayTypes.contains(type) else { continue }
                let level = (a["AssertLevel"] as? Int) ?? 255
                if level > 0 { return true }
            }
        }
        return false
    }

    /// Reads the current assertions. MacToys' own (Awake creates some) never count.
    static func displayKeptAwakeByOthers() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let raw = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return false
        }
        var byProcess: [Int32: [[String: Any]]] = [:]
        for (pid, list) in raw { byProcess[pid.int32Value] = list }
        return keepsDisplayAwake(byProcess, excluding: ProcessInfo.processInfo.processIdentifier)
    }
}

/// Watches how long the Mac has had no input and engages Blur Screen or Lock after the configured
/// minutes. Reads the idle time the window server keeps (no Input Monitoring needed).
@MainActor
final class AwayMonitor {
    var onAction: ((AwayTimers.Action) -> Void)?
    /// Whether the screen is locked already.
    var isLocked: () -> Bool = { false }

    private var timers = AwayTimers()
    private var timer: Timer?
    static let interval: TimeInterval = 5
    /// `kCGAnyInputEventType`.
    private static let anyInput = CGEventType(rawValue: ~0)!

    var isRunning: Bool { timer != nil }

    func configure(blurMinutes: Int, lockMinutes: Int, pauseWhileDisplayKeptAwake: Bool) {
        timers.blurAfter = blurMinutes > 0 ? TimeInterval(blurMinutes * 60) : nil
        timers.lockAfter = lockMinutes > 0 ? TimeInterval(lockMinutes * 60) : nil
        timers.pauseWhileDisplayKeptAwake = pauseWhileDisplayKeptAwake
        if timers.isEnabled { start() } else { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        let kept = timers.pauseWhileDisplayKeptAwake && PowerAssertions.displayKeptAwakeByOthers()
        if let action = timers.update(idle: idle, displayKeptAwake: kept, locked: isLocked()) {
            onAction?(action)
        }
    }
}

/// Lock or blur when the pointer rests in a chosen display corner. Follows the pointer with global
/// mouse-moved monitors, which need no permission (only key monitoring does).
@MainActor
final class HotCornerMonitor {
    var onTrigger: (() -> Void)?

    private var tracker = HotCornerTracker(target: .none, dwell: 0.5)
    private var global: Any?
    private var local: Any?
    private var dwellTimer: Timer?

    func configure(corner: ScreenCorner, dwell: TimeInterval) {
        tracker.target = corner
        tracker.dwell = min(3, max(0.1, dwell))
        if corner == .none { stop() } else { start() }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        tracker = HotCornerTracker(target: tracker.target, dwell: tracker.dwell)
    }

    private func start() {
        guard global == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    private func pointerMoved() {
        let corner = HotCornerGeometry.corner(at: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        switch tracker.update(corner: corner, now: Date()) {
        case .idle:
            dwellTimer?.invalidate()
            dwellTimer = nil
        case .waiting(let until):
            guard dwellTimer == nil else { return }
            let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dwellTimer = nil
                    self?.pointerMoved()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            dwellTimer = t
        case .fire:
            dwellTimer?.invalidate()
            dwellTimer = nil
            onTrigger?()
        }
    }
}
