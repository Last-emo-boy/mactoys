import AppKit
import MacToysCore

/// Carbon also declares a `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// One display Auto Tiling arranges.
struct TileDisplay: Identifiable, Equatable {
    /// `NSScreen.stableID`, with the display id appended when two identical monitors share it.
    let key: String
    let displayID: CGDirectDisplayID
    let name: String
    /// 1-based, left to right.
    let number: Int
    /// Full frame, top-left coordinates.
    let frame: CGRect
    /// Without menu bar and Dock, top-left coordinates.
    let visibleFrame: CGRect
    /// The display with the menu bar.
    let isMain: Bool
    let isBuiltIn: Bool

    var id: String { key }
    var shape: DisplayShape { DisplayShape(size: frame.size) }

    /// Connected displays, left to right.
    @MainActor
    static func current() -> [TileDisplay] {
        let primary = NSScreen.screens.first
        let screens = NSScreen.screens.sorted { a, b in
            a.axFrame.minX != b.axFrame.minX ? a.axFrame.minX < b.axFrame.minX : a.axFrame.minY < b.axFrame.minY
        }
        let ids = screens.map(\.stableID)
        return screens.enumerated().map { i, s in
            let key = ids.filter { $0 == ids[i] }.count > 1 ? "\(ids[i])-\(s.displayID)" : ids[i]
            return TileDisplay(key: key, displayID: s.displayID, name: s.localizedName, number: i + 1, frame: s.axFrame,
                               visibleFrame: s.axVisibleFrame, isMain: s == primary, isBuiltIn: s.isBuiltIn)
        }
    }

    /// The display showing most of `rect`.
    static func showing(_ rect: CGRect, in displays: [TileDisplay]) -> TileDisplay? {
        if let d = displays.first(where: { $0.frame.contains(rect.center) }) { return d }
        let best = displays.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
        if let best, best.frame.intersection(rect).area > 0 { return best }
        return displays.min { $0.frame.distance(to: rect.center) < $1.frame.distance(to: rect.center) }
    }

    /// The display containing a point (the nearest one outside all of them).
    static func containing(_ p: CGPoint, in displays: [TileDisplay]) -> TileDisplay? {
        displays.first { $0.frame.contains(p) } ?? displays.min { $0.frame.distance(to: p) < $1.frame.distance(to: p) }
    }
}

/// Moves windows off the main thread: every Accessibility call waits for the app to answer.
final class FrameApplier: @unchecked Sendable {
    struct Move: @unchecked Sendable {
        let ref: WindowRef
        let id: CGWindowID
        let frame: CGRect
    }

    struct Result: Sendable {
        let id: CGWindowID
        let requested: CGRect
        /// The frame the window has afterwards (nil when it's gone).
        let actual: CGRect?
    }

    private let queue = DispatchQueue(label: "com.w33d.mactoys.autotile.frames", qos: .userInteractive)

    /// Sets every frame in one go, then reads them back; `completion` runs on the main actor.
    func apply(_ moves: [Move], completion: @escaping @MainActor ([Result]) -> Void) {
        guard !moves.isEmpty else { return }
        queue.async {
            var results: [Result] = []
            results.reserveCapacity(moves.count)
            for m in moves {
                // A hung app must not hold up the other windows.
                AXUIElementSetMessagingTimeout(m.ref.element, 0.3)
                m.ref.setFrame(m.frame)
                results.append(Result(id: m.id, requested: m.frame, actual: m.ref.frame))
            }
            // Some apps resize a moment later: read the ones that didn't land once more before
            // their size is taken for a minimum.
            let unsettled = results.indices.filter { i in
                results[i].actual.map { !Self.landed($0, results[i].requested) } ?? false
            }
            if !unsettled.isEmpty {
                Thread.sleep(forTimeInterval: 0.12)
                for i in unsettled {
                    results[i] = Result(id: results[i].id, requested: results[i].requested, actual: moves[i].ref.frame)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(results) }
            }
        }
    }

    static func landed(_ actual: CGRect, _ requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= 2 && abs(actual.minY - requested.minY) <= 2
            && abs(actual.width - requested.width) <= 2 && abs(actual.height - requested.height) <= 2
    }
}

/// A window Auto Tiling knows about.
struct TrackedWindow {
    let ref: WindowRef
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// Last known frame, top-left coordinates.
    var frame: CGRect
    var isMinimized: Bool
    var isFullScreen: Bool
    let cornerRadius: CGFloat
    /// System uptime when first seen.
    let firstSeen: TimeInterval
    /// The smallest size this window accepted so far (zero until learned).
    var minimum: CGSize = .zero
}
