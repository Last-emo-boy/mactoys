import MacToysCore
import SwiftUI

struct AlwaysOnTopSettingsView: View {
    let module: AlwaysOnTopModule

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .indigo) {
                AlwaysOnTopHero(module: module, list: module.list)
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", subtitle: "Pins or unpins the focused window",
                            shortcut: $s.value.activation)
                Picker(selection: $s.value.raiseTrigger) {
                    ForEach(AlwaysOnTopSettings.RaiseTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Bring a pinned window forward by",
                             subtitle: "While another window is in front, a pinned window shows a live mirror of itself. Point at it or click it to use the real window.")
                }
            }
            Section("Border") {
                Toggle(isOn: $s.value.showBorder) {
                    RowLabel("Show a border around the pinned window")
                }
                Group {
                    Picker(selection: $s.value.colorMode) {
                        ForEach(AlwaysOnTopSettings.ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        RowLabel("Color mode")
                    }
                    if s.value.colorMode == .custom {
                        ColorRow("Color", color: $s.value.customColor, supportsOpacity: false)
                    }
                    SliderRow("Opacity", value: $s.value.opacity, in: 0...100, step: 1) {
                        ($0 / 100).formatted(.percent.precision(.fractionLength(0)))
                    }
                    SliderRow("Thickness", value: $s.value.thickness, in: 1...24, step: 1) { "\(Int($0)) px" }
                    Toggle(isOn: $s.value.roundedCorners) {
                        RowLabel("Enable rounded corners")
                    }
                }
                .disabled(!s.value.showBorder)
            }
            Section("Behavior") {
                Toggle(isOn: $s.value.playSound) {
                    RowLabel("Play a sound when pinning a window")
                }
                Picker(selection: $s.value.frameRate) {
                    ForEach([15, 30, 60], id: \.self) { fps in
                        Text("\(fps) fps", comment: "Frame rate: frames per second").tag(fps)
                    }
                } label: {
                    RowLabel("Mirror frame rate", subtitle: "Higher rates look smoother and use more energy")
                }
            }
            Section("Excluded apps") {
                ExcludedAppsEditor(apps: $s.value.excludedApps)
                Text("Windows of these apps can't be pinned. Partial names match too: “Note” excludes Notes and Notefile.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AlwaysOnTopHero: View {
    let module: AlwaysOnTopModule
    let list: PinList

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            PinIllustration()
                .frame(width: 150, height: 96)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Pin the focused window with", comment: "Followed by the keys of the keyboard shortcut")
                        .font(.system(size: 13, weight: .semibold))
                    Keycaps(module.settings.value.activation)
                }
                Text("macOS doesn't let one app float another app's windows, so a pinned window is kept in front by a live mirror while you work elsewhere. Pointing at it brings the real window forward in place.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if list.items.isEmpty {
                    Text("No windows pinned").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(list.items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "pin.fill").foregroundStyle(Tint.indigo.color).font(.system(size: 11))
                                Text(verbatim: item.title.isEmpty ? item.app : item.title).lineLimit(1)
                                if !item.title.isEmpty {
                                    Text(verbatim: item.app).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button("Unpin") { module.unpin(windowID: item.id) }.controlSize(.small)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Pin Focused Window") { module.toggleFocused() }
                        .buttonStyle(.borderedProminent)
                    if !list.items.isEmpty {
                        Button("Unpin All") { module.unpinAll(feedback: true) }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Small drawing of a pinned window floating over another one, for the hero card.
private struct PinIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .frame(width: 110, height: 72)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 3) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) }
                        }
                        Capsule().fill(.primary.opacity(0.15)).frame(width: 46, height: 4)
                        Capsule().fill(.primary.opacity(0.1)).frame(width: 36, height: 4)
                    }
                    .padding(7)
                }
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .frame(width: 84, height: 60)
                .offset(x: 60, y: 30)
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tint.indigo.color))
                .offset(x: 132, y: 22)
        }
    }
}
