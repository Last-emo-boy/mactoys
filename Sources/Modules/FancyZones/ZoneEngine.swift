import AppKit
import ApplicationServices
import MacToysCore

/// Carbon also declares a `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Where a window was snapped, so it can be restored, kept in its zone and cycled.
struct SnapRecord {
    var displayKey: String
    var layoutID: String
    var zones: [Int]
    /// Size before the first snap, restored when the window is dragged out.
    var originalSize: CGSize
    /// Snap order, for cycling windows that share a zone.
    var sequence: Int
    /// Keyboard extension: the zones the extension started from and the zone it reached.
    var extendAnchor: [Int]?
    var extendCursor: Int?
}

/// The last zone an app's window was snapped to (for "move newly created windows to their last known zone").
struct ZoneHistoryEntry: Codable, Equatable {
    var displayKey: String
    var layoutID: String
    var zones: [Int]
}

/// FancyZones state shared by dragging, the keyboard, the editor and window watching:
/// settings, layouts per display, snapped windows and the zone overlay.
@MainActor
final class ZoneEngine {
    let settings: Persisted<FancyZonesSettings>
    let library: Persisted<LayoutLibrary>
    let history: Persisted<[String: ZoneHistoryEntry]>
    let overlay = ZoneOverlay()
    /// Called after a display's layout changed (so an ongoing drag can redraw).
    var onLayoutChange: ((ZoneDisplay) -> Void)?

    private(set) var records: [WindowRef: SnapRecord] = [:]
    private var sequence = 0
    private let log = Log.for("fancyzones")

    init(settings: Persisted<FancyZonesSettings>, library: Persisted<LayoutLibrary>,
         history: Persisted<[String: ZoneHistoryEntry]>) {
        self.settings = settings
        self.library = library
        self.history = history
    }

    // MARK: Displays and layouts

    var displays: [ZoneDisplay] { ZoneDisplay.current(spanning: settings.value.spanAcrossDisplays) }

    var style: ZoneStyle { ZoneStyle(settings.value) }

    func layout(for display: ZoneDisplay) -> ZoneLayout {
        let s = settings.value
        return library.value.layout(forDisplay: display.key, vertical: display.isVertical,
                                    defaultHorizontal: s.defaultHorizontalLayout, defaultVertical: s.defaultVerticalLayout)
    }

    func zones(for display: ZoneDisplay) -> [CGRect] {
        layout(for: display).zones(in: display.workArea)
    }

    func display(key: String) -> ZoneDisplay? { displays.first { $0.key == key } }

    func displayUnderPointer() -> ZoneDisplay? {
        ZoneDisplay.containing(ScreenGeometry.toAX(NSEvent.mouseLocation), in: displays)
    }

    /// The display the user is working on: the focused window's, else the one under the pointer.
    func activeDisplay() -> ZoneDisplay? {
        if let f = focusedWindow()?.frame, let d = ZoneDisplay.showing(f, in: displays) { return d }
        return displayUnderPointer()
    }

