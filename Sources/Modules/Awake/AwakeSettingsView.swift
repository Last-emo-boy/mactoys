import MacToysCore
import SwiftUI

struct AwakeSettingsView: View {
    let module: AwakeModule
    @Bindable var s: Persisted<AwakeSettings>
    @State private var newPresetName = ""
    @State private var newPresetMinutes = 240

    init(module: AwakeModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            hero
        } content: {
            Section("Behavior") {
                Picker(selection: Binding(get: { s.value.mode }, set: { module.select($0) })) {
                    ForEach(AwakeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    RowLabel("Mode", subtitle: "Awake never changes your Energy settings; it only asks macOS not to sleep while a mode is on.")
                }
                .pickerStyle(.radioGroup)

                if s.value.mode == .timed || s.value.mode == .off {
                    LabeledContent {
                        HStack(spacing: 4) {
                            Text(Duration.seconds(s.value.intervalHours * 3600).formatted(.units(allowed: [.hours], width: .abbreviated)))
                                .monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                            Stepper("Hours", value: Binding(get: { s.value.intervalHours },
                                                            set: { module.setInterval(hours: $0, minutes: s.value.intervalMinutes) }),
                                    in: 0...999)
                                .labelsHidden()
                            Text(Duration.seconds(s.value.intervalMinutes * 60).formatted(.units(allowed: [.minutes], width: .abbreviated)))
                                .monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                            Stepper("Minutes", value: Binding(get: { s.value.intervalMinutes },
                                                              set: { module.setInterval(hours: s.value.intervalHours, minutes: $0) }),
                                    in: 0...59, step: 5)
                                .labelsHidden()
                        }
                    } label: {
                        RowLabel("Interval", subtitle: "Changing the interval while a timed session runs restarts its timer.")
                    }
                }
                if s.value.mode == .until || s.value.mode == .off {
                    DatePicker(selection: Binding(get: { s.value.untilDate }, set: { module.setUntilDate($0) }),
                               in: Date()..., displayedComponents: [.date, .hourAndMinute]) {
                        RowLabel("Keep awake until", subtitle: "Awake returns to Off at this date and time.")
                    }
                }
            }

            Section("Screen") {
                Toggle(isOn: $s.value.keepScreenOn) {
                    RowLabel("Keep screen on", subtitle: "Without this the displays may still turn off while the Mac stays awake.")
                }
                Toggle(isOn: $s.value.allowDisplaySleepWhenLocked) {
                    RowLabel("Allow display sleep when locked",
                             subtitle: "While the screen is locked only the Mac is kept awake; the displays follow your Lock Screen settings. Turning the screen back on resumes on unlock.")
                }
                .disabled(!s.value.keepScreenOn)
            }

            Section("Menu bar") {
                Toggle(isOn: $s.value.showMenuBarIcon) {
                    RowLabel("Show Awake in the menu bar", subtitle: "A cup that shows the current mode, with the Awake menu.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel("Extra durations", subtitle: "Added to the menu after 30 minutes, 1 hour and 2 hours.")
                    ForEach(s.value.customPresets) { preset in
                        HStack {
                            Text("Keep awake for \(preset.name)", comment: "Awake menu item; the placeholder is a duration, e.g. '1 hour'")
                            Spacer()
                            Text(AwakeSchedule.displayDuration(TimeInterval(preset.seconds))).foregroundStyle(.secondary)
                            Button {
                                s.value.customPresets.removeAll { $0 == preset }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(Text("Remove", comment: "Help tag: remove this extra duration"))
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Name, e.g. 4 hours", text: $newPresetName).frame(maxWidth: 180)
                        Text(AwakeSchedule.displayDuration(TimeInterval(newPresetMinutes * 60)))
                            .monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                        Stepper("Duration", value: $newPresetMinutes, in: 5...(60 * 72), step: 15).labelsHidden()
                        Button("Add") {
                            let seconds = newPresetMinutes * 60
                            let trimmed = newPresetName.trimmingCharacters(in: .whitespaces)
                            let name = trimmed.isEmpty ? AwakeSchedule.displayDuration(TimeInterval(seconds)) : trimmed
                            s.value.customPresets.append(AwakePreset(name: name, seconds: seconds))
                            newPresetName = ""
                        }
                    }
                }
            }
        }
    }

    private var hero: some View {
        HeroCard(tint: .orange) {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                HStack(spacing: 14) {
                    Image(nsImage: AwakeIcon.image(for: s.value.mode))
                        .renderingMode(.template)
                        .foregroundStyle(module.isAwake ? Tint.orange.color : .secondary)
                        .scaleEffect(1.6)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        (module.isAwake ? Text("Keeping this Mac awake") : Text("Following your Energy settings"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(module.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if module.isAwake {
                        Button("Turn Off") { module.turnOff() }
                    } else {
                        Button("Keep Awake") { module.toggle() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}
