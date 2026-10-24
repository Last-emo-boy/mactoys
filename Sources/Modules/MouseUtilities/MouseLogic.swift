import CoreGraphics
import Foundation
import MacToysCore

/// Detects a modifier key pressed twice quickly on its own (Find My Mouse's double-⌃).
struct DoubleTapDetector {
    /// A press longer than this isn't a tap.
    var maxPress: TimeInterval = 0.4
    /// Longest gap between the first release and the second press.
    var maxGap: TimeInterval = 0.5

    private var pressedAt: TimeInterval?
    private var lastTapEnd: TimeInterval?
    private var taps = 0

    /// The watched key went down or up. `clean` is false while other modifiers are held.
    /// Returns true when the second tap completes.
    mutating func watchedKey(down: Bool, time: TimeInterval, clean: Bool) -> Bool {
        guard clean else { reset(); return false }
        if down {
            if let end = lastTapEnd, time - end > maxGap { taps = 0; lastTapEnd = nil }
            pressedAt = time
            return false
        }
        guard let start = pressedAt else { return false }
        pressedAt = nil
        guard time - start <= maxPress else { reset(); return false }
        taps += 1
        if taps >= 2 { reset(); return true }
        lastTapEnd = time
        return false
    }

    /// Another key or a mouse button: the taps no longer count.
    mutating func interrupt() { reset() }

    mutating func reset() {
        pressedAt = nil
        lastTapEnd = nil
        taps = 0
    }
}

/// Detects shaking: lots of back-and-forth movement in a short time.
///
/// Over the last `interval`, the pointer's path length must reach `minimumDistance` and be at
/// least `factor` times the diagonal of the box the movement stayed in. A long straight move
/// has a ratio near 1; shaking scores far higher. Samples live in a fixed ring buffer, so adding
/// one doesn't allocate.
struct ShakeDetector {
    var interval: TimeInterval = 1
    var minimumDistance: Double = 1000
    /// Ratio (4 = 400 %).
    var factor: Double = 4

    static let capacity = 512
    private var xs = [Double](repeating: 0, count: capacity)
    private var ys = [Double](repeating: 0, count: capacity)
    private var ts = [TimeInterval](repeating: 0, count: capacity)
    private var head = 0
    private var count = 0
    private var path: Double = 0

    mutating func add(_ p: CGPoint, at time: TimeInterval) -> Bool {
        while count > 0 && (time - ts[head] > interval || count == Self.capacity) { dropOldest() }
        if count > 0 {
            let last = (head + count - 1) % Self.capacity
            path += hypot(Double(p.x) - xs[last], Double(p.y) - ys[last])
        }
        let slot = (head + count) % Self.capacity
        xs[slot] = Double(p.x)
        ys[slot] = Double(p.y)
        ts[slot] = time
        count += 1
        guard path >= minimumDistance else { return false }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for i in 0..<count {
            let j = (head + i) % Self.capacity
            minX = min(minX, xs[j]); maxX = max(maxX, xs[j])
            minY = min(minY, ys[j]); maxY = max(maxY, ys[j])
        }
        let diagonal = max(hypot(maxX - minX, maxY - minY), 1)
        guard path >= factor * diagonal else { return false }
        reset()
        return true
    }

    mutating func reset() {
        head = 0
        count = 0
        path = 0
    }

    private mutating func dropOldest() {
        if count > 1 {
            let next = (head + 1) % Self.capacity
            path -= hypot(xs[next] - xs[head], ys[next] - ys[head])
        }
        head = (head + 1) % Self.capacity
        count -= 1
        if count <= 1 { path = 0 }
        path = max(0, path)
    }
}

/// CursorWrap's edge math, in global top-left coordinates.
enum CursorWrapMath {
    /// Where the pointer goes when it pushes against an outer edge of the desktop (an edge with
    /// no other display beyond it at that point), or nil. Horizontal wraps land on the far edge of
    /// the outermost display in the same row (the displays covering the pointer's y); vertical
    /// wraps likewise in the same column. Displays of different sizes and offsets are fine because
    /// only displays that cover the coordinate are candidates.
    static func wrap(_ p: CGPoint, delta: CGVector, displays: [CGRect], mode: CursorWrapSettings.Mode) -> CGPoint? {
        guard let current = displays.first(where: { $0.contains(p) })
            ?? displays.min(by: { $0.distance(to: p) < $1.distance(to: p) }) else { return nil }
        var q = p
        var wrapped = false
        if mode != .vertical {
            let row = displays.filter { $0.minY <= p.y && p.y < $0.maxY }
            if delta.dx > 0, p.x >= current.maxX - 1, !covered(CGPoint(x: current.maxX + 0.5, y: p.y), displays),
               let target = row.min(by: { $0.minX < $1.minX }) {
                q.x = target.minX + 1
                wrapped = true
            } else if delta.dx < 0, p.x < current.minX + 1, !covered(CGPoint(x: current.minX - 0.5, y: p.y), displays),
                      let target = row.max(by: { $0.maxX < $1.maxX }) {
                q.x = target.maxX - 2
                wrapped = true
            }
        }
        if mode != .horizontal {
            let column = displays.filter { $0.minX <= p.x && p.x < $0.maxX }
            if delta.dy > 0, p.y >= current.maxY - 1, !covered(CGPoint(x: p.x, y: current.maxY + 0.5), displays),
               let target = column.min(by: { $0.minY < $1.minY }) {
                q.y = target.minY + 1
                wrapped = true
            } else if delta.dy < 0, p.y < current.minY + 1, !covered(CGPoint(x: p.x, y: current.minY - 0.5), displays),
                      let target = column.max(by: { $0.maxY < $1.maxY }) {
                q.y = target.maxY - 2
                wrapped = true
            }
        }
        return wrapped ? q : nil
    }

