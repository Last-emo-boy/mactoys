import AppKit
import SwiftUI

/// Click to record a shortcut; shows keycaps. Esc cancels, ⌫ clears.
/// Global hotkeys are suspended while recording so the old binding doesn't fire.
public struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var allowsModifierless: Bool
    @State private var recording = false
    @State private var monitor: Any?
    @State private var liveModifiers: Modifiers = []

    public init(shortcut: Binding<Shortcut?>, allowsModifierless: Bool = false) {
        self._shortcut = shortcut
        self.allowsModifierless = allowsModifierless
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Group {
                    if recording {
                        Text(liveModifiers.symbols.isEmpty ? "Type shortcut…" : liveModifiers.symbols.joined(separator: " "))
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 22)
                    } else if let shortcut {
                        Keycaps(shortcut)
                    } else {
                        Text("Record shortcut").foregroundStyle(.secondary).font(.system(size: 12))
                            .padding(.horizontal, 8).frame(minHeight: 22)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotkeyCenter.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                liveModifiers = Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                return nil
            }
            if event.keyCode == 53 { stop(); return nil }                // esc
            if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                shortcut = nil; stop(); return nil                       // delete
            }
            if event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                stop(); return event                                     // tab leaves the field
            }
            guard let s = Shortcut(event: event) else { return nil }
            if s.modifiers.subtracting(.shift).isEmpty && !allowsModifierless && !KeyCodes.isFunctionKey(s.keyCode) {
                NSSound.beep()
                return nil
            }
            shortcut = s
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        liveModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyCenter.shared.isSuspended = false
    }
}
