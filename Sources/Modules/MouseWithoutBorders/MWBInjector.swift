import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Posts the input another Mac sends while it controls this one. Every key and button pressed
/// is remembered so `releaseAll()` can let go of them when control moves away or the
/// connection drops.
@MainActor
final class MWBInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var keysDown: Set<UInt16> = []
    private var buttonsDown: Set<UInt8> = []
    private var flags: CGEventFlags = []
    private(set) var position = CGPoint.zero

    var isHoldingInput: Bool { !keysDown.isEmpty || !buttonsDown.isEmpty }

    /// Control arrives: put the pointer at `p`.
    func enter(at p: CGPoint) {
        position = p
        MouseSynth.warp(to: p)
        post(mouse: .mouseMoved, button: .left, at: p, dx: 0, dy: 0)
    }

    func move(_ m: MWBMouseMove) {
        let p = CGPoint(x: m.x, y: m.y)
        position = p
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(0) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(1) { type = .rightMouseDragged; button = .right }
        else if let other = buttonsDown.min() { type = .otherMouseDragged; button = CGMouseButton(rawValue: UInt32(other)) ?? .center }
        else { type = .mouseMoved; button = .left }
        post(mouse: type, button: button, at: p, dx: m.dx, dy: m.dy)
    }

    func button(_ b: MWBMouseButton) {
        let p = CGPoint(x: b.x, y: b.y)
        position = p
        if b.down {
            buttonsDown.insert(b.button)
        } else {
            // A release without a press (the press stayed on the other Mac) is dropped.
            guard buttonsDown.remove(b.button) != nil else { return }
        }
        let type: CGEventType
        switch (b.button, b.down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: CGMouseButton(rawValue: UInt32(b.button)) ?? .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b.button))
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, b.clickCount)))
        e.flags = flags
        KeySynth.post(e)
    }

    func scroll(_ s: MWBScroll) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(s.dy.rounded()), wheel2: Int32(s.dx.rounded()), wheel3: 0) else { return }
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: s.dy)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: s.dx)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(s.lineDy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(s.lineDx))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(s.lineDy))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(s.lineDx))
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.continuous ? 1 : 0)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(s.phase))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(s.momentumPhase))
        e.location = position
        e.flags = flags
        KeySynth.post(e)
    }

    func key(_ k: MWBKey) {
        flags = CGEventFlags(rawValue: k.flags)
        if k.down { keysDown.insert(k.keyCode) } else { keysDown.remove(k.keyCode) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.keyCode, keyDown: k.down) else { return }
        e.flags = flags
        if k.autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        KeySynth.post(e)
    }

    func media(_ m: MWBMediaKey) {
        let state = m.down ? 0xA : 0xB
        let data1 = (Int(m.code) << 16) | (state << 8) | (m.autorepeat ? 1 : 0)
        guard let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                          modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                          context: nil, subtype: 8, data1: data1, data2: -1),
              let cg = ns.cgEvent else { return }
        KeySynth.post(cg)
    }

    /// Releases every key and button still held down by the other Mac.
    func releaseAll() {
        for b in buttonsDown.sorted() {
            button(MWBMouseButton(button: b, down: false, clickCount: 1, x: position.x, y: position.y))
        }
        // Non-modifier keys first, then modifiers, with the flags shrinking as they go up.
        let modifiers: Set<UInt16> = [UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Shift), UInt16(kVK_RightShift),
                                      UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Control),
                                      UInt16(kVK_RightControl), UInt16(kVK_Function)]
        for code in keysDown.subtracting(modifiers).sorted() {
            key(MWBKey(keyCode: code, down: false, flags: flags.rawValue, autorepeat: false))
        }
        for code in keysDown.intersection(modifiers).sorted() {
            key(MWBKey(keyCode: code, down: false, flags: 0, autorepeat: false))
        }
        keysDown = []
        buttonsDown = []
        flags = []
    }

    private func post(mouse type: CGEventType, button: CGMouseButton, at p: CGPoint, dx: Double, dy: Double) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        e.flags = flags
        KeySynth.post(e)
    }
}
