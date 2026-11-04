import AppKit
import CoreGraphics
import MacToysCore

/// One physical screen: what edge snap tiles into and what Auto Tiling may claim.
struct ScreenSlot: Equatable {
    let displayID: CGDirectDisplayID
    /// Full frame, top-left coordinates.
    let frame: CGRect
    /// Visible frame (menu bar and Dock excluded), top-left coordinates.
    let workArea: CGRect

    @MainActor
    static var current: [ScreenSlot] {
        NSScreen.screens.map { ScreenSlot(displayID: $0.displayID, frame: $0.axFrame, workArea: $0.axVisibleFrame) }
    }
}

/// The screens whose windows Auto Tiling arranges right now. FancyZones leaves them alone: no new
/// window placement, no zones or snapping while dragging, no keyboard moves, no zone flashes.
struct AutoTilingGate: Equatable {
    /// Top-left frames of the screens Auto Tiling manages.
    let managed: [CGRect]

    static let open = AutoTilingGate(managed: [])

    init(managed: [CGRect]) {
        self.managed = managed
    }

    /// Asks `manages` (Auto Tiling's `Services` hook; nil while Auto Tiling is off) about each screen.
    init(screens: [ScreenSlot], manages: ((CGDirectDisplayID) -> Bool)?) {
        guard let manages else { self.init(managed: []); return }
        self.init(managed: screens.filter { manages($0.displayID) }.map(\.frame))
    }

    var isEmpty: Bool { managed.isEmpty }

    /// Whether a point (the pointer while dragging) lies on a managed screen.
    func blocks(_ p: CGPoint) -> Bool {
        !managed.isEmpty && managed.contains { $0.contains(p) }
    }

    /// Whether a window frame or zone belongs to a managed screen (the one holding its center).
    func blocks(_ rect: CGRect) -> Bool {
        !managed.isEmpty && !rect.isNull && blocks(rect.center)
    }
}

extension ZoneEngine {
    /// The gate as of now, for `screens` (the current ones by default).
    func autoTilingGate(screens: [ScreenSlot]? = nil) -> AutoTilingGate {
        guard let manages = autoTilingManages() else { return .open }
        return AutoTilingGate(screens: screens ?? ScreenSlot.current, manages: manages)
    }
}
