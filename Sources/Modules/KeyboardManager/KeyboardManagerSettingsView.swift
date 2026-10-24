import MacToysCore
import SwiftUI

struct KeyboardManagerSettingsView: View {
    let module: KeyboardManagerModule
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            hero
        } content: {
            Section("Profile") {
                Picker(selection: Binding(
                    get: { s.value.profiles.isEmpty ? UUID() : s.value.profiles[s.value.activeProfileIndex].id },
                    set: { s.value.activeProfileID = $0 })) {
                    ForEach(s.value.profiles) { p in Text("\(p.name) · \(p.remaps.count)").tag(p.id) }
                } label: {
                    RowLabel("Active profile", subtitle: "Each profile is a complete set of remaps. Switch with mactoys://keyboardmanager/profile?name=…")
                }
                if renaming {
                    HStack {
                        TextField("Profile name", text: $newName).onSubmit(commitRename)
                        Button("Rename", action: commitRename).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { renaming = false }
                    }
                }
                HStack {
                    Button("New") { addProfile(copying: false) }
                    Button("Duplicate") { addProfile(copying: true) }
                    Button("Rename…") {
                        newName = module.activeProfileName
                        renaming = true
                    }
                    Button("Delete", role: .destructive, action: deleteProfile).disabled(s.value.profiles.count <= 1)
                    Spacer()
                    Button("Import…") { module.importProfile() }
                    Button("Export…") { module.exportProfile() }
                }
            }
            Section("Remapping") {
                Toggle(isOn: $s.value.paused) {
                    RowLabel("Pause remapping", subtitle: "Turn every remap off without disabling Keyboard Manager.")
                }
                Toggle(isOn: $s.value.useSystemKeyMapping) {
                    RowLabel("Apply simple key remaps at the system level",
                             subtitle: "Global key → key remaps go through the macOS key mapping (hidutil): they work everywhere, even in password fields. Your previous mapping is restored when remapping stops. Caps Lock remaps always use it.")
                }
                SliderRow("Tap-alone timeout", subtitle: "Longest press that still counts as a tap.",
                          value: Binding(get: { s.value.tapTimeout * 1000 }, set: { s.value.tapTimeout = $0 / 1000 }),
                          in: 100...1000, step: 25) { "\(Int($0)) ms" }
                SliderRow("Chord timeout", subtitle: "How long a chord waits for its second key.",
                          value: Binding(get: { s.value.chordTimeout * 1000 }, set: { s.value.chordTimeout = $0 / 1000 }),
                          in: 300...3000, step: 100) { "\(Int($0)) ms" }
            }
            Section("Shortcuts") {
                ShortcutRow("Open Keyboard Manager", shortcut: $s.value.openEditorShortcut)
                ShortcutRow("Pause or resume remapping", shortcut: $s.value.toggleShortcut)
            }
            Section("Good to know") {
                Text("Remaps that need the event tap don’t apply in secure text fields (passwords) or at the login window. Keys are matched by position, so remaps keep working when you switch keyboard layouts. App-specific remaps use bundle identifiers and win over global ones.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var hero: some View {
        let remaps = module.settings.value.remaps
        let keys = remaps.filter { $0.kind == .key }.count
        return HeroCard(tint: .orange) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remap keys and shortcuts").font(.headline)
                    Text("\(keys) key remap\(keys == 1 ? "" : "s") and \(remaps.count - keys) shortcut remap\(remaps.count - keys == 1 ? "" : "s") in “\(module.activeProfileName)”. Tap-alone keys, chords, text, apps and URLs are all edited in the Keyboard Manager window.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Manager") { module.openEditor() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(remaps.prefix(3)) { r in
                        HStack(spacing: 6) {
                            Keycaps(r.triggerKeycaps)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(RemapFormatting.actionSummary(r.action)).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func addProfile(copying: Bool) {
        let s = module.settings.value
        let current = s.profiles.isEmpty ? RemapProfile(name: "Default") : s.profiles[s.activeProfileIndex]
        var p = RemapProfile(name: copying ? "\(current.name) copy" : "Profile \(s.profiles.count + 1)")
        if copying {
            p.remaps = current.remaps.map { var r = $0; r.id = UUID(); return r }
        }
        module.settings.update {
            $0.profiles.append(p)
            $0.activeProfileID = p.id
        }
    }

    private func deleteProfile() {
        module.settings.update {
            guard $0.profiles.count > 1 else { return }
            $0.profiles.remove(at: $0.activeProfileIndex)
            $0.activeProfileID = $0.profiles.first?.id
        }
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        module.settings.update { $0.profiles[$0.activeProfileIndex].name = name }
        renaming = false
    }
}
