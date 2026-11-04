import AppKit
import MacToysCore
import SwiftUI

/// The Window Gestures settings page: the hero, then every gesture with its action.
struct WindowGesturesSettingsView: View {
    let module: WindowGesturesModule
    @State private var smartZoomOff = TrackpadPreferences.smartZoomOff

    var body: some View {
        @Bindable var s = module.settings
        let v = s.value
        SettingsPage(module: module) {
            VStack(spacing: 0) {
                AutoTilingNotice()
                if !v.active {
                    InfoBar(.info, title: Text("Gestures are paused"),
                            message: Text("Turn them back on here or from the MacToys menu bar flyout."),
                            actionTitle: Text("Resume")) { s.value.active = true }
                        .padding(.bottom, 12)
                }
                GestureHero(settings: v)
            }
        } content: {
            Section {
                Toggle(isOn: $s.value.swipeToHalves) {
                    row(.swipe(.left), "Swipe left or right for half the screen",
                        subtitle: "On a window's title bar or toolbar — scrolling in its content is left alone")
                }
                Toggle(isOn: $s.value.cycleSizes) {
                    row(.swipeAgain(.left), "Swipe again for thirds",
                        subtitle: "Toward the same edge: ⅓, ⅔, then ½ again. The other way slides a third to the center.")
                }
                .disabled(!v.swipeToHalves && !v.cornerSwipes)
                Toggle(isOn: $s.value.cornerSwipes) {
                    row(.corner(.right, .up), "Swipe into a corner for a quarter",
                        subtitle: "Sideways, then up or down. Swipe the same way again for a sixth.")
                }
                Picker(selection: $s.value.swipeUp) {
                    ForEach(WindowGesturesSettings.UpAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { row(.swipe(.up), "Swipe up") }
                Picker(selection: $s.value.swipeDown) {
                    ForEach(WindowGesturesSettings.DownAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { row(.swipe(.down), "Swipe down") }
                Picker(selection: $s.value.displayModifier) {
                    ForEach(WindowGesturesSettings.DisplayModifier.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    row(.swipe(.right), "Swipe while holding a key to change display",
                        subtitle: "The window moves to the display that way, keeping its tile")
                }
            } header: {
                Text("Swipe on a title bar")
            }

            Section("Pinch and tap on a title bar") {
                Picker(selection: $s.value.pinchIn) {
                    ForEach(WindowGesturesSettings.PinchInAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { row(.pinchIn, "Pinch in") }
                Toggle(isOn: $s.value.confirmClose) {
                    RowLabel("Hold the pinch to confirm closing or quitting",
                             subtitle: "A ring fills while you hold; lift early to keep the window")
                }
                .disabled(v.pinchIn != .closeWindow && v.pinchIn != .quitApp)
                SliderRow("Hold for", value: $s.value.confirmHold, in: 0.2...1.5, step: 0.1) {
                    Measurement(value: $0, unit: UnitDuration.seconds)
                        .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))))
                }
                .disabled(!v.confirmClose || (v.pinchIn != .closeWindow && v.pinchIn != .quitApp))
                Picker(selection: $s.value.pinchOut) {
                    ForEach(WindowGesturesSettings.PinchOutAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { row(.pinchOut, "Pinch out") }
                Picker(selection: $s.value.doubleTap) {
                    ForEach(WindowGesturesSettings.DoubleTapAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    row(.doubleTap, "Double-tap with two fingers", subtitle: "Uses the trackpad's Smart zoom gesture")
                }
                if smartZoomOff && v.doubleTap != .nothing {
                    InfoBar(.info, title: Text("Smart zoom is off"),
                            message: Text("Turn on Smart zoom in Trackpad settings › Scroll & Zoom for the double-tap. Elsewhere it zooms as usual."),
                            actionTitle: Text("Open Trackpad Settings…")) { TrackpadPreferences.openSettings() }
                }
            }

            Section("Dock and menu bar") {
                Toggle(isOn: $s.value.dockGestures) {
                    RowLabel("Swipe on an app's Dock icon", subtitle: "Away from the screen edge to show it, toward the edge to put it away")
                }
                Group {
                    Picker(selection: $s.value.dockUp) {
                        ForEach(WindowGesturesSettings.DockUpAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    } label: { row(.swipe(.up), "Swipe up on an icon") }
                    Picker(selection: $s.value.dockDown) {
                        ForEach(WindowGesturesSettings.DockDownAction.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    } label: { row(.swipe(.down), "Swipe down on an icon") }
                }
                .disabled(!v.dockGestures)
                Toggle(isOn: $s.value.menuBarFill) {
                    row(.swipe(.down), "Swipe down on the menu bar to fill the front window")
                }
            }

            Section("Recognition") {
                SliderRow("Sensitivity", subtitle: "Higher reacts to shorter swipes and smaller pinches",
                          value: $s.value.sensitivity, in: 0.5...2, step: 0.25) {
                    $0.formatted(.number.precision(.fractionLength(0...2))) + "×"
                }
                SliderRow("Title bar height", subtitle: "For windows that don't say where their title bar ends",
                          value: $s.value.titleBarHeight, in: 20...80, step: 2) { "\(Int($0).formatted()) pt" }
                Toggle(isOn: $s.value.reverseDirections) {
                    RowLabel("Reverse swipe directions",
                             subtitle: "Swipes follow your fingers whether natural scrolling is on or off; this swaps every direction")
                }
                Toggle(isOn: $s.value.disableInFullScreen) {
                    RowLabel("Leave full-screen apps alone", subtitle: "No gestures on a window that fills its display, such as a game or a video")
                }
            }

            Section("Feedback") {
                Toggle(isOn: $s.value.showPreview) {
                    RowLabel("Show where the window goes", subtitle: "A glass preview of the target appears before you lift your fingers")
                }
                Toggle(isOn: $s.value.haptics) {
                    RowLabel("Haptic feedback", subtitle: "A tap on a Force Touch trackpad when the target changes or the close ring fills")
                }
                SliderRow("Space between tiled windows", value: $s.value.gap, in: 0...24, step: 2) { "\(Int($0).formatted()) pt" }
                LabeledContent {
                    Button("Show Cheat Sheet") { module.showCheatSheet() }
                } label: {
                    RowLabel("Gesture cheat sheet", subtitle: "Every gesture that is on, at a glance")
                }
                ShortcutRow("Cheat sheet shortcut", shortcut: $s.value.cheatSheetShortcut)
            }

            Section("Excluded apps") {
                ExcludedAppsEditor("Apps without gestures", apps: $s.value.excludedApps)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            smartZoomOff = TrackpadPreferences.smartZoomOff
        }
    }

    private func row(_ glyph: GestureGlyph.Kind, _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: 12) {
            GestureGlyph(kind: glyph, width: 38, tint: Tint.cyan.color)
            RowLabel(title, subtitle: subtitle)
        }
    }
}

/// Shown when Auto Tiling arranges a display: gestures don't move windows there.
private struct AutoTilingNotice: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let names = NSScreen.screens.filter { Services.autoTilingManagesDisplay?($0.displayID) == true }
                .map(\.localizedName)
            if !names.isEmpty {
                InfoBar(.info, title: Text("Auto Tiling arranges \(names.formatted(.list(type: .and)))",
                                           comment: "Window Gestures notice: the names of the displays Auto Tiling manages"),
                        message: Text("Gestures there still minimize, close and go full screen, but leave moving and resizing to Auto Tiling."))
                    .padding(.bottom, 12)
            }
        }
    }
}

/// The trackpad's own settings that the gestures depend on.
enum TrackpadPreferences {
    private static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    /// Smart zoom (the two-finger double-tap) is explicitly off for every trackpad.
    static var smartZoomOff: Bool {
        let values = domains.compactMap { d -> Int? in
            CFPreferencesAppSynchronize(d as CFString)
            return (CFPreferencesCopyAppValue("TrackpadTwoFingerDoubleTapGesture" as CFString, d as CFString) as? NSNumber)?.intValue
        }
        return !values.isEmpty && values.allSatisfy { $0 == 0 }
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