    private static func covered(_ p: CGPoint, _ displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(p) }
    }
}

/// Mouse Button Lock: hold a button still long enough and it stays down after you let go;
/// the next press of any button releases it.
struct ButtonLockMachine {
    enum Button: Int, Hashable, Sendable { case left = 0, right = 1, middle = 2 }

    /// What to do with the event that was fed in.
    enum Decision: Equatable {
        case pass
        case swallow
        /// Turn this press into the release of the locked button.
        case becomeUp(Button)
        /// Turn this move into a drag of the locked button.
        case becomeDrag(Button)
        /// Turn this drag into a plain move (the physical button no longer counts as down).
        case becomeMove
    }

    enum State: Equatable {
        case idle
        case pressed(Button, at: TimeInterval, from: CGPoint)
        case locked(Button)
        /// The releasing press is still physically down.
        case releasing(physical: Button)
    }

    var lockable: Set<Button>
    var holdDuration: TimeInterval
    var dragThreshold: Double
    private(set) var state: State = .idle

    init(lockable: Set<Button>, holdDuration: TimeInterval, dragThreshold: Double) {
        self.lockable = lockable
        self.holdDuration = holdDuration
        self.dragThreshold = dragThreshold
    }

    var lockedButton: Button? {
        if case .locked(let b) = state { return b }
        return nil
    }

    mutating func down(_ b: Button, at time: TimeInterval, point: CGPoint) -> Decision {
        switch state {
        case .idle:
            if lockable.contains(b) { state = .pressed(b, at: time, from: point) }
            return .pass
        case .pressed:
            state = .idle  // a chord of buttons is never a lock
            return .pass
        case .locked(let l):
            state = .releasing(physical: b)
            return .becomeUp(l)
        case .releasing:
            return .pass
        }
    }

    /// Returns the decision and whether the button just became locked.
    mutating func up(_ b: Button, at time: TimeInterval) -> (Decision, lockedNow: Bool) {
        switch state {
        case .pressed(let p, let start, _) where p == b:
            if time - start >= holdDuration {
                state = .locked(b)
                return (.swallow, true)
            }
            state = .idle
            return (.pass, false)
        case .releasing(let p) where p == b:
            state = .idle
            return (.swallow, false)
        default:
            return (.pass, false)
        }
    }

    mutating func moved(to point: CGPoint) -> Decision {
        switch state {
        case .pressed(_, _, let from):
            if hypot(Double(point.x - from.x), Double(point.y - from.y)) > dragThreshold { state = .idle }
            return .pass
        case .locked(let b):
            return .becomeDrag(b)
        case .releasing:
            return .becomeMove
        case .idle:
            return .pass
        }
    }

    mutating func reset() { state = .idle }
}

/// The gliding cursor: a vertical line sweeps across the screen, fast then slow; then a
/// horizontal line does the same; the last press clicks where they cross. One shortcut drives it.
struct GlidingCursor {
    enum Phase: Equatable { case idle, xFast, xSlow, yFast, ySlow }

    private(set) var phase: Phase = .idle
    private(set) var position: CGPoint = .zero
    private(set) var bounds: CGRect = .zero

    var isActive: Bool { phase != .idle }

    mutating func start(at p: CGPoint, in bounds: CGRect) {
        self.bounds = bounds
        position = CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1), y: min(max(p.y, bounds.minY), bounds.maxY - 1))
        phase = .xFast
    }

    /// Advances to the next phase; returns the point to click after the last one.
    mutating func press() -> CGPoint? {
        switch phase {
        case .idle: return nil
        case .xFast: phase = .xSlow
        case .xSlow: phase = .yFast
        case .yFast: phase = .ySlow
        case .ySlow:
            phase = .idle
            return position
        }
        return nil
    }

    /// One animation frame. Lines wrap around at the screen edges.
    mutating func tick(fast: CGFloat, slow: CGFloat) {
        switch phase {
        case .idle: return
        case .xFast, .xSlow:
            position.x += phase == .xFast ? fast : slow
            if position.x >= bounds.maxX { position.x = bounds.minX + (position.x - bounds.maxX) }
        case .yFast, .ySlow:
            position.y += phase == .yFast ? fast : slow
            if position.y >= bounds.maxY { position.y = bounds.minY + (position.y - bounds.maxY) }
        }
    }

    mutating func cancel() { phase = .idle }
}

