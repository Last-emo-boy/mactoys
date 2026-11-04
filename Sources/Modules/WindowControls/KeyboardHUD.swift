import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What the keyboard-mode HUD shows.
@MainActor
@Observable
final class KeyboardHUDModel {
    struct NumberedControl: Identifiable, Equatable {
        let number: Int
        let control: WindowControl
        var id: Int { number }
    }

    var appName = ""
    var appIcon: NSImage?
    var windowTitle = ""
    /// The last thing done, shown for a moment under the header.
    var lastAction: String?
    var controls: [NumberedControl] = []
    var showCheatSheet = true
    var multipleDisplays = false
    var canUndo = false
    /// The letter on the key that moves the window to the next display (D on a US layout).
    var displayKey = "D"
}

/// The keyboard-mode cheat sheet: the window being arranged, then every key and what it does.
struct KeyboardHUDView: View {
    let model: KeyboardHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PaletteSurface(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.showCheatSheet {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 9) {
                            sectionTitle(Text("Move and size", comment: "Keyboard mode cheat sheet section"))
                            row(["←", "→", "↑", "↓"], Text("Halves · two in a row for a quarter",
                                                         comment: "Keyboard mode: arrows move the window to screen halves"))
                            row(["⇧", "←→↑↓"], Text("Narrower, wider, shorter, taller",
                                                     comment: "Keyboard mode: shift-arrows resize the window"))
                            row(["⌥", "←→↑↓"], Text("Nudge · add ⇧ for 1 pt", comment: "Keyboard mode: option-arrows move the window a little"))
                            row([String(localized: "Space", comment: "Key name: space bar")], Text("Center", comment: "Keyboard mode: center the window"))
                            row(["↩"], Text("Fill", comment: "Keyboard mode: make the window fill the screen"))
                            if model.multipleDisplays {
                                row([model.displayKey], Text("Next display", comment: "Keyboard mode: move the window to the next display"))
                            }
                            row(["⌫"], Text("Undo", comment: "Keyboard mode: put the window back where it was"))
                                .opacity(model.canUndo ? 1 : 0.45)
                        }
                        .frame(width: 270, alignment: .leading)
                        VStack(alignment: .leading, spacing: 9) {
                            sectionTitle(Text("Custom controls", comment: "Keyboard mode cheat sheet section"))
                            if model.controls.isEmpty {
                                Text("Choose controls for keyboard mode in Settings.",
                                     comment: "Keyboard mode: no custom controls are numbered yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(model.controls) { item in
                                HStack(spacing: 9) {
                                    keycap("\(item.number)")
                                    ControlGlyph(item.control, style: .dark)
                                        .frame(width: 26, height: 17)
                                    Text(verbatim: item.control.displayName)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                }
                            }
                            row(["⇥"], Text("Next window · ⇧ previous", comment: "Keyboard mode: tab arranges another window"))
                                .padding(.top, model.controls.isEmpty ? 0 : 4)
                        }
                        .frame(width: 230, alignment: .leading)
                    }
                }
            }
            .padding(18)
            .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tint.green.gradient)
                Image(systemName: "keyboard").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard mode", comment: "Title of the Window Controls keyboard-mode HUD")
                    .font(.system(size: 14, weight: .semibold))
                ZStack(alignment: .leading) {
                    if let action = model.lastAction {
                        Text(verbatim: action)
                            .foregroundStyle(Color.accentColor.opacity(0.95))
                            .transition(.opacity)
                            .id(action)
                    } else {
                        HStack(spacing: 5) {
                            if let icon = model.appIcon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                            Text(verbatim: model.windowTitle.isEmpty ? model.appName : "\(model.appName) — \(model.windowTitle)")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .transition(.opacity)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.lastAction)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                keycap("esc")
                Text("Done", comment: "Keyboard mode: esc leaves it").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func sectionTitle(_ t: Text) -> some View {
        t.font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
    }

    private func row(_ keys: [String], _ text: Text) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) { ForEach(Array(keys.enumerated()), id: \.offset) { keycap($0.element) } }
                .frame(minWidth: 26, alignment: .leading)
            text.font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
        }
    }

    private func keycap(_ key: String) -> some View {
        Text(verbatim: key)
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 21)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

/// The accent ring drawn around the window keyboard mode arranges.
struct WindowRing: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 5 : 3.5)
            .shadow(color: Color.accentColor.opacity(0.55), radius: 8)
            .padding(6)
    }
}
