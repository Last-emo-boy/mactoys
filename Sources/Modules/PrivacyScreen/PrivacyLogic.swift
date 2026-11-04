import AppKit
import CoreGraphics
import Foundation

// Pure logic of Privacy Screen: everything here is plain data and functions, so it can be unit
// tested without a display, permissions or a running app.

// MARK: - Failed unlock attempts

/// How someone tried to unlock.
public enum UnlockMethod: String, Codable, Sendable {
    case password, touchID
}

/// One failed unlock attempt, kept in memory only.
struct FailedAttempt: Equatable, Sendable {
    let date: Date
    let method: UnlockMethod
}

/// Wrong passwords make the next attempt wait longer: 1, 2, 4, 8 … seconds, capped at five minutes.
/// Touch ID failures are listed but not penalized (the Secure Enclave rate-limits those itself).
struct UnlockBackoff: Equatable {
    static let cap: TimeInterval = 300

    private(set) var attempts: [FailedAttempt] = []
    private(set) var penalized = 0
    private(set) var lastPenalized: Date?

    /// Wait after `failures` wrong passwords.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(cap, pow(2, Double(min(failures - 1, 20))))
    }

    mutating func recordFailure(_ method: UnlockMethod, at date: Date) {
        attempts.append(FailedAttempt(date: date, method: method))
        guard method == .password else { return }
        penalized += 1
        lastPenalized = date
    }

    /// When the next password may be tried; nil when there is no wait.
    var nextAttempt: Date? {
        lastPenalized.map { $0.addingTimeInterval(Self.delay(afterFailures: penalized)) }
    }

    func remainingWait(at now: Date) -> TimeInterval {
        guard let next = nextAttempt else { return 0 }
        return max(0, next.timeIntervalSince(now))
    }

    func canTryPassword(at now: Date) -> Bool { remainingWait(at: now) <= 0 }

    mutating func reset() { self = UnlockBackoff() }
}

// MARK: - Away timers

/// Blur after N minutes without input, lock after M minutes. Each fires once per idle period; new
/// input starts a new period. While another app holds a display-sleep assertion (video, calls) the
/// timers pause, and the paused time does not count once they resume.
struct AwayTimers: Equatable {
    enum Action: Equatable { case blur, lock }

    var blurAfter: TimeInterval?
    var lockAfter: TimeInterval?
    var pauseWhileDisplayKeptAwake = true

    private(set) var lastIdle: TimeInterval = 0
    /// Idle time that passed while paused, in the current period.
    private(set) var pausedTime: TimeInterval = 0
    /// System idle value when the current pause began.
    private(set) var pauseStart: TimeInterval?
    private(set) var firedBlur = false
    private(set) var firedLock = false

    var isEnabled: Bool { blurAfter != nil || lockAfter != nil }

    /// Idle time that counts toward the timers.
    var effectiveIdle: TimeInterval { max(0, lastIdle - pausedTime - (pauseStart.map { lastIdle - $0 } ?? 0)) }

    /// Feeds one sample of the system idle time.
    /// - Parameters:
    ///   - idle: seconds since the last input event.
    ///   - displayKeptAwake: another process prevents display sleep right now.
    ///   - locked: the screen is already locked (nothing to do).
    mutating func update(idle: TimeInterval, displayKeptAwake: Bool, locked: Bool) -> Action? {
        if idle < lastIdle {
            // Input happened since the last sample: a new idle period begins.
            firedBlur = false
            firedLock = false
            pausedTime = 0
            pauseStart = nil
        }
        lastIdle = idle
        if pauseWhileDisplayKeptAwake && displayKeptAwake {
            if pauseStart == nil { pauseStart = idle }
            return nil
        }
        if let start = pauseStart {
            pausedTime += max(0, idle - start)
            pauseStart = nil
        }
        guard !locked else { return nil }
        let counted = idle - pausedTime
        if let lockAfter, !firedLock, counted >= lockAfter {
            firedLock = true
            firedBlur = true
            return .lock
        }
        if let blurAfter, !firedBlur, !firedLock, counted >= blurAfter {
            firedBlur = true
            return .blur
        }
        return nil
    }
}

