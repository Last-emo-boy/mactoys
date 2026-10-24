import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// An NSView that records keys while it is the first responder. Clicking focuses it;
/// Tab and ⇧Tab move focus on (so Tab itself is picked from the list instead).
/// It records physical keys: the owner suspends remapping while it has focus.
final class KeyCaptureNSView: NSView {
    enum Mode { case key, shortcut }

    var mode: Mode = .key
    var onCapture: ((KeyCombo) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onModifiers: ((Modifiers) -> Void)?

    private var pendingModifier: Int?
    private var mediaMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?(true)
        mediaMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, event.subtype.rawValue == 8 else { return event }
            let state = (event.data1 & 0xFF00) >> 8
            if state == 0xA { self.onCapture?(KeyCombo([], .media((event.data1 & 0xFFFF_0000) >> 16))) }
            return nil
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
        mediaMonitor = nil
        pendingModifier = nil
        onModifiers?([])
        onFocus?(false)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        let mods = Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if event.keyCode == UInt16(kVK_Tab) && mods.intersection([.command, .option, .control]).isEmpty {
            if mods.contains(.shift) { window?.selectKeyView(preceding: self) } else { window?.selectKeyView(following: self) }
            return
        }
        guard !event.isARepeat else { return }
        pendingModifier = nil
        let key = Key.keyboard(Int(event.keyCode))
        switch mode {
        case .key:
            onCapture?(KeyCombo([], key))
        case .shortcut:
            var m = mods
            if !KeyCodes.isFunctionKey(event.keyCode) { m.remove(.function) }
            onCapture?(KeyCombo(m, key))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let code = Int(event.keyCode)
        onModifiers?(Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
        if code == kVK_CapsLock {
            if mode == .key { onCapture?(KeyCombo([], .capsLock)) }
            return
        }
        guard mode == .key, let info = KeyCatalog.modifierInfo[code] else { return }
        let raw = UInt64(event.modifierFlags.rawValue)
        let down = info.deviceMask != 0 ? raw & info.deviceMask != 0 : event.modifierFlags.contains(.function)
        if down {
            // A modifier pressed and released on its own is recorded as that key (e.g. Right ⌘).
            pendingModifier = pendingModifier == nil ? code : -1
        } else if pendingModifier == code {
            pendingModifier = nil
            onCapture?(KeyCombo([], .keyboard(code)))
        } else if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            pendingModifier = nil
        }
    }
}

struct KeyCaptureView: NSViewRepresentable {
    var mode: KeyCaptureNSView.Mode
    var onCapture: (KeyCombo) -> Void
    var onFocus: (Bool) -> Void
    var onModifiers: (Modifiers) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let v = KeyCaptureNSView()
        update(v)
        return v
    }

    func updateNSView(_ v: KeyCaptureNSView, context: Context) { update(v) }

    private func update(_ v: KeyCaptureNSView) {
        v.mode = mode
        v.onCapture = onCapture
        v.onFocus = onFocus
        v.onModifiers = onModifiers
    }
}

/// A key or shortcut field: click and press keys to record, or pick from the list (which also
/// has media keys and keys your keyboard lacks). Shortcut fields add modifier toggles.
struct KeyField: View {
    @Binding var combo: KeyCombo
    var mode: KeyCaptureNSView.Mode
    var onFocusChange: (Bool) -> Void

    @State private var focused = false
    @State private var live: Modifiers = []
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if mode == .shortcut { modifierToggles }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                KeyCaptureView(mode: mode,
                               onCapture: { combo = $0 },
                               onFocus: { f in
                                   focused = f
                                   onFocusChange(f)
                               },
                               onModifiers: { live = $0 })
                HStack(spacing: 6) {
                    if focused && !live.isEmpty && mode == .shortcut {
                        Keycaps(live.symbols)
                        Text("…").foregroundStyle(.secondary)
                    } else {
                        Keycaps(combo.keycaps)
                    }
                    Spacer(minLength: 4)
                    Text(focused ? "Recording · Tab to finish" : "Click to record")
                        .font(.system(size: 11))
                        .foregroundStyle(focused ? Color.accentColor : .secondary)
                }
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
            }
            .frame(minWidth: 240, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1))

            Button { picking = true } label: { Image(systemName: "list.bullet") }
                .help("Choose from all keys, including media keys and keys your keyboard doesn’t have")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    KeyPicker { key in
                        combo.key = key
                        picking = false
                    }
                }
        }
    }

    private var modifierToggles: some View {
            HStack(spacing: 4) {
                ForEach(Self.modifierToggles, id: \.1) { mod, symbol in
                    Toggle(symbol, isOn: Binding(
                        get: { combo.modifiers.contains(mod) },
                        set: { on in if on { combo.modifiers.insert(mod) } else { combo.modifiers.remove(mod) } }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
    }

    static let modifierToggles: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"),
                                                          (.command, "⌘"), (.function, "fn")]
}

/// Searchable list of every key the remapper knows.
struct KeyPicker: View {
    var onPick: (Key) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search keys", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List {
                ForEach(KeyCatalog.groups) { group in
                    let keys = group.keys.filter(matches)
                    if !keys.isEmpty {
                        Section(group.id) {
                            ForEach(keys, id: \.self) { key in
                                Button { onPick(key) } label: {
                                    HStack {
                                        Text(key.name)
                                        Spacer()
                                        Text(key.kind == .media ? "media" : "\(key.code)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 300, height: 380)
    }

    private func matches(_ key: Key) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || key.name.lowercased().contains(q) || key.keycaps.joined(separator: " ").lowercased().contains(q)
    }
}
