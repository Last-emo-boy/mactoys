import AppKit
import AVFoundation
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

struct ZoomItSettingsView: View {
    let module: ZoomItModule
    @Bindable var settings: Persisted<ZoomItSettings>

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .red) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Present like a pro").font(.headline)
                        Text("Zoom in, draw, time breaks, record and snip — each with its own shortcut.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Zoom") { module.toggleZoom() }
                    Button { module.draw() } label: { Text("Draw", comment: "Button: start drawing on the screen") }
                    Button { module.toggleBreak() } label: {
                        Text("Break", comment: "Break timer card title: a pause during a presentation")
                    }
                }
            }
        } content: {
            zoomSection
            drawSection
            breakSection
            liveZoomSection
            recordSection
            snipSection
            demoTypeSection
        }
    }

    private var zoomSection: some View {
        Section("Zoom") {
            ShortcutRow("Zoom toggle", subtitle: "Scroll or ↑ ↓ to change the level; click to draw; Esc or right-click to leave.",
                        shortcut: $settings.value.zoomShortcut)
            Toggle(isOn: $settings.value.animateZoom) { RowLabel("Animate zoom in and zoom out") }
            Toggle(isOn: $settings.value.smoothImage) {
                RowLabel("Smooth the zoomed image", subtitle: "Off shows crisp pixels.")
            }
            SliderRow("Initial magnification", value: $settings.value.initialZoom, in: 1.25...4, step: 0.25,
                      format: Self.magnification)
        }
    }

    private var drawSection: some View {
        Section("Draw") {
            ShortcutRow("Draw without zoom", subtitle: "Also starts drawing while zoomed or in Live Zoom.",
                        shortcut: $settings.value.drawShortcut)
            Picker("Pen color", selection: $settings.value.penColor) {
                ForEach(PenColor.allCases) { Text($0.title).tag($0) }
            }
            SliderRow("Pen width", value: $settings.value.penWidth, in: 1...30, step: 1, format: Self.points)
            Toggle(isOn: $settings.value.showToolbar) {
                RowLabel("Show the drawing toolbar", subtitle: "Colors, tools, undo and boards at the top of the screen.")
            }
            Picker(selection: $settings.value.textFont) {
                Text("System", comment: "Text font: the system font").tag("")
                ForEach(Self.fontFamilies, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: {
                RowLabel("Text font", subtitle: "For text typed with T. Scroll or ↑ ↓ while typing to resize.")
            }
            SliderRow("Text size", value: $settings.value.textSize, in: 12...120, step: 2, format: Self.points)
            RowLabel(title: Text("Keys while drawing"),
                     subtitle: Text("R G B Y O P colors (⇧ highlighter) · X blur · hold ⇧ line, ⌃ rectangle, Tab ellipse, ⌃⇧ arrow · T text · ⌘Z undo · E erase all · W whiteboard · K blackboard · Space centers the pointer · ⌘C copy, ⌘S save (⇧ to crop)",
                                    comment: "Single capital letters are the keys to press (R G B Y O P, X, T, E, W, K); keep them. Tab and Space are the keys of that name."))
        }
    }

    private var breakSection: some View {
        Section("Break timer") {
            ShortcutRow("Start break timer", subtitle: "Press again to hide or show it while it keeps running.",
                        shortcut: $settings.value.breakShortcut)
            Stepper(value: $settings.value.breakMinutes, in: 1...99, step: 1) {
                RowLabel(title: Text("Timer", comment: "Break timer length"),
                         subtitle: Text("\(Self.minutes(settings.value.breakMinutes)) · ↑ ↓ adjust while it runs",
                                        comment: "%@ is the break length, e.g. 10 minutes"))
            }
            Toggle(isOn: $settings.value.showElapsedAfterExpiry) { RowLabel("Show time elapsed after expiration") }
            Toggle(isOn: $settings.value.playSoundOnExpiry) { RowLabel("Play sound on expiration") }
            if settings.value.playSoundOnExpiry {
                Picker("Alarm sound", selection: $settings.value.expirySound) {
                    ForEach(Self.systemSounds, id: \.self) { Text(verbatim: $0).tag($0) }
                    if settings.value.expirySound.hasPrefix("/") {
                        Text(verbatim: (settings.value.expirySound as NSString).lastPathComponent).tag(settings.value.expirySound)
                    }
                }
                LabeledContent("Alarm sound file") {
                    Button("Choose…") { choose([.audio]) { settings.value.expirySound = $0 } }
                }
            }
            SliderRow("Timer opacity", value: $settings.value.timerOpacity, in: 0.1...1, step: 0.05,
                      format: { $0.formatted(.percent.precision(.fractionLength(0))) })
            Picker("Timer position", selection: $settings.value.timerPosition) {
                ForEach(TimerPosition.allCases) { Text($0.title).tag($0) }
            }
            Picker(selection: $settings.value.breakBackground) {
                ForEach(BreakBackground.allCases) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Background", subtitle: "Faded and blurred desktops need Screen Recording.")
            }
            if settings.value.breakBackground == .image {
                LabeledContent {
                    HStack {
                        Self.fileName(settings.value.backgroundImagePath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { choose([.image]) { settings.value.backgroundImagePath = $0 } }
                    }
                } label: { RowLabel("Background image file") }
                Toggle(isOn: $settings.value.scaleBackgroundImage) { RowLabel("Scale to screen") }
            }
        }
    }

    private var liveZoomSection: some View {
        Section("Live Zoom") {
            ShortcutRow("Live Zoom toggle", subtitle: "A magnified, live view you can keep working in. ⌃⌥= and ⌃⌥- change the level.",
                        shortcut: $settings.value.liveZoomShortcut)
            SliderRow("Live Zoom magnification", value: $settings.value.liveZoomLevel, in: 1.25...4, step: 0.25,
                      format: Self.magnification)
        }
    }

    private var recordSection: some View {
        Section("Record") {
            ShortcutRow("Record screen", subtitle: "Press again to stop and save.", shortcut: $settings.value.recordShortcut)
            ShortcutRow("Record screen region", shortcut: $settings.value.recordRegionShortcut)
            ShortcutRow("Record window", subtitle: "The window under the pointer.", shortcut: $settings.value.recordWindowShortcut)
            Toggle(isOn: $settings.value.lockRegionTo16x9) { RowLabel("Lock region selection to 16:9") }
            Picker("Format", selection: $settings.value.recordFormat) {
                ForEach(RecordFormat.allCases) { Text($0.title).tag($0) }
            }
            if settings.value.recordFormat != .gif {
                Picker("Video codec", selection: $settings.value.videoCodec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
            }
            SliderRow("Scaling", subtitle: "Of the screen's native resolution.", value: $settings.value.recordScaling,
                      in: 0.1...1, step: 0.05, format: Self.scaling)
            if settings.value.recordFormat == .gif {
                SliderRow("GIF scaling", value: $settings.value.gifScaling, in: 0.1...1, step: 0.05,
                          format: Self.scaling)
            }
            Picker("Frame rate", selection: $settings.value.frameRate) {
                ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Toggle(isOn: $settings.value.recordPointer) { RowLabel("Show the pointer") }
            Toggle(isOn: $settings.value.captureSystemAudio) { RowLabel("Capture system audio") }
            Toggle(isOn: $settings.value.captureMicrophone) { RowLabel("Capture audio input", subtitle: "Needs Microphone access.") }
            if settings.value.captureMicrophone {
                Picker("Microphone", selection: $settings.value.microphoneID) {
                    Text("Default", comment: "Microphone: the system default input").tag("")
                    ForEach(Self.microphones, id: \.uniqueID) { Text(verbatim: $0.localizedName).tag($0.uniqueID) }
                }
                Toggle(isOn: $settings.value.monoMicrophone) { RowLabel(title: Text("Mono", comment: "Audio: one channel"),
                                                                                 subtitle: Text("Mix the microphone to one channel.")) }
            }
        }
    }

    private var snipSection: some View {
        Section("Snip") {
            ShortcutRow("Snip to clipboard", subtitle: "Hold ⇧ when you release to save instead.",
                        shortcut: $settings.value.snipShortcut)
            ShortcutRow("Save snip to file", shortcut: $settings.value.snipSaveShortcut)
            Toggle(isOn: $settings.value.copyWhenSaving) { RowLabel("Copy to clipboard when saving") }
            Toggle(isOn: $settings.value.snipDictation) {
                RowLabel("Snip with dictation",
                         subtitle: "Press Space while dragging and speak. Transcribed on this Mac; the text is pasted with the image.")
            }
            if settings.value.snipDictation {
                Toggle(isOn: $settings.value.dictateEverySnip) { RowLabel("Listen on every snip") }
                LabeledContent {
                    TextField(text: $settings.value.dictationPrefix, prompt: Text("e.g. Note:")) {
                        Text("Text before the dictation")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                } label: { RowLabel("Text before the dictation") }
            }
        }
    }

    private var demoTypeSection: some View {
        Section("DemoType") {
            ShortcutRow("Type next segment", subtitle: "Types into the frontmost app. Esc stops.",
                        shortcut: $settings.value.demoTypeShortcut)
            ShortcutRow("Previous segment", shortcut: $settings.value.demoTypeBackShortcut)
            LabeledContent {
                HStack {
                    Self.fileName(settings.value.demoTypeFile)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { choose([.plainText, .text]) { settings.value.demoTypeFile = $0 } }
                }
            } label: {
                RowLabel(title: Text("Input file"),
                         subtitle: Text("Segments end at [end]. Also: [enter] [up] [down] [left] [right] [pause:n] [paste]…[/paste]. Clipboard text starting with [start] is used instead.",
                                        comment: "Keep the bracketed tags such as [end], [pause:n] and [paste] unchanged: they are DemoType script commands."))
            }
            SliderRow("Typing speed", subtitle: "Larger is faster.", value: $settings.value.typingSpeed, in: 10...100)
            Toggle(isOn: $settings.value.userDriven) {
                RowLabel("Drive input while typing", subtitle: "Each key you press types the next characters; Space ends a segment.")
            }
        }
    }

    // MARK: Helpers

    /// A chosen file's name, or "None".
    private static func fileName(_ path: String) -> Text {
        path.isEmpty ? Text("None", comment: "No file chosen") : Text(verbatim: (path as NSString).lastPathComponent)
    }

    /// "2×", "1.5×" (two significant digits, in the locale's number format).
    private static func magnification(_ v: Double) -> String {
        "\(v.formatted(.number.precision(.significantDigits(1...2))))×"
    }

    private static func points(_ v: Double) -> String { "\(Int(v).formatted()) pt" }

    private static func scaling(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2))) }

    /// "10 minutes", in the user's language.
    private static func minutes(_ m: Double) -> String {
        Duration.seconds(Int(m) * 60).formatted(.units(allowed: [.minutes], width: .wide))
    }

    private func choose(_ types: [UTType], _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { done(url.path) }
        }
    }

    static let systemSounds: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let list = names.map { ($0 as NSString).deletingPathExtension }.sorted()
        return list.isEmpty ? ["Glass"] : list
    }()

    static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}