// MARK: - Hot corners

enum HotCornerGeometry {
    /// The corner of a display that `point` rests in, within `size` points of both edges.
    /// Corners that touch another display are not corners: the pointer passes through them.
    /// - Parameters:
    ///   - point: Cocoa coordinates (y up), as `NSEvent.mouseLocation`.
    ///   - screens: display frames in Cocoa coordinates.
    static func corner(at point: CGPoint, screens: [CGRect], size: CGFloat = 4) -> ScreenCorner? {
        guard let s = screens.first(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }) else { return nil }
        let nearLeft = point.x - s.minX < size
        let nearRight = s.maxX - point.x <= size
        let nearBottom = point.y - s.minY < size
        let nearTop = s.maxY - point.y <= size
        let corner: ScreenCorner
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): corner = .topLeft
        case (_, true, true, _): corner = .topRight
        case (true, _, _, true): corner = .bottomLeft
        case (_, true, _, true): corner = .bottomRight
        default: return nil
        }
        // Points just past the corner, horizontally and vertically: if another display is there,
        // the pointer can keep going and the corner can't be "hit".
        let step = size * 2 + 2
        let dx: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? -step : step
        let dy: CGFloat = (corner == .topLeft || corner == .topRight) ? step : -step
        let beyond = [CGPoint(x: point.x + dx, y: point.y), CGPoint(x: point.x, y: point.y + dy),
                      CGPoint(x: point.x + dx, y: point.y + dy)]
        for p in beyond where screens.contains(where: { $0 != s && $0.contains(p) }) { return nil }
        return corner
    }
}

/// Fires once when the pointer has rested in the chosen corner for the dwell time; leaving the
/// corner re-arms it.
struct HotCornerTracker: Equatable {
    enum Step: Equatable {
        case idle
        /// In the corner; check again at this time.
        case waiting(until: Date)
        case fire
    }

    var target: ScreenCorner
    var dwell: TimeInterval
    private(set) var enteredAt: Date?
    private(set) var fired = false

    init(target: ScreenCorner, dwell: TimeInterval) {
        self.target = target
        self.dwell = dwell
    }

    mutating func update(corner: ScreenCorner?, now: Date) -> Step {
        guard target != .none, corner == target else {
            enteredAt = nil
            fired = false
            return .idle
        }
        if fired { return .idle }
        let start = enteredAt ?? now
        enteredAt = start
        if now.timeIntervalSince(start) >= dwell {
            fired = true
            return .fire
        }
        return .waiting(until: start.addingTimeInterval(dwell))
    }
}

// MARK: - Visible regions

enum RegionGeometry {
    /// Rects smaller than this (in either dimension) are dropped.
    static let minimumSide: CGFloat = 1

    /// `rect` minus `cutter`, as up to four non-overlapping rects (bands above and below the cut,
    /// then the pieces left and right of it).
    static func subtract(_ cutter: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(cutter)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        let pieces = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
        ]
        return pieces.filter { $0.width >= minimumSide && $0.height >= minimumSide }
    }

    /// The parts of `window` that no rect in `above` covers.
    static func visibleParts(of window: CGRect, above: [CGRect]) -> [CGRect] {
        var parts = [window].filter { $0.width >= minimumSide && $0.height >= minimumSide }
        for cutter in above {
            guard !parts.isEmpty else { break }
            parts = parts.flatMap { subtract(cutter, from: $0) }
        }
        return parts
    }

    static func area(_ rects: [CGRect]) -> CGFloat { rects.reduce(0) { $0 + $1.width * $1.height } }

    static func contains(_ rects: [CGRect], _ point: CGPoint) -> Bool { rects.contains { $0.contains(point) } }

    /// Converts a global top-left rect into the bottom-left local space of a window at `windowFrame`
    /// (Cocoa coordinates), given the primary display height.
    static func local(_ axRect: CGRect, in windowFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        let cocoaY = primaryHeight - axRect.maxY
        return CGRect(x: axRect.minX - windowFrame.minX, y: cocoaY - windowFrame.minY,
                      width: axRect.width, height: axRect.height)
    }
}

