import MacToysCore
import SwiftUI

struct MouseUtilitiesSettingsView: View {
    let module: MouseUtilitiesModule
    @State private var permissions = PermissionCenter.shared

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            hero
        } content: {
            findMyMouse($s.value.findMyMouse)
            highlighter($s.value.highlighter)
            mouseJump($s.value.jump)
            crosshairs($s.value.crosshairs)
            cursorWrap($s.value.cursorWrap)
            autoHide($s.value.autoHide)
            buttonLock($s.value.buttonLock)
        }
    }

    private var hero: some View {
        HeroCard(tint: .red) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Seven pointer tools").font(.headline)
                Text("Each one has its own switch below. Highlighter, Crosshairs and CursorWrap also turn on and off from the menu bar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Find My Mouse") { module.findMyMouse.activate() }
                    Button("Mouse Jump") { module.jump.open() }
                    Button(module.highlighter.isActive ? "Highlighter off" : "Highlighter on") { module.highlighter.toggle() }
                    Button(module.crosshairs.isActive ? "Crosshairs off" : "Crosshairs on") { module.crosshairs.toggle() }
                }
                .controlSize(.small)
            }
        }
    }

    private func header(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
    }

    // MARK: - Find My Mouse

    @ViewBuilder
    private func findMyMouse(_ f: Binding<FindMyMouseSettings>) -> some View {
        Section {
            Toggle(isOn: f.enabled) {
                RowLabel("Find My Mouse", subtitle: "A spotlight closes in on the pointer. Click or press a key to dismiss.")
            }
            Group {
                Picker("Activation method", selection: f.activation) {
                    ForEach(FindMyMouseSettings.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch f.wrappedValue.activation {
                case .leftControlTwice, .rightControlTwice:
                    Toggle(isOn: f.requireCommand) { RowLabel("Only while holding ⌘") }
                case .shake:
                    SliderRow("Minimum distance to shake", value: f.shakeMinimumDistance, in: 200...4000, step: 50) { "\(Int($0)) px" }
                    SliderRow("Shake detection interval", value: f.shakeInterval, in: 250...3000, step: 50) { "\(Int($0)) ms" }
                    SliderRow("Shake sensitivity factor", subtitle: "How much back-and-forth counts as a shake. Lower is more sensitive.",
                              value: f.shakeFactor, in: 150...2000, step: 25) { "\(Int($0)) %" }
                case .shortcut:
                    ShortcutRow("Activation shortcut", shortcut: f.shortcut)
                }
                ColorRow("Backdrop color", subtitle: "The alpha sets how dark the rest of the screen gets.", color: f.backdropColor)
                ColorRow("Spotlight color", subtitle: "Use a transparent color to see through the spotlight.", color: f.spotlightColor)
                SliderRow("Spotlight radius", value: f.spotlightRadius, in: 20...400, step: 5) { "\(Int($0)) px" }
                SliderRow("Spotlight initial zoom", value: f.initialZoom, in: 1...20, step: 1) { "\(Int($0))×" }
                SliderRow("Animation duration", value: f.animationDuration, in: 0...3000, step: 50) { "\(Int($0)) ms" }
                Toggle(isOn: f.skipFullScreenApps) {
                    RowLabel("Don’t activate over full-screen apps", subtitle: "Games and videos (macOS has no Game Mode signal for apps).")
                }
                ExcludedAppsEditor(apps: f.excludedApps)
            }
            .disabled(!f.wrappedValue.enabled)
        } header: { header("Find My Mouse", "scope") }
    }

    // MARK: - Highlighter

    @ViewBuilder
    private func highlighter(_ h: Binding<HighlighterSettings>) -> some View {
        Section {
            Toggle(isOn: h.enabled) {
                RowLabel("Mouse Highlighter", subtitle: "Shows your clicks. Turn it on with the shortcut or from the menu bar.")
            }
            Group {
                ShortcutRow("Activation shortcut", shortcut: h.shortcut)
                Toggle(isOn: h.autoActivate) { RowLabel("Turn on automatically when MacToys starts") }
                Picker("Highlight mode", selection: h.mode) {
                    ForEach(HighlighterSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ColorRow("Primary button highlight color", color: h.primaryColor)
                ColorRow("Secondary button highlight color", color: h.secondaryColor)
                switch h.wrappedValue.mode {
                case .spotlight, .circle:
                    ColorRow("Always highlight color",
                             subtitle: h.wrappedValue.mode == .spotlight
                                ? "The dimmed area around the spotlight (50 % black when transparent)."
                                : "A circle that follows the pointer. Transparent turns it off.",
                             color: h.alwaysColor)
                    SliderRow("Radius", value: h.radius, in: 5...200, step: 1) { "\(Int($0)) px" }
                    SliderRow("Fade delay", value: h.fadeDelay, in: 0...3000, step: 50) { "\(Int($0)) ms" }
                    SliderRow("Fade duration", value: h.fadeDuration, in: 0...3000, step: 50) { "\(Int($0)) ms" }
                case .ripple:
                    SliderRow("Size", value: h.rippleSize, in: 10...300, step: 1) { "\(Int($0)) px" }
                    SliderRow("Intensity", value: h.rippleIntensity, in: 0.15...1.35, step: 0.05) { String(format: "%.2f", $0) }
                    SliderRow("Duration", value: h.rippleDuration, in: 60...2000, step: 10) { "\(Int($0)) ms" }
                    Toggle(isOn: h.followCursorWhileHeld) { RowLabel("Follow the pointer while the button is held") }
                    Toggle(isOn: h.rightReleasePulse) { RowLabel("Show crosshairs on right-click release") }
                }
            }
            .disabled(!h.wrappedValue.enabled)
        } header: { header("Mouse Highlighter", "cursorarrow.click.2") }
    }

    // MARK: - Mouse Jump

    @ViewBuilder
    private func mouseJump(_ j: Binding<MouseJumpSettings>) -> some View {
        Section {
            Toggle(isOn: j.enabled) {
                RowLabel("Mouse Jump", subtitle: "A preview of all displays: click to move the pointer there. 1–9 pick a display, ← → cycle, Home/End first/last, P primary.")
            }
            Group {
                ShortcutRow("Activation shortcut", shortcut: j.shortcut)
                SliderRow("Maximum width", value: j.maxWidth, in: 160...4000, step: 10) { "\(Int($0)) px" }
                SliderRow("Maximum height", value: j.maxHeight, in: 120...3000, step: 10) { "\(Int($0)) px" }
                Toggle(isOn: j.liveThumbnails) {
                    RowLabel("Live previews", subtitle: "Shows what’s on each display. Without Screen Recording permission the desktop pictures are used.")
                }
                if j.wrappedValue.liveThumbnails && !permissions.isGranted(.screenRecording) {
                    InfoBar(.info, title: "Screen Recording is off", message: "Mouse Jump shows desktop pictures instead of live previews.",
                            actionTitle: "Grant Access") { permissions.request(.screenRecording) }
                }
                Picker("Preview style", selection: j.style) {
                    ForEach(MouseJumpSettings.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if j.wrappedValue.style == .custom {
                    ColorRow("Background", color: j.customBackground)
                    ColorRow("Border color", color: j.customBorderColor)
                    SliderRow("Border width", value: j.customBorderWidth, in: 0...8, step: 1) { "\(Int($0)) px" }
                    SliderRow("Bezel depth", value: j.customBezel, in: 0...20, step: 1) { "\(Int($0)) px" }
                    SliderRow("Screen margin", value: j.customMargin, in: 0...30, step: 1) { "\(Int($0)) px" }
                    SliderRow("Corner radius", value: j.customCornerRadius, in: 0...20, step: 1) { "\(Int($0)) px" }
                } else {
                    Button("Copy to custom preview style") {
                        let m = MouseJumpModel.metrics(for: j.wrappedValue)
                        j.wrappedValue.customBezel = Double(m.bezel)
                        j.wrappedValue.customMargin = Double(m.margin)
                        j.wrappedValue.style = .custom
                    }
                }
            }
            .disabled(!j.wrappedValue.enabled)
        } header: { header("Mouse Jump", "rectangle.on.rectangle") }
    }

    // MARK: - Crosshairs

    @ViewBuilder
    private func crosshairs(_ c: Binding<CrosshairsSettings>) -> some View {
        Section {
            Toggle(isOn: c.enabled) {
                RowLabel("Mouse Pointer Crosshairs", subtitle: "Lines through the pointer, for presentations and precise work.")
            }
            Group {
                ShortcutRow("Activation shortcut", shortcut: c.shortcut)
                Toggle(isOn: c.autoActivate) { RowLabel("Turn on automatically when MacToys starts") }
                ColorRow("Crosshairs color", color: c.color, supportsOpacity: false)
                SliderRow("Opacity", value: c.opacity, in: 0.05...1, step: 0.05) { "\(Int(($0 * 100).rounded())) %" }
                SliderRow("Center radius", value: c.centerRadius, in: 0...200, step: 1) { "\(Int($0)) px" }
                SliderRow("Thickness", value: c.thickness, in: 1...50, step: 1) { "\(Int($0)) px" }
                ColorRow("Border color", color: c.borderColor, supportsOpacity: false)
                SliderRow("Border size", value: c.borderSize, in: 0...20, step: 1) { "\(Int($0)) px" }
                Picker("Orientation", selection: c.orientation) {
                    ForEach(CrosshairsSettings.Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: c.hideWhenPointerHidden) {
                    RowLabel("Hide the crosshairs when the pointer is hidden", subtitle: "While Auto Hide Cursor has hidden it.")
                }
                Toggle(isOn: c.fixedLength) { RowLabel("Fixed length") }
                if c.wrappedValue.fixedLength {
                    SliderRow("Crosshairs length", value: c.length, in: 1...1000, step: 1) { "\(Int($0)) px" }
                }
                ShortcutRow("Gliding cursor", subtitle: "Press once: a line sweeps across; press again to slow it, again to fix it, then the same for the other direction; the last press clicks. Esc cancels.",
                            shortcut: c.glideShortcut)
                SliderRow("Gliding travel speed", value: c.glideTravelSpeed, in: 5...60, step: 1) { "\(Int($0)) px" }
                SliderRow("Gliding delay speed", subtitle: "The slow sweep for fine positioning.",
                          value: c.glideDelaySpeed, in: 1...60, step: 1) { "\(Int($0)) px" }
            }
            .disabled(!c.wrappedValue.enabled)
        } header: { header("Mouse Pointer Crosshairs", "plus.viewfinder") }
    }

    // MARK: - CursorWrap

    @ViewBuilder
    private func cursorWrap(_ w: Binding<CursorWrapSettings>) -> some View {
        Section {
            Toggle(isOn: w.enabled) {
                RowLabel("CursorWrap", subtitle: "Push the pointer past an outer edge of the desktop and it comes in on the opposite side.")
            }
            Group {
                ShortcutRow("Activation shortcut", shortcut: w.shortcut)
                Toggle(isOn: w.autoActivate) { RowLabel("Turn on automatically when MacToys starts") }
                Toggle(isOn: w.disableWhileDragging) { RowLabel("Don’t wrap while dragging") }
                Picker("Wrap mode", selection: w.mode) {
                    ForEach(CursorWrapSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Wrapping activation", selection: w.activation) {
                    ForEach(CursorWrapSettings.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: w.disableOnSingleMonitor) { RowLabel("Don’t wrap with a single display") }
            }
            .disabled(!w.wrappedValue.enabled)
        } header: { header("CursorWrap", "arrow.left.and.right.square") }
    }

    // MARK: - Auto Hide Cursor

    @ViewBuilder
    private func autoHide(_ a: Binding<AutoHideSettings>) -> some View {
        Section {
            Toggle(isOn: a.enabled) {
                RowLabel("Auto Hide Cursor", subtitle: "Moving the mouse on purpose, clicking or scrolling brings it back.")
            }
            Group {
                Toggle(isOn: a.hideWhileTyping) {
                    RowLabel("Hide after keyboard input", subtitle: "Modifier keys and shortcuts with ⌘ or ⌃ don’t count.")
                }
                Toggle(isOn: a.hideWhenIdle) { RowLabel("Hide after pointer inactivity") }
                if a.wrappedValue.hideWhenIdle {
                    SliderRow("Idle delay", value: a.idleDelay, in: 1...60, step: 1) { "\(Int($0)) s" }
                }
                SliderRow("Ignore movements smaller than", value: a.movementThreshold, in: 0...50, step: 1) { "\(Int($0)) px" }
                if !a.wrappedValue.hideWhileTyping && !a.wrappedValue.hideWhenIdle {
                    InfoBar(.info, title: "Nothing to do", message: "Turn on at least one of the options above.")
                }
            }
            .disabled(!a.wrappedValue.enabled)
        } header: { header("Auto Hide Cursor", "cursorarrow.slash") }
    }

    // MARK: - Mouse Button Lock

    @ViewBuilder
    private func buttonLock(_ b: Binding<ButtonLockSettings>) -> some View {
        Section {
            Toggle(isOn: b.enabled) {
                RowLabel("Mouse Button Lock", subtitle: "Hold a button still to keep it held after you let go; drag, then click any button to release.")
            }
            Group {
                Toggle(isOn: b.left) { RowLabel("Lock the left (primary) button") }
                Toggle(isOn: b.right) {
                    RowLabel("Lock the right button", subtitle: "The context menu that opens is closed when the button locks.")
                }
                Toggle(isOn: b.middle) { RowLabel("Lock the middle button") }
                SliderRow("Hold duration", value: b.holdDuration, in: 200...2200, step: 50) { "\(Int($0)) ms" }
                SliderRow("Drag threshold", subtitle: "Moving farther than this while holding makes it a normal drag.",
                          value: b.dragThreshold, in: 0...100, step: 1) { "\(Int($0)) px" }
            }
            .disabled(!b.wrappedValue.enabled)
        } header: { header("Mouse Button Lock", "lock") }
    }
}
