import AppKit
import MacToysCore

/// Keyboard snapping: ⌃⌥ arrows move the focused window between zones, ⌃⌥⇧ arrows extend it
/// over neighboring zones, ⌃⌥⇞/⇟ cycle windows sharing a zone.
extension ZoneEngine {
    /// Moves the focused window to the adjacent zone (zone-index or relative-position mode).
    func moveFocusedWindow(_ direction: ZoneDirection) {
        guard let (w, frame, display) = focusedTarget() else { return }
        let s = settings.value
        let all = displays
        let zones = self.zones(for: display)
        let current = currentZones(of: w, frame: frame, on: display, zones: zones)

        switch s.moveMode {
        case .zoneIndex:
            if let i = ZoneGeometry.index(after: current, count: zones.count, direction: direction, wrap: false) {
                snap(w, to: [i], on: display)
            } else if s.moveAcrossDisplays, let next = adjacentDisplay(to: display, forward: direction.isForward, in: all) {
                let nextZones = self.zones(for: next)
                guard !nextZones.isEmpty else { return }
                snap(w, to: [direction.isForward ? 0 : nextZones.count - 1], on: next)
            } else if s.wrapAround,
                      let i = ZoneGeometry.index(after: current, count: zones.count, direction: direction, wrap: true) {
                snap(w, to: [i], on: display)
            }
        case .relativePosition:
            let from = current.isEmpty ? frame : ZoneGeometry.union(of: current, in: zones)
            if let i = ZoneGeometry.zone(from: from, direction: direction, in: zones) {
                snap(w, to: [i], on: display)
                return
            }
            if s.moveAcrossDisplays, all.count > 1 {
                var targets: [(display: ZoneDisplay, index: Int)] = []
                var rects: [CGRect] = []
                for d in all where d.key != display.key {
                    for (i, z) in self.zones(for: d).enumerated() { targets.append((d, i)); rects.append(z) }
                }
                if let k = ZoneGeometry.zone(from: from, direction: direction, in: rects) {
                    snap(w, to: [targets[k].index], on: targets[k].display)
                    return
                }
            }
            if s.wrapAround,
               let i = ZoneGeometry.wrappedZone(from: from, direction: direction, in: zones, area: display.workArea) {
                snap(w, to: [i], on: display)
            }
        }
    }

    /// Grows (or shrinks back) the focused window over the zone in `direction`.
    /// A window in no zone is moved first, like PowerToys.
    func extendFocusedWindow(_ direction: ZoneDirection) {
        guard let (w, frame, display) = focusedTarget() else { return }
        let zones = self.zones(for: display)
        let current = currentZones(of: w, frame: frame, on: display, zones: zones)
        guard !current.isEmpty else { moveFocusedWindow(direction); return }
        let record = validRecord(for: w, frame: frame, on: display)
        let anchor = record?.extendAnchor ?? current
        let d = direction.vector
        let cursor = record?.extendCursor ?? current.max {
            zones[$0].midX * d.dx + zones[$0].midY * d.dy < zones[$1].midX * d.dx + zones[$1].midY * d.dy
        } ?? current[0]
        guard zones.indices.contains(cursor),
              let next = ZoneGeometry.zone(from: zones[cursor], direction: direction, in: zones) else { return }
        let span = ZoneGeometry.span(from: anchor, to: [next], in: zones)
        snap(w, to: span, on: display, extend: (anchor, next))
    }

    /// Focuses the next (or previous) window snapped to the same zone as the focused one.
    func cycleWindowsInZone(forward: Bool) {
        guard let w = focusedWindow() else { return }
        let group = windowsSharingZone(with: w)
        guard group.count > 1, let i = group.firstIndex(of: w) else { return }
        group[(i + (forward ? 1 : -1) + group.count) % group.count].focus()
    }

    /// Snaps the focused window to zone `index` (0-based) of its display.
    func snapFocusedWindow(toZone index: Int) {
        guard let (w, _, display) = focusedTarget() else { return }
        guard zones(for: display).indices.contains(index) else { return }
        snap(w, to: [index], on: display)
    }

    // MARK: Helpers

    /// The focused window, its frame and its display: the display it was snapped on while it
    /// is still in that zone (spanning layouts can reach across screens), else the one showing it.
    private func focusedTarget() -> (WindowRef, CGRect, ZoneDisplay)? {
        guard let w = focusedWindow(), isSnappable(w), let frame = w.frame else { return nil }
        AXUIElementSetMessagingTimeout(w.element, 0.5)
        let all = displays
        let display = liveRecord(for: w, frame: frame).flatMap { r in all.first { $0.key == r.displayKey } }
            ?? ZoneDisplay.showing(frame, in: all)
        guard let display else { return nil }
        return (w, frame, display)
    }

    /// The window's record while it is still in its zone of `display`'s current layout.
    private func validRecord(for w: WindowRef, frame: CGRect, on display: ZoneDisplay) -> SnapRecord? {
        guard let r = liveRecord(for: w, frame: frame), r.displayKey == display.key,
              r.layoutID == layout(for: display).id else { return nil }
        return r
    }

    /// The zones a window occupies: its snap record, else the zones its frame matches.
    private func currentZones(of w: WindowRef, frame: CGRect, on display: ZoneDisplay, zones: [CGRect]) -> [Int] {
        if let r = validRecord(for: w, frame: frame, on: display), r.zones.allSatisfy({ zones.indices.contains($0) }) {
            return r.zones
        }
        return ZoneGeometry.zonesMatching(frame: frame, in: zones, tolerance: 6)
    }

    private func adjacentDisplay(to display: ZoneDisplay, forward: Bool, in all: [ZoneDisplay]) -> ZoneDisplay? {
        guard all.count > 1, let i = all.firstIndex(where: { $0.key == display.key }) else { return nil }
        return all[(i + (forward ? 1 : -1) + all.count) % all.count]
    }
}