// MARK: - Window scene

/// One on-screen window as the window server reports it (no title, no content).
struct WindowSample: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    /// Window level (`kCGWindowLayer`).
    let layer: Int
    /// Global top-left coordinates.
    let frame: CGRect
}

/// The on-screen windows, front to back, plus the frontmost app.
struct WindowScene: Equatable, Sendable {
    var windows: [WindowSample] = []
    var frontPID: pid_t?

    /// Windows that sit below an overlay at `overlayLevel`.
    func covered(by overlayLevel: Int) -> [WindowSample] {
        windows.filter { $0.layer >= 0 && $0.layer < overlayLevel }
    }

    /// Focus Blur: the frontmost app's frontmost window, the child windows stacked right on it
    /// (sheets, popovers, completion lists), and the app's floating panels — everything that stays sharp.
    func focusHoles(overlayLevel: Int, attachMargin: CGFloat = 24) -> [CGRect] {
        guard let frontPID else { return [] }
        let below = covered(by: overlayLevel)
        var holes = below.filter { $0.pid == frontPID && $0.layer > 0 }.map(\.frame)
        let normal = below.filter { $0.layer == 0 }
        guard let first = normal.firstIndex(where: { $0.pid == frontPID }) else { return holes }
        let main = normal[first]
        holes.append(main.frame)
        let reach = main.frame.insetBy(dx: -attachMargin, dy: -attachMargin)
        for w in normal[(first + 1)...] {
            guard w.pid == frontPID else { break }
            if w.frame.intersects(reach) { holes.append(w.frame) }
        }
        return holes
    }

    /// The visible parts of every window whose owner matches, front to back, skipping the frontmost
    /// app when `skipFrontmost` is set. Each window loses what any window above it covers.
    func visibleRegions(overlayLevel: Int, skipFrontmost: Bool = true,
                        where matches: (pid_t) -> Bool) -> [(window: WindowSample, parts: [CGRect])] {
        let below = covered(by: overlayLevel)
        var result: [(WindowSample, [CGRect])] = []
        for (i, w) in below.enumerated() {
            guard matches(w.pid), !(skipFrontmost && w.pid == frontPID) else { continue }
            let above = below[..<i].map(\.frame)
            let parts = RegionGeometry.visibleParts(of: w.frame, above: above)
            if !parts.isEmpty { result.append((w, parts)) }
        }
        return result
    }
}

// MARK: - Notch island

enum IslandLayout {
    /// Where the unlock island goes on a display.
    /// - Parameters:
    ///   - content: size of the island's content (below the notch on notched displays).
    ///   - screen: display frame, Cocoa coordinates.
    ///   - notchHeight: `safeAreaInsets.top` (0 without a notch).
    ///   - leftOfNotch / rightOfNotch: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, Cocoa coordinates.
    ///   - topMargin: gap above the island on displays without a notch (e.g. the menu bar height).
    /// - Returns: the island frame and the height of the notch part at its top (0 when it floats).
    static func frame(content: CGSize, screen: CGRect, notchHeight: CGFloat, leftOfNotch: CGRect?,
                      rightOfNotch: CGRect?, topMargin: CGFloat = 12) -> (frame: CGRect, notch: CGFloat) {
        if notchHeight > 0, let left = leftOfNotch, let right = rightOfNotch, right.minX > left.maxX {
            let notchWidth = right.minX - left.maxX
            let width = min(screen.width, max(content.width, notchWidth + 64))
            let height = notchHeight + content.height
            let midX = (left.maxX + right.minX) / 2
            let x = min(max(screen.minX, midX - width / 2), screen.maxX - width)
            return (CGRect(x: x, y: screen.maxY - height, width: width, height: height), notchHeight)
        }
        let width = min(screen.width, content.width)
        return (CGRect(x: screen.midX - width / 2, y: screen.maxY - topMargin - content.height,
                       width: width, height: content.height), 0)
    }
}

// MARK: - Modes

