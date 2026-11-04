import AppKit
import MacToysCore
import SwiftUI

struct ScreenshotSettingsView: View {
    let module: ScreenshotModule
    @Bindable var settings: Persisted<ScreenshotSettings>
    @State private var confirmClear = false

    var body: some View {
        SettingsPage(module: module, hero: { hero }) {
            shortcutsSection
            captureSection
            windowSection
            afterCaptureSection
            overlaySection
            outputSection
            annotateSection
            backgroundSection
            historySection
        }
        .confirmationDialog(Text("Delete every capture in the history?", comment: "Capture history: confirm clearing"),
                            isPresented: $confirmClear) {
            Button(role: .destructive) { module.history.clear() } label: { Text("Delete All", comment: "Capture history: confirm clearing") }
        } message: {
            Text("Files you saved stay where they are.", comment: "Capture history: what clearing keeps")
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroCard(tint: .pink) {
            HStack(alignment: .center, spacing: 20) {
                ScreenshotHeroArt(settings: settings.value)
                    .frame(width: 268, height: 168)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Capture, mark up, share", comment: "Screenshot settings hero title").font(.headline)
                    Text("Select an area, a window or a whole screen. Each capture lands on a card you can copy, save, annotate, pin or drag into any app.",
                         comment: "Screenshot settings hero text")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { module.captureArea() } label: { Text("Capture Area", comment: "Screenshot hero button") }
                            .buttonStyle(.borderedProminent)
                        if let s = settings.value.areaShortcut { Keycaps(s) }
                        Button { module.captureWindow() } label: { Text("Window", comment: "Screenshot hero button: capture a window") }
                        Button { module.showHistory() } label: { Text("History", comment: "Screenshot hero button: open the capture history") }
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sections

    private var shortcutsSection: some View {
        Section {
            ShortcutRow("Capture area", subtitle: "Drag over the screen. ⇧ square, ⌥ from the center, hold Space to move, arrows nudge.",
                        shortcut: $settings.value.areaShortcut)
            ShortcutRow("Capture window", subtitle: "Click the highlighted window. Space switches between area and window.",
                        shortcut: $settings.value.windowShortcut)
            ShortcutRow("Capture screen", shortcut: $settings.value.screenShortcut)
            ShortcutRow("Capture the previous area", subtitle: "Takes the last area again, without selecting.",
                        shortcut: $settings.value.previousAreaShortcut)
            ShortcutRow("Open capture history", shortcut: $settings.value.historyShortcut)
            InfoBar(.info, title: Text("Want ⌘⇧3, ⌘⇧4 or ⌘⇧5?", comment: "Screenshot settings: using the macOS screenshot keys"),
                    message: Text("Turn off the macOS screenshot shortcuts in System Settings › Keyboard › Keyboard Shortcuts › Screenshots, then record them above.",
                                  comment: "Screenshot settings: how to free the macOS screenshot keys"),
                    actionTitle: Text("Keyboard Shortcuts…", comment: "Button: open the Keyboard Shortcuts settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } header: {
            Text("Shortcuts", comment: "Settings section")
        }
    }

    private var captureSection: some View {
        Section {
            Toggle(isOn: $settings.value.showMagnifier) {
                RowLabel("Show the magnifier", subtitle: "Zoomed pixels next to the crosshair for exact edges.")
            }
            Toggle(isOn: $settings.value.showCrosshair) { RowLabel("Show crosshair lines across the screen") }
            Toggle(isOn: $settings.value.freezeScreen) {
                RowLabel("Freeze the screen while selecting", subtitle: "Catches menus, tooltips and video frames as they were.")
            }
            Toggle(isOn: $settings.value.rememberLastArea) {
                RowLabel("Start with the previous area", subtitle: "It's selected already: press ↩ to take it again, or drag a new one.")
            }
            Toggle(isOn: $settings.value.hideDesktopIcons) {
                RowLabel("Hide desktop icons in captures", subtitle: "Files on the desktop stay out of screen and area shots.")
            }
            Toggle(isOn: $settings.value.includePointer) { RowLabel("Include the pointer in window and screen captures") }
            Picker(selection: $settings.value.selfTimer) {
                Text("Off", comment: "Self-timer: capture right away").tag(0)
                ForEach([3, 5, 10], id: \.self) { n in
                    Text(Duration.seconds(n).formatted(.units(allowed: [.seconds], width: .wide))).tag(n)
                }
            } label: {
                RowLabel(title: Text("Self-timer", comment: "Screenshot settings: delay before capturing"),
                         subtitle: Text("Wait before capturing, to set up hover states and menus."))
            }
            Picker(selection: $settings.value.screenTarget) {
                ForEach(ScreenTarget.allCases) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Capture Screen takes")
            }
        } header: {
            Text("Capture", comment: "Settings section")
        }
    }

    private var windowSection: some View {
        Section {
            Toggle(isOn: $settings.value.windowShadow) { RowLabel("Keep the window shadow") }
            SliderRow("Transparent padding", value: $settings.value.windowPadding, in: 0...120, step: 4,
                      format: { BeautifyPanel.points($0) })
        } header: {
            Text("Window captures", comment: "Settings section")
        } footer: {
            Text("Window captures have transparent corners. With a background frame (below), shadow and padding come from the frame instead.",
                 comment: "Screenshot settings: window capture footer")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var afterCaptureSection: some View {
        Section {
            Toggle(isOn: $settings.value.showQuickAccess) {
                RowLabel("Show the Quick Access card", subtitle: "Copy, save, annotate, pin or drag the capture from a card in the corner.")
            }
            Toggle(isOn: $settings.value.saveToFile) { RowLabel("Save to a file") }
            Toggle(isOn: $settings.value.copyToClipboard) { RowLabel("Copy to the clipboard") }
            Toggle(isOn: $settings.value.openAnnotate) { RowLabel("Open the annotate window") }
            Toggle(isOn: $settings.value.pinToScreen) { RowLabel("Pin to the screen") }
            Picker(selection: $settings.value.autoBeautify) {
                ForEach(AutoBeautify.allCases) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Add the background frame", subtitle: "Applies the frame below right away; you can still turn it off while annotating.")
            }
            Toggle(isOn: $settings.value.playSound) { RowLabel("Play the shutter sound") }
        } header: {
            Text("After capture", comment: "Settings section")
        }
    }

    private var overlaySection: some View {
        Section {
            Picker(selection: $settings.value.overlayCorner) {
                ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel(title: Text("Position", comment: "Quick Access card position setting")) }
            Picker(selection: $settings.value.overlaySize) {
                ForEach(OverlaySize.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel(title: Text("Size", comment: "Quick Access card size setting")) }
            Picker(selection: $settings.value.autoCloseSeconds) {
                Text("Never", comment: "Quick Access cards: don't close by themselves").tag(0)
                ForEach([5, 10, 20, 30, 60], id: \.self) { n in
                    Text(Duration.seconds(n).formatted(.units(allowed: [.seconds, .minutes], width: .wide))).tag(n)
                }
            } label: {
                RowLabel("Close cards after", subtitle: "Waits while the pointer is over a card. Swipe a card toward the edge to close it.")
            }
        } header: {
            Text("Quick Access card", comment: "Settings section")
        }
    }

    private var outputSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: (settings.value.saveFolderURL.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button { chooseFolder() } label: { Text("Choose…", comment: "Button: pick a folder") }
                }
            } label: {
                RowLabel(title: Text("Save to", comment: "Screenshot settings: folder for saved captures"))
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField(text: $settings.value.fileNameTemplate, prompt: Text(verbatim: FileNamer.defaultTemplate)) {
                            Text("File name", comment: "Screenshot settings: file name template")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        Menu {
                            ForEach(DateTokens.help, id: \.token) { entry in
                                Button { settings.value.fileNameTemplate += entry.token } label: {
                                    Text(verbatim: "\(entry.token)  \(entry.meaning)")
                                }
                            }
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(Text("Insert a date or time token", comment: "Screenshot settings: file name template menu"))
                    }
                } label: {
                    RowLabel(title: Text("File name", comment: "Screenshot settings: file name template"))
                }
                Text(verbatim: FileNamer.name(template: settings.value.fileNameTemplate, date: Date(), format: settings.value.format))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Picker(selection: $settings.value.format) {
                ForEach(ImageFormat.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: { RowLabel(title: Text("Format", comment: "Screenshot file format setting")) }
            if settings.value.format.isLossy {
                SliderRow(label: RowLabel(title: Text("Quality", comment: "JPEG or HEIC compression quality")),
                          value: $settings.value.jpegQuality, in: 0.4...1, step: 0.05,
                          format: { $0.formatted(.percent.precision(.fractionLength(0))) })
            }
            Picker(selection: $settings.value.retina) {
                Text("Full resolution (Retina)", comment: "Screenshot output scale: the display's native pixels").tag(true)
                Text("Standard (1×)", comment: "Screenshot output scale: one pixel per point").tag(false)
            } label: {
                RowLabel("Resolution", subtitle: "1× halves the pixels on a Retina display: smaller files, softer text.")
            }
        } header: {
            Text("Output", comment: "Settings section")
        }
    }

    private var annotateSection: some View {
        Section {
            LabeledContent {
                ColorSwatches(color: $settings.value.annotationColor)
            } label: {
                RowLabel("Starting color")
            }
            LabeledContent {
                SizePicker(size: $settings.value.annotationSize)
            } label: {
                RowLabel("Starting stroke")
            }
            Toggle(isOn: $settings.value.curvedArrows) { RowLabel("Draw curved arrows") }
            RowLabel(title: Text("Keys in the annotate window", comment: "Screenshot settings: list of annotate keys"),
                     subtitle: Text("V select · A arrow · L line · R rectangle · O ellipse · T text · H highlighter · P pencil · N counter · B blur · X pixelate · S spotlight · C crop · ⇧ straight or square · ⌫ delete · ⌘Z undo · ⌘C copy · ⌘S save · ⌘B background",
                                    comment: "Single capital letters are the keys to press; keep them as they are."))
        } header: {
            Text("Annotate", comment: "Settings section")
        }
    }

    private var backgroundSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                RowLabel(title: Text("Background", comment: "Background frame setting: what fills the frame"),
                         subtitle: Text("Used when you add a frame while annotating, and for automatic frames."))
                BackdropGrid(selection: $settings.value.beautify.backdrop)
                    .frame(maxWidth: 380)
            }
            SliderRow(label: RowLabel(title: Text("Padding", comment: "Background frame: space around the screenshot")),
                      value: $settings.value.beautify.padding, in: 0...200, step: 4, format: { BeautifyPanel.points($0) })
            SliderRow("Corner radius", value: $settings.value.beautify.cornerRadius, in: 0...40, step: 1,
                      format: { BeautifyPanel.points($0) })
            SliderRow(label: RowLabel(title: Text("Shadow", comment: "Background frame: shadow under the screenshot")),
                      value: $settings.value.beautify.shadow, in: 0...1, step: 0.05,
                      format: { $0.formatted(.percent.precision(.fractionLength(0))) })
            Picker(selection: $settings.value.beautify.aspect) {
                ForEach(AspectPreset.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: { RowLabel(title: Text("Shape", comment: "Background frame: aspect ratio of the result")) }
            Picker(selection: $settings.value.beautify.alignment) {
                ForEach(BeautifyAlignment.allCases) { Text($0.title).tag($0) }
            } label: {
                RowLabel(title: Text("Position", comment: "Background frame: where the screenshot sits"),
                         subtitle: Text("Where the capture sits when the shape adds room."))
            }
        } header: {
            Text("Background frame", comment: "Settings section")
        }
    }

    private var historySection: some View {
        Section {
            Toggle(isOn: $settings.value.keepHistory) {
                RowLabel("Keep a capture history", subtitle: "Recent captures stay in Application Support, ready to annotate again.")
            }
            Picker(selection: $settings.value.historyLimitMB) {
                ForEach([100, 250, 500, 1000, 2000, 5000], id: \.self) { mb in
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_000_000, countStyle: .file)).tag(mb)
                }
            } label: { RowLabel("Size limit", subtitle: "The oldest captures go first.") }
            Picker(selection: $settings.value.historyMaxAgeDays) {
                ForEach([1, 7, 30, 90], id: \.self) { days in
                    Text(Duration.seconds(days * 86_400).formatted(.units(allowed: [.days, .weeks], width: .wide))).tag(days)
                }
                Text("Until the size limit", comment: "Capture history: no age limit").tag(0)
            } label: { RowLabel("Keep captures for") }
            LabeledContent {
                HStack(spacing: 8) {
                    Button { module.showHistory() } label: { Text("Open History", comment: "Button") }
                    Button(role: .destructive) { confirmClear = true } label: { Text("Clear…", comment: "Button: delete the capture history") }
                }
            } label: {
                let summary = module.historySummary
                RowLabel(title: Text("History", comment: "Screenshot settings row"),
                         subtitle: Text("\(summary.count) captures · \(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))",
                                        comment: "Capture history size: number of captures, then disk space, e.g. 48 captures · 123 MB"))
            }
        } header: {
            Text("History", comment: "Settings section")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.value.saveFolderURL
        panel.prompt = String(localized: "Choose", comment: "Folder picker button")
        panel.message = String(localized: "Choose where screenshots are saved", comment: "Folder picker message")
        if panel.runModal() == .OK, let url = panel.url { settings.value.saveFolder = url.path }
    }
}

/// The hero's live miniature: a framed, annotated capture on the chosen background, with a
/// Quick Access card in the chosen corner.
struct ScreenshotHeroArt: View {
    let settings: ScreenshotSettings

    var body: some View {
        let style = settings.beautify
        let radius = min(CGFloat(style.cornerRadius) * 0.5, 12)
        ZStack {
            BackdropSwatch(backdrop: style.backdrop == .none ? .preset(.graphite) : style.backdrop)
            // The capture.
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) }
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(height: 13)
                .background(Color(white: 0.95))
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5).fill(i == 1 ? Tint.blue.color.opacity(0.5) : Color(white: 0.84))
                                .frame(width: 26, height: 4)
                        }
                    }
                    .padding(6)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(white: 0.965))
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.3)).frame(width: 70, height: 6)
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach([0.45, 0.7, 0.55, 0.9, 0.62, 0.8], id: \.self) { h in
                                RoundedRectangle(cornerRadius: 1.5).fill(Tint.indigo.color.opacity(0.75))
                                    .frame(width: 10, height: 40 * h)
                            }
                        }
                        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.84)).frame(width: 96, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.84)).frame(width: 74, height: 4)
                    }
                    .padding(.vertical, 7)
                    Spacer(minLength: 0)
                }
                .background(Color.white)
            }
            .frame(width: 168, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.4 * style.shadow), radius: 4 + 8 * style.shadow, y: 2 + 4 * style.shadow)
            .overlay(alignment: .topLeading) { annotations }
            .offset(y: -4)
            quickCard
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.08)))
    }

    private var annotations: some View {
        ZStack(alignment: .topLeading) {
            // Highlighted title.
            RoundedRectangle(cornerRadius: 1).fill(Color.yellow.opacity(0.55)).frame(width: 76, height: 9)
                .offset(x: 46, y: 18)
            // An arrow pointing at the tallest bar.
            Path { p in
                p.move(to: CGPoint(x: 150, y: 92))
                p.addQuadCurve(to: CGPoint(x: 110, y: 42), control: CGPoint(x: 150, y: 52))
            }
            .stroke(Color(red: 1, green: 0.23, blue: 0.19), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 104, y: 46)); p.addLine(to: CGPoint(x: 110, y: 41)); p.addLine(to: CGPoint(x: 111, y: 49))
            }
            .stroke(Color(red: 1, green: 0.23, blue: 0.19), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            counter(1).offset(x: 34, y: 28)
            counter(2).offset(x: 118, y: 74)
        }
        .frame(width: 168, height: 104, alignment: .topLeading)
    }

    private func counter(_ n: Int) -> some View {
        Text(verbatim: "\(n)")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Color(red: 1, green: 0.23, blue: 0.19)))
            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
    }

    private var quickCard: some View {
        let corner = settings.overlayCorner
        let alignment: Alignment = switch corner {
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        }
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(white: 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).padding(4)
            )
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .frame(width: 40, height: 26)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
