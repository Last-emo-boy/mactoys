import MacToysCore
import SwiftUI

struct CropAndLockSettingsView: View {
    let module: CropAndLockModule

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .teal) {
                CropHero(module: module, counter: module.openCrops)
            }
        } content: {
            Section("Shortcuts") {
                ShortcutRow("Thumbnail shortcut", subtitle: "Select an area of the focused window and keep a live view of it",
                            shortcut: $s.value.thumbnail)
                ShortcutRow("Interactive shortcut",
                            subtitle: "Like a thumbnail, but clicking it brings the original window forward with that area under the pointer",
                            shortcut: $s.value.interactive)
                ShortcutRow("Screenshot shortcut", subtitle: "Keep a frozen picture of the area you can copy, save or drag",
                            shortcut: $s.value.screenshot)
            }
            Section("Crop windows") {
                Toggle(isOn: $s.value.showOnAllSpaces) {
                    RowLabel("Show crop windows on every Space", subtitle: "They stay with you like Picture in Picture, also over full-screen apps")
                }
                Picker(selection: $s.value.frameRate) {
                    ForEach([15, 30, 60], id: \.self) { fps in
                        Text("\(fps) fps", comment: "Frame rate: frames per second").tag(fps)
                    }
                } label: {
                    RowLabel("Live frame rate", subtitle: "Higher rates look smoother and use more energy")
                }
            }
            Section("Interactive crops") {
                Toggle(isOn: $s.value.forwardClicks) {
                    RowLabel("Pass the first click on to the app",
                             subtitle: "One click both brings the window forward and presses what you clicked")
                }
                Toggle(isOn: $s.value.restorePosition) {
                    RowLabel("Move the original window back when the crop closes")
                }
                InfoBar(.info, title: "How interactive crops work on a Mac",
                        message: "macOS can't place one app's window inside another. When you click an interactive crop, the original window moves so the cropped area sits exactly under the crop and comes to the front; when you switch away, the crop returns.")
            }
        }
    }
}

private struct CropHero: View {
    let module: CropAndLockModule
    let counter: CropCounter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                card(.thumbnail, "Live view of the area. Resize it freely; it keeps its proportions.",
                     module.settings.value.thumbnail)
                card(.interactive, "Live view you can click through to use the original window.",
                     module.settings.value.interactive)
                card(.screenshot, "A frozen picture to copy, save or drag into another app.",
                     module.settings.value.screenshot)
            }
            HStack(spacing: 10) {
                (counter.count == 0 ? Text("No crop windows open") : Text("\(counter.count) crop windows open"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if counter.count > 0 {
                    Button("Close All Crops") { module.closeAll() }
                }
            }
        }
    }

    private func card(_ mode: CropMode, _ text: LocalizedStringKey, _ shortcut: Shortcut?) -> some View {
        Button {
            module.begin(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ModuleIcon(symbol: mode.symbol, tint: .teal, size: 26)
                    Spacer()
                    Keycaps(shortcut)
                }
                Text(verbatim: mode.title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.help)
    }
}