/// Which privacy modes are on. Lock supersedes everything; Blur Screen hides Focus Blur and Private
/// Apps while it is up; Focus Blur already covers private apps.
struct PrivacyModes: Equatable, Sendable {
    var locked = false
    var screenBlurred = false
    var focusBlur = false
    var privateApps = false

    enum Request: Equatable, Sendable {
        case lock
        /// Only after authentication (or the macOS lock was unlocked).
        case unlock
        case blur
        case clearBlur
        case toggleBlur
        case setFocus(Bool)
        case toggleFocus
        case setPrivateApps(Bool)
        case togglePrivateApps
    }

    @discardableResult
    mutating func apply(_ request: Request) -> Bool {
        let before = self
        switch request {
        case .lock:
            locked = true
            screenBlurred = false
        case .unlock:
            locked = false
        case .blur:
            if !locked { screenBlurred = true }
        case .clearBlur:
            screenBlurred = false
        case .toggleBlur:
            if !locked { screenBlurred.toggle() }
        case .setFocus(let on):
            focusBlur = on
        case .toggleFocus:
            focusBlur.toggle()
        case .setPrivateApps(let on):
            privateApps = on
        case .togglePrivateApps:
            privateApps.toggle()
        }
        return self != before
    }

    var showsScreenBlur: Bool { !locked && screenBlurred }
    var showsFocusBlur: Bool { !locked && !screenBlurred && focusBlur }
    var showsPrivateApps: Bool { !locked && !screenBlurred && !focusBlur && privateApps }
}

/// `mactoys://privacyscreen/<action>`. Every action only turns protection on: no URL can unlock,
/// clear a blur or switch a mode off, because any app or web page can open a URL.
enum PrivacyURLAction: String, CaseIterable, Sendable {
    case lock, blur, focus
    case privateApps = "private"
    case appLock = "applock"
    case settings

    init?(action: String) {
        switch action.lowercased() {
        case "lock": self = .lock
        case "blur": self = .blur
        case "focus": self = .focus
        case "private", "privateapps": self = .privateApps
        case "applock", "app-lock": self = .appLock
        case "open", "settings", "show": self = .settings
        default: return nil
        }
    }

    /// The mode change this action makes; nil for actions that change no mode.
    var request: PrivacyModes.Request? {
        switch self {
        case .lock: .lock
        case .blur: .blur
        case .focus: .setFocus(true)
        case .privateApps: .setPrivateApps(true)
        case .appLock, .settings: nil
        }
    }
}

// MARK: - Presentation options

/// Saves the app's presentation options when the lock takes over the keyboard, and gives back
/// exactly what was there when it ends.
struct PresentationLease: Equatable {
    /// Hide the Dock and menu bar, disable ⌘Tab and Exposé, Force Quit, the power-key panel, the
    /// Apple menu and ⌘H. (A valid combination: the disables require hidden Dock and menu bar.)
    static let lockOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableAppleMenu, .disableHideApplication,
    ]

    private(set) var saved: NSApplication.PresentationOptions?

    var isEngaged: Bool { saved != nil }

    /// Returns the options to set. Engaging twice keeps the first saved options.
    mutating func engage(current: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        if saved == nil { saved = current }
        return Self.lockOptions
    }

    /// Returns the options to restore, or nil when nothing was engaged.
    mutating func release() -> NSApplication.PresentationOptions? {
        defer { saved = nil }
        return saved
    }
}

// MARK: - Blur strength

/// How a 0…1 blur strength is built from window-server materials: stacked behind-window blur layers
/// (each one blurs the result of the ones below) plus a dimming wash.
struct BlurRecipe: Equatable {
    /// Number of stacked blur panels per display.
    let layers: Int
    /// Opacity of the dim/tint wash over the blur.
    let wash: Double

    static func make(strength: Double) -> BlurRecipe {
        let s = min(1, max(0, strength))
        let layers = s < 0.34 ? 1 : (s < 0.75 ? 2 : 3)
        let wash = 0.06 + 0.3 * s
        return BlurRecipe(layers: layers, wash: (wash * 100).rounded() / 100)
    }
}
