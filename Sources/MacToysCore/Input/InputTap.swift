import AppKit
import CoreGraphics

/// What a tap handler wants done with an event.
public enum TapDecision {
    /// Let the next handler (and then the system) see it.
    case pass
    /// Swallow it.
    case consume
    /// Deliver this event instead and stop the chain.
    case replace(CGEvent)
}

/// One shared session event tap that every module hooks into, ordered by priority
/// (higher first). Requires Accessibility; it starts on its own once access is granted.
///
///     InputTap.shared.add("quickaccent", priority: 50, events: [.keyDown, .keyUp]) { type, event in
///         …
///         return .pass
///     }
///
/// Events MacToys itself posts through `KeySynth`/`MouseSynth` are skipped unless the
/// handler opts in with `includeSynthetic`.
@MainActor
public final class InputTap {
    public static let shared = InputTap()
    public typealias Handler = (CGEventType, CGEvent) -> TapDecision

    private struct Entry {
        var id: String
        var priority: Int
        var mask: CGEventMask
        var includeSynthetic: Bool
        var handler: Handler
    }

    private var entries: [Entry] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var installedMask: CGEventMask = 0
    private var retryTimer: Timer?
    private let log = Log.for("inputtap")

    /// `NSEvent.EventType.systemDefined` (media keys) as a CGEventType.
    public static let systemDefined = CGEventType(rawValue: 14)!

    public var isRunning: Bool { tap != nil }

    private init() {}

    public func add(_ id: String, priority: Int = 0, events: [CGEventType], includeSynthetic: Bool = false,
                    _ handler: @escaping Handler) {
        remove(id)
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        entries.append(Entry(id: id, priority: priority, mask: mask, includeSynthetic: includeSynthetic, handler: handler))
        entries.sort { $0.priority > $1.priority }
        rebuild()
    }

    public func remove(_ id: String) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { rebuild() }
    }

    /// Re-attempt tap creation (called after Accessibility is granted).
    public func restart() {
        teardown()
        rebuild()
    }

    private func rebuild() {
        let mask = entries.reduce(CGEventMask(0)) { $0 | $1.mask }
        if mask == 0 { teardown(); return }
        if tap != nil && mask == installedMask { return }
        teardown()
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated { InputTap.shared.dispatch(type, event) }
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil) else {
            log.notice("Event tap unavailable (Accessibility not granted?) — retrying")
            scheduleRetry()
            return
        }
        tap = port
        installedMask = mask
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                InputTap.shared.retryTimer?.invalidate()
                InputTap.shared.retryTimer = nil
                InputTap.shared.rebuild()
            }
        }
    }

    private func teardown() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        installedMask = 0
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == KeySynth.marker
        let bit = CGEventMask(1) << type.rawValue
        for entry in entries where entry.mask & bit != 0 {
            if synthetic && !entry.includeSynthetic { continue }
            switch entry.handler(type, event) {
            case .pass: continue
            case .consume: return nil
            case .replace(let replacement): return Unmanaged.passRetained(replacement)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
