import MacToysCore
import SwiftUI

/// The FancyZones settings page (design 03), grouped like PowerToys.
struct FancyZonesSettingsView: View {
    let module: FancyZonesModule

    var body: some View {
        @Bindable var s = module.settings
        let v = s.value
        SettingsPage(module: module) {
            FancyZonesHero(module: module)
        } content: {
            Section("Zone activation") {
                Toggle(isOn: $s.value.holdShiftToActivate) { RowLabel(title: Text("Hold ⇧ to activate zones while dragging"),
                    subtitle: v.holdShiftToActivate ? nil : Text("Zones show as soon as you drag a window; hold ⇧ to drag freely")) }
                Toggle(isOn: $s.value.nonPrimaryButtonToggles) { RowLabel("Use a non-primary mouse button to toggle zones",
                    subtitle: "Right-click while dragging shows or hides zones") }
                Toggle(isOn: $s.value.middleButtonSpansZones) { RowLabel("Use the middle mouse button to span multiple zones",
                    subtitle: "Click it while dragging, like holding ⌘") }
                Toggle(isOn: $s.value.showZonesOnAllDisplays) { RowLabel("Show zones on all displays while dragging") }
                Toggle(isOn: $s.value.spanAcrossDisplays) { RowLabel("Allow zones to span across displays",
                    subtitle: "Treat all displays as one canvas with a single layout") }
                Toggle(isOn: $s.value.mouseWheelSwitchesLayouts) { RowLabel("Scroll while dragging to cycle layouts",
                    subtitle: "Shows the layout name as you switch. Cycles layouts with a quick key, else custom layouts") }
                Picker(selection: $s.value.overlapAlgorithm) {
                    ForEach(OverlapAlgorithm.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { RowLabel("When multiple zones overlap") }
            }

            Section("Zone appearance") {
                Picker(selection: $s.value.zoneColors) {
                    ForEach(FancyZonesSettings.ZoneColors.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { RowLabel("Colors") }
                Group {
                    ColorRow("Highlight color", subtitle: "The zone a window will drop into", color: $s.value.highlightColor)
                    ColorRow("Inactive color", color: $s.value.inactiveColor)
                    ColorRow("Border color", color: $s.value.borderColor)
                    ColorRow("Number color", color: $s.value.numberColor)
                }
                .disabled(v.zoneColors == .system)
                SliderRow("Opacity", value: $s.value.opacity, in: 0...100, step: 5) {
                    ($0 / 100).formatted(.percent.precision(.fractionLength(0)))
                }
                Toggle(isOn: $s.value.showZoneNumber) { RowLabel("Show zone number") }
            }

            Section("Layout name indicator") {
                Toggle(isOn: $s.value.showLayoutName) { RowLabel("Show the layout name when switching layouts",
                    subtitle: "While dragging (mouse wheel) or with a quick layout key") }
                Group {
                    Picker(selection: $s.value.layoutNamePosition) {
                        ForEach(FancyZonesSettings.IndicatorPosition.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    } label: { RowLabel("Position on screen") }
                    ColorRow("Text color", color: $s.value.layoutNameTextColor)
                    ColorRow("Background color", color: $s.value.layoutNameBackground)
                    SliderRow("Text size", value: $s.value.layoutNameTextSize, in: 8...128, step: 1) { "\(Int($0).formatted()) pt" }
                    SliderRow("Padding", value: $s.value.layoutNamePadding, in: 0...64, step: 1) { "\(Int($0).formatted()) pt" }
                    SliderRow("Display duration", value: $s.value.layoutNameDuration, in: 300...10_000, step: 100) {
                        Measurement(value: $0 / 1000, unit: UnitDuration.seconds)
                            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))))
                    }
                }
                .disabled(!v.showLayoutName)
            }

            Section("Window behavior") {
                Toggle(isOn: $s.value.keepWindowsOnDisplayChange) { RowLabel("Keep windows in their zones when displays change",
                    subtitle: "After a resolution, arrangement or Dock size change") }
                Toggle(isOn: $s.value.keepWindowsOnLayoutChange) { RowLabel("Move windows with their zones when the layout changes",
                    subtitle: "Snapped windows keep their zone number in the new layout") }
                Toggle(isOn: $s.value.moveNewWindowsToLastZone) { RowLabel("Move newly created windows to their last known zone") }
                Toggle(isOn: $s.value.moveNewWindowsToActiveDisplay) { RowLabel("Move newly created windows to the current active display",
                    subtitle: "The display under the pointer, when the app has no last known zone") }
                Toggle(isOn: $s.value.restoreSizeOnUnsnap) { RowLabel("Restore the original size of windows when unsnapping") }
                Toggle(isOn: $s.value.allowChildWindows) { RowLabel("Allow dialogs to snap",
                    subtitle: "Child windows such as settings and file dialogs") }
                Toggle(isOn: $s.value.allowPopupWindows) { RowLabel("Allow floating and popup windows to snap",
                    subtitle: "Panels, palettes and other non-standard windows") }
                Toggle(isOn: .constant(false)) { RowLabel("Make the dragged window transparent",
                    subtitle: "Not available on macOS: an app can't change the transparency of another app's windows") }
                    .disabled(true)
            }

            Section("Keyboard") {
                Toggle(isOn: $s.value.moveWithKeyboard) { RowLabel("Move windows between zones with the keyboard") }
                Group {
                    Picker(selection: $s.value.moveMode) {
                        ForEach(FancyZonesSettings.MoveMode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    } label: {
                        RowLabel(title: Text("Move windows based on"), subtitle: v.moveMode == .zoneIndex
                                 ? Text("← and → step through zone numbers; ↑ and ↓ stay with the app")
                                 : Text("Arrows pick the nearest zone in that direction; ⌃⌥⇧ arrows extend over several zones"))
                    }
                    Toggle(isOn: $s.value.moveAcrossDisplays) { RowLabel("Move windows between zones across all displays") }
                    Toggle(isOn: $s.value.wrapAround) { RowLabel("Wrap around to the first zone after the last") }
                    ShortcutRow("Move to the zone on the left", shortcut: $s.value.moveLeft)
                    ShortcutRow("Move to the zone on the right", shortcut: $s.value.moveRight)
                    Group {
                        ShortcutRow("Move to the zone above", shortcut: $s.value.moveUp)
                        ShortcutRow("Move to the zone below", shortcut: $s.value.moveDown)
                        ShortcutRow("Extend to the left", shortcut: $s.value.extendLeft)
                        ShortcutRow("Extend to the right", shortcut: $s.value.extendRight)
                        ShortcutRow("Extend up", shortcut: $s.value.extendUp)
                        ShortcutRow("Extend down", shortcut: $s.value.extendDown)
                    }
                    .disabled(v.moveMode != .relativePosition)
                }
                .disabled(!v.moveWithKeyboard)
                Toggle(isOn: $s.value.switchWindowsInZone) { RowLabel("Switch between windows in the current zone") }
                Group {
                    ShortcutRow("Next window", shortcut: $s.value.nextWindowShortcut)
                    ShortcutRow("Previous window", shortcut: $s.value.previousWindowShortcut)
                }
                .disabled(!v.switchWindowsInZone)
            }

            Section("Layouts") {
                ShortcutRow("Open layout editor", shortcut: $s.value.editorShortcut)
                Picker(selection: $s.value.editorDisplay) {
                    ForEach(FancyZonesSettings.EditorDisplay.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { RowLabel("Open the editor on") }
                Toggle(isOn: $s.value.quickLayoutSwitch) {
                    RowLabel(title: Text("Enable quick layout switch"), subtitle: Text(verbatim: quickKeysSummary))
                }
                Toggle(isOn: $s.value.flashZonesOnLayoutSwitch) { RowLabel("Flash zones when switching layout") }
                layoutPicker("Default layout for horizontal displays", selection: $s.value.defaultHorizontalLayout)
                layoutPicker("Default layout for vertical displays", selection: $s.value.defaultVerticalLayout)
            }

            Section("Excluded apps") {
                ExcludedAppsEditor("Exclude apps from snapping to zones", apps: $s.value.excludedApps)
            }
        }
    }

    private var quickKeysSummary: String {
        let keyed = module.layouts.value.all.filter { $0.quickKey != nil }.sorted { ($0.quickKey ?? 0) < ($1.quickKey ?? 0) }
        guard !keyed.isEmpty else { return String(localized: "Assign ⌃⌥⇧ number keys to layouts in the editor") }
        return keyed.map { "⌃⌥⇧\($0.quickKey ?? 0) \($0.displayName)" }.joined(separator: " · ")
    }

    private func layoutPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(module.layouts.value.all.filter { $0.kind != .blank }) { Text(verbatim: $0.displayName).tag($0.id) }
        } label: { RowLabel(title, subtitle: "Used by displays you haven't picked a layout for") }
    }
}

/// Hero card: the main display's layout with template shortcuts and the editor button.
private struct FancyZonesHero: View {
    let module: FancyZonesModule

    var body: some View {
        let lib = module.layouts.value
        let display = module.engine.displays.first
        let current = display.map { module.engine.layout(for: $0) }
        let reference = display?.workArea.size ?? CGSize(width: 1512, height: 945)
        HeroCard(tint: .blue) {
            HStack(alignment: .center, spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(lib.templates.filter { [.columns, .rows, .grid, .priorityGrid].contains($0.kind) }) { t in
                        let on = current?.id == t.id
                        Button {
                            if let display { module.engine.apply(t, to: display, announce: true) }
                        } label: {
                            VStack(spacing: 6) {
                                LayoutThumbnail(layout: t, reference: reference, selected: on,
                                                fill: Color.primary.opacity(0.07), selectedFill: Color.accentColor.opacity(0.35),
                                                stroke: .primary)
                                    .frame(width: 84, height: 54)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor)))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: on ? 2 : 1))
                                (t.kind == .priorityGrid
                                    ? Text("Priority", comment: "Short name of the Priority Grid layout template, under its thumbnail")
                                    : Text(verbatim: t.displayName))
                                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.accentColor : .secondary)
                                    .fixedSize()
                            }
                        }
                        .buttonStyle(.plain)
                        .help(Text("Apply \(t.displayName)", comment: "Tooltip: apply the layout template with this name"))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    title(layout: current?.displayName ?? ZoneLayout.Kind.blank.title, display: display?.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Each display keeps its own layout. Custom canvas and grid layouts are made in the editor.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Launch layout editor") { module.openEditor() }
                            .buttonStyle(.borderedProminent)
                        Keycaps(module.settings.value.editorShortcut)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func title(layout: String, display: String?) -> Text {
        if let display {
            Text("\(layout) on \(display)", comment: "FancyZones: a layout name, then the name of the display that uses it")
        } else {
            Text("\(layout) on this display", comment: "FancyZones: a layout name")
        }
    }
}
