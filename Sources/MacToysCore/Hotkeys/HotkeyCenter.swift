import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys through Carbon `RegisterEventHotKey`. Needs no permission.
///
///     HotkeyCenter.shared.register("colorpicker.activate", settings.value.activation) { … }
///
/// Registering the same id again replaces the previous binding; passing `nil` unregisters.
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private struct Entry {
        var id: String
        var shortcut: Shortcut
        var number: UInt32
        var ref: EventHotKeyRef?
        var onPress: () -> Void
        var onRelease: (() -> Void)?
    }

    private var entries: [String: Entry] = [:]
    private var nextNumber: UInt32 = 1
    private var handler: EventHandlerRef?
    private let log = Log.for("hotkeys")
    private static let signature: OSType = 0x4D54_4F59 // 'MTOY'

    /// Ids whose shortcut could not be registered (taken by another app).
    public private(set) var failed: Set<String> = []

    /// While true (shortcut recording), hotkeys do not fire.
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            for id in entries.keys {
                if isSuspended { unregisterCarbon(id) } else { registerCarbon(id) }
            }
        }
    }

    private init() {}

    @discardableResult
    public func register(_ id: String, _ shortcut: Shortcut?, onPress: @escaping () -> Void,
                         onRelease: (() -> Void)? = nil) -> Bool {
        unregister(id)
        guard let shortcut else { return true }
        installHandlerIfNeeded()
        entries[id] = Entry(id: id, shortcut: shortcut, number: nextNumber, ref: nil,
                            onPress: onPress, onRelease: onRelease)
        nextNumber += 1
        guard !isSuspended else { return true }
        return registerCarbon(id)
    }

    public func unregister(_ id: String) {
        unregisterCarbon(id)
        entries[id] = nil
        failed.remove(id)
    }

    public func unregister(prefix: String) {
        for id in entries.keys where id.hasPrefix(prefix) { unregister(id) }
    }

    /// Every active binding, for conflict detection and the Shortcut Guide.
    public var bindings: [String: Shortcut] { entries.mapValues(\.shortcut) }

    /// Other registered ids that use the same shortcut.
    public func conflicts(for shortcut: Shortcut, excluding id: String) -> [String] {
        entries.values.filter { $0.id != id && $0.shortcut == shortcut }.map(\.id)
    }

    @discardableResult
    private func registerCarbon(_ id: String) -> Bool {
        guard var entry = entries[id], entry.ref == nil else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: entry.number)
        let status = RegisterEventHotKey(UInt32(entry.shortcut.keyCode), entry.shortcut.modifiers.carbonFlags,
                                         hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            entry.ref = ref
            entries[id] = entry
            failed.remove(id)
            return true
        }
        log.error("Hotkey \(id, privacy: .public) \(entry.shortcut.description, privacy: .public) failed: \(status)")
        failed.insert(id)
        return false
    }

    private func unregisterCarbon(_ id: String) {
        guard var entry = entries[id], let ref = entry.ref else { return }
        UnregisterEventHotKey(ref)
        entry.ref = nil
        entries[id] = entry
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let number = hotKeyID.id
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(number: number, pressed: pressed) }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }

    private func fire(number: UInt32, pressed: Bool) {
        guard let entry = entries.values.first(where: { $0.number == number }) else { return }
        if pressed { entry.onPress() } else { entry.onRelease?() }
    }
}