    /// The focused window of the frontmost app, never one of MacToys' own: an Accessibility
    /// request into our own process from the main thread would wait on itself until it times out.
    func focusedWindow() -> WindowRef? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return WindowRef.focused()
    }

    /// Assigns `layout` to `display`; windows snapped there follow when the option is on.
    /// With `announce`, the zones flash and the layout name shows (per the settings).
    func apply(_ layout: ZoneLayout, to display: ZoneDisplay, announce: Bool) {
        library.update { $0.assignments[display.key] = layout.id }
        if settings.value.keepWindowsOnLayoutChange { refit(display) }
        onLayoutChange?(display)
        guard announce else { return }
        if settings.value.flashZonesOnLayoutSwitch {
            overlay.flash(ZoneLayer(display: display, zones: layout.zones(in: display.workArea)), style: style)
        }
        overlay.showLayoutName(layout.name, on: display, settings: settings.value)
    }

    /// Applies the layout with quick key `n` to the active display.
    @discardableResult
    func applyQuickKey(_ n: Int, on display: ZoneDisplay? = nil) -> Bool {
        guard let layout = library.value.layout(quickKey: n), let d = display ?? activeDisplay() else { return false }
        apply(layout, to: d, announce: true)
        return true
    }

    // MARK: Windows

    /// Whether FancyZones may move this window.
    func isSnappable(_ w: WindowRef) -> Bool {
        guard w.pid != ProcessInfo.processInfo.processIdentifier, w.role == kAXWindowRole as String else { return false }
        let s = settings.value
        if s.excludedApps.matches(app: w.app) { return false }
        let subrole = w.subrole
        if subrole == kAXStandardWindowSubrole as String {
            // Regular document and app windows always snap.
        } else if subrole == kAXDialogSubrole as String || subrole == kAXSystemDialogSubrole as String {
            if !s.allowChildWindows { return false }
        } else if !s.allowPopupWindows {
            return false
        }
        return !w.isFullScreen && !w.isMinimized
    }

    func record(for w: WindowRef) -> SnapRecord? { records[w] }

    func forget(_ w: WindowRef) { records[w] = nil }

    /// Moves a window over `zones` of `display` and remembers it.
    func snap(_ w: WindowRef, to zones: [Int], on display: ZoneDisplay, originalSize: CGSize? = nil,
              extend: (anchor: [Int], cursor: Int)? = nil) {
        let layout = layout(for: display)
        let all = layout.zones(in: display.workArea)
        let indices = Array(Set(zones.filter { all.indices.contains($0) })).sorted()
        let target = ZoneGeometry.union(of: indices, in: all)
        guard !target.isNull else { return }
        let current = w.frame
        let original = originalSize ?? records[w]?.originalSize ?? current?.size ?? target.size
        if w.isResizable {
            w.setFrame(target)
        } else if let size = current?.size {
            // Fixed-size windows are centered in the zone instead.
            w.setPosition(CGPoint(x: max(target.minX, target.midX - size.width / 2),
                                  y: max(target.minY, target.midY - size.height / 2)))
        }
        sequence += 1
        records[w] = SnapRecord(displayKey: display.key, layoutID: layout.id, zones: indices,
                                originalSize: original, sequence: sequence,
                                extendAnchor: extend?.anchor, extendCursor: extend?.cursor)
        if let bid = w.bundleIdentifier {
            history.value[bid] = ZoneHistoryEntry(displayKey: display.key, layoutID: layout.id, zones: indices)
        }
    }

    /// Re-snaps windows on `display` to the same zone numbers of its current layout; windows
    /// whose zone no longer exists are released.
    func refit(_ display: ZoneDisplay) {
        let layout = layout(for: display)
        let count = layout.count
        for (w, r) in records where r.displayKey == display.key {
            guard r.zones.allSatisfy({ $0 < count }) else { records[w] = nil; continue }
            guard w.position != nil else { records[w] = nil; continue }
            snap(w, to: r.zones, on: display, originalSize: r.originalSize)
        }
    }

    /// After the display arrangement or resolution changed.
    func refitAll() {
        purgeStaleRecords()
        for d in displays { refit(d) }
    }

    func purgeStaleRecords() {
        records = records.filter { $0.key.position != nil }
    }

    /// Windows snapped to the same zones of the same display as `w`, in snap order.
    func windowsSharingZone(with w: WindowRef) -> [WindowRef] {
        guard let r = records[w] else { return [] }
        purgeStaleRecords()
        return records.filter { $0.value.displayKey == r.displayKey && $0.value.zones == r.zones && !$0.key.isMinimized }
            .sorted { $0.value.sequence < $1.value.sequence }
            .map(\.key)
    }

    func reset() {
        records.removeAll()
        overlay.tearDown()
    }
}
