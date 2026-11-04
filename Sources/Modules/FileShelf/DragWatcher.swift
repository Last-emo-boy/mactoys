import AppKit
import MacToysCore

/// Watches the pointer during drag-and-drop anywhere on screen and reports a shake.
///
/// Uses a global mouse-event monitor (no permission needed for mouse events) for left-button
/// down/dragged/up. A drag-and-drop session is told apart from a window move or a text selection
/// by the drag pasteboard: its change count moves when an app starts dragging something. The
/// dragged-event handler only feeds the allocation-free `ShakeDetector`; the pasteboard is read
/// once per click and once per detected shake.
@MainActor
final class DragWatcher {
    /// Called with the pointer location (Cocoa coordinates) when a shake happens during a drag.
    var onShake: ((CGPoint) -> Void)?
    /// Asked once per shake: false skips it (excluded apps).
    var shouldOpen: (() -> Bool)?

    private var monitor: Any?
    private var detector = ShakeDetector()
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCountAtPress = 0
    private var firedThisDrag = false
    private var buttonDown = false

    var isRunning: Bool { monitor != nil }

    func start(sensitivity: ShakeSensitivity) {
        detector.tuning = sensitivity.tuning
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        detector.reset()
        buttonDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            buttonDown = true
            firedThisDrag = false
            detector.reset()
            changeCountAtPress = dragPasteboard.changeCount
        case .leftMouseDragged:
            guard buttonDown, !firedThisDrag else { return }
            let p = NSEvent.mouseLocation
            guard detector.add(x: p.x, y: p.y, time: event.timestamp) else { return }
            // A shake: only act if something is being dragged (not a window or a selection).
            guard dragPasteboard.changeCount != changeCountAtPress else { return }
            firedThisDrag = true
            if shouldOpen?() ?? true { onShake?(p) }
        case .leftMouseUp:
            buttonDown = false
            detector.reset()
        default:
            break
        }
    }
}