/// Mouse Jump's preview layout: every display scaled into one picture, in its real arrangement.
struct JumpLayout {
    struct Metrics: Equatable {
        /// Space around the whole picture.
        var padding: CGFloat
        /// Gap between neighboring displays.
        var margin: CGFloat
        /// Frame drawn around each display's image.
        var bezel: CGFloat
    }

    /// Display frames in global top-left coordinates.
    let displays: [CGRect]
    let union: CGRect
    let scale: CGFloat
    let size: CGSize
    /// Each display's slot in preview coordinates (top-left origin), bezel included.
    let slots: [CGRect]
    /// The image area inside each slot.
    let images: [CGRect]

    init(displays: [CGRect], maxSize: CGSize, metrics: Metrics) {
        self.displays = displays
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        self.union = union.isNull ? .zero : union
        let availW = max(maxSize.width - 2 * metrics.padding, 1)
        let availH = max(maxSize.height - 2 * metrics.padding, 1)
        let s = union.isNull || union.isEmpty ? 1 : min(availW / union.width, availH / union.height, 1)
        scale = s
        size = CGSize(width: (self.union.width * s).rounded(.up) + 2 * metrics.padding,
                      height: (self.union.height * s).rounded(.up) + 2 * metrics.padding)
        var slots: [CGRect] = []
        var images: [CGRect] = []
        for d in displays {
            let slot = CGRect(x: (d.minX - self.union.minX) * s + metrics.padding,
                              y: (d.minY - self.union.minY) * s + metrics.padding,
                              width: d.width * s, height: d.height * s)
            slots.append(slot.insetBy(dx: min(metrics.margin / 2, slot.width / 4), dy: min(metrics.margin / 2, slot.height / 4)))
            let inset = metrics.margin / 2 + metrics.bezel
            let image = slot.insetBy(dx: min(inset, slot.width / 3), dy: min(inset, slot.height / 3))
            images.append(image)
        }
        self.slots = slots
        self.images = images
    }

    /// The display slot under a preview point.
    func index(at p: CGPoint) -> Int? {
        if let i = slots.firstIndex(where: { $0.contains(p) }) { return i }
        return nil
    }

    /// The global point a click in the preview stands for (bezel clicks land on the screen edge).
    func globalPoint(for p: CGPoint) -> CGPoint? {
        guard let i = index(at: p) else { return nil }
        let img = images[i], d = displays[i]
        let fx = min(max((p.x - img.minX) / img.width, 0), 1)
        let fy = min(max((p.y - img.minY) / img.height, 0), 1)
        return CGPoint(x: min(d.minX + fx * d.width, d.maxX - 1), y: min(d.minY + fy * d.height, d.maxY - 1))
    }

    /// Where a global point is drawn in the preview.
    func previewPoint(for g: CGPoint) -> CGPoint? {
        guard let i = displays.firstIndex(where: { $0.contains(g) }) else { return nil }
        let img = images[i], d = displays[i]
        return CGPoint(x: img.minX + (g.x - d.minX) / d.width * img.width,
                       y: img.minY + (g.y - d.minY) / d.height * img.height)
    }
}

/// Crosshair arm rectangles around the pointer.
enum CrosshairGeometry {
    /// Left, right, top and bottom arms (only those the orientation shows), each `thickness`
    /// wide, starting `radius` away from `center` and running to the edges of `bounds`
    /// or for `length` points.
    static func arms(center c: CGPoint, bounds: CGRect, radius: CGFloat, thickness: CGFloat, length: CGFloat?,
                     orientation: CrosshairsSettings.Orientation) -> [CGRect] {
        var arms: [CGRect] = []
        let half = thickness / 2
        // CGRect.width is always positive, so check the extents before building rects.
        func horizontal(from x0: CGFloat, to x1: CGFloat) {
            if x1 > x0 { arms.append(CGRect(x: x0, y: c.y - half, width: x1 - x0, height: thickness)) }
        }
        func vertical(from y0: CGFloat, to y1: CGFloat) {
            if y1 > y0 { arms.append(CGRect(x: c.x - half, y: y0, width: thickness, height: y1 - y0)) }
        }
        if orientation != .vertical {
            horizontal(from: length.map { c.x - radius - $0 } ?? bounds.minX, to: c.x - radius)
            horizontal(from: c.x + radius, to: length.map { c.x + radius + $0 } ?? bounds.maxX)
        }
        if orientation != .horizontal {
            vertical(from: length.map { c.y - radius - $0 } ?? bounds.minY, to: c.y - radius)
            vertical(from: c.y + radius, to: length.map { c.y + radius + $0 } ?? bounds.maxY)
        }
        return arms
    }
}
