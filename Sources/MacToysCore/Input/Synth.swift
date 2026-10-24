import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Posts keyboard events. Everything posted here carries `marker` so `InputTap`
/// handlers don't react to MacToys' own output.
public enum KeySynth {
    public static let marker: Int64 = 0x4D54_4F59

    private static let source = CGEventSource(stateID: .hidSystemState)

    public static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    public static func key(_ code: Int, down: Bool, flags: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.flags = flags
        post(e)
    }

    /// Press and release a key with modifiers.
    public static func tap(_ code: Int, flags: CGEventFlags = []) {
        key(code, down: true, flags: flags)
        key(code, down: false, flags: flags)
    }

    public static func tap(_ shortcut: Shortcut) {
        tap(Int(shortcut.keyCode), flags: shortcut.modifiers.cgFlags)
    }

    /// Types arbitrary text (any script, emoji) regardless of keyboard layout.
    public static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                post(e)
            }
            i += 16
        }
    }

    public static func backspace(_ count: Int = 1) {
        for _ in 0..<count { tap(kVK_Delete) }
    }

    /// ⌘V into the frontmost app.
    public static func paste() { tap(kVK_ANSI_V, flags: .maskCommand) }
    /// ⌘C in the frontmost app.
    public static func copy() { tap(kVK_ANSI_C, flags: .maskCommand) }
}

/// Posts mouse events (marked like `KeySynth`).
public enum MouseSynth {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Current pointer location in global top-left coordinates.
    public static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public static func move(to point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        KeySynth.post(e)
    }

    /// Moves the pointer without generating an event (no acceleration, no apps notified).
    public static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public static func button(_ button: CGMouseButton, down: Bool, at point: CGPoint? = nil, clickCount: Int = 1,
                              flags: CGEventFlags = []) {
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point ?? location,
                              mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.flags = flags
        KeySynth.post(e)
    }

    public static func drag(_ button: CGMouseButton, to point: CGPoint) {
        let type: CGEventType = button == .left ? .leftMouseDragged : button == .right ? .rightMouseDragged : .otherMouseDragged
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                              mouseButton: button) else { return }
        KeySynth.post(e)
    }

    public static func scroll(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        KeySynth.post(e)
    }
}
