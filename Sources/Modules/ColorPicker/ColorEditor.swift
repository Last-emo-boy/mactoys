import AppKit
import MacToysCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// State behind the editor window: the color being looked at and what to do on actions.
@MainActor
@Observable
final class ColorEditorModel {
    let history: ColorHistory
    let settings: Persisted<ColorPickerSettings>
    /// The color whose formats are shown; adjusting edits it, picking or selecting replaces it.
    var current: ColorValue
    var showAdjust = false
    @ObservationIgnored var onPick: () -> Void = {}
    @ObservationIgnored var onCopy: (String) -> Void = { _ in }

    init(history: ColorHistory, settings: Persisted<ColorPickerSettings>) {
        self.history = history
        self.settings = settings
        self.current = history.colors.first ?? ColorValue(red: 255, green: 95, blue: 74)
    }

    var visibleFormats: [ColorFormat] { settings.value.formats.filter(\.enabled) }

    func value(_ format: ColorFormat) -> String { ColorFormatter.format(current, format.format) }

    func select(_ color: ColorValue) { current = color }

    /// Selects a shade and records it, as PowerToys does for similar colors.
    func choose(_ color: ColorValue) {
        current = color
        history.add(color)
    }

    func copy(_ format: ColorFormat) { onCopy(value(format)) }

    /// Plain-text export of the history: one block per color, one line per enabled format.
    func exportText() -> String {
        history.colors.map { c in
            visibleFormats.map { "\($0.name): \(ColorFormatter.format(c, $0.format))" }.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }
}

/// Design 06 editor: history column, shade bar, every enabled format with a copy button.
struct ColorEditorView: View {
    @Bindable var model: ColorEditorModel

    var body: some View {
        HStack(spacing: 0) {
            historyColumn
            VStack(alignment: .leading, spacing: 12) {
                header
                ShadeBar(model: model)
                formats
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .background(Color(red: 0.125, green: 0.125, blue: 0.145))
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var historyColumn: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(model.history.colors, id: \.self) { c in
                        HistorySwatch(color: c, selected: c == model.current)
                            .onTapGesture { model.select(c) }
                            .contextMenu {
                                Button("Copy \(model.settings.value.copyFormat.name)") {
                                    model.select(c)
                                    model.copy(model.settings.value.copyFormat)
                                }
                                Button("Remove") { model.history.remove(c) }
                                Divider()
                                Button("Clear History") { model.history.clear() }
                            }
                            .help(c.hex)
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Button(action: model.onPick) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 46, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Pick a color from the screen")
        }
        .padding(.top, 40)
        .padding(.bottom, 14)
        .frame(width: 72)
        .background(Color.black.opacity(0.22))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.settings.value.showColorName {
                Text(ColorNames.name(for: model.current)).font(.system(size: 13, weight: .semibold))
            }
            Text(model.current.hex).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button { model.showAdjust.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("Adjust color")
                .popover(isPresented: $model.showAdjust, arrowEdge: .bottom) { AdjustPanel(model: model) }
            Menu {
                Button("Export History…", action: exportHistory).disabled(model.history.colors.isEmpty)
                Button("Clear History") { model.history.clear() }.disabled(model.history.colors.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .frame(height: 22)
    }

    private var formats: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                let list = model.visibleFormats
                ForEach(Array(list.enumerated()), id: \.element.id) { i, f in
                    FormatRow(name: f.name, value: model.value(f)) { model.copy(f) }
                    if i < list.count - 1 { Divider().opacity(0.5) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.045)))
        }
        .scrollIndicators(.never)
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Colors.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do { try model.exportText().write(to: url, atomically: true, encoding: .utf8) }
                catch { Log.for("colorpicker").error("Export failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}

struct HistorySwatch: View {
    let color: ColorValue
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.rgba.color)
            .frame(width: 46, height: 42)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.08), lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
    }
}

/// Five shades, darkest first; the middle one is the current color and opens the adjust panel.
struct ShadeBar: View {
    @Bindable var model: ColorEditorModel

    var body: some View {
        let shades = ColorMath.shades(of: model.current)
        HStack(spacing: 0) {
            ForEach(Array(shades.enumerated()), id: \.offset) { i, c in
                Rectangle()
                    .fill(c.rgba.color)
                    .overlay {
                        if i == 2 {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ColorMath.hsl(c).lightness > 0.6 ? Color.black.opacity(0.45) : .white.opacity(0.7))
                                .opacity(0.9)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if i == 2 { model.showAdjust = true } else { model.choose(c) } }
                    .help(i == 2 ? "Adjust" : c.hex)
            }
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct FormatRow: View {
    let name: String
    let value: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            Button {
                copy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5))
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Copy \(name)")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

/// Hue / saturation / brightness sliders, hex entry and the system color panel.
struct AdjustPanel: View {
    @Bindable var model: ColorEditorModel
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hex = ""
    @State private var panelBridge = ColorPanelBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 6).fill(model.current.rgba.color).frame(width: 34, height: 34)
                TextField("Hex", text: $hex)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { if let c = ColorValue(hex: hex) { model.current = c; load() } }
                Spacer()
            }
            slider("Hue", value: $hue, range: 0...360, suffix: "°")
            slider("Saturation", value: $saturation, range: 0...100, suffix: "%")
            slider("Brightness", value: $brightness, range: 0...100, suffix: "%")
            HStack {
                Button("Color Panel…") {
                    panelBridge.open(with: model.current) { c in model.current = c; load() }
                }
                Spacer()
                Button("Add to History") {
                    model.history.add(model.current)
                    model.showAdjust = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear(perform: load)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; apply() }), in: range)
        }
    }

    private func load() {
        let hsv = ColorMath.hsv(model.current)
        hue = hsv.hue
        saturation = hsv.saturation * 100
        brightness = hsv.value * 100
        hex = model.current.hex
    }

    private func apply() {
        model.current = ColorMath.fromHSV(hue: hue, saturation: saturation / 100, value: brightness / 100)
        hex = model.current.hex
    }
}

/// Bridges `NSColorPanel`'s target/action to a closure.
@MainActor
final class ColorPanelBridge: NSObject {
    private var onChange: ((ColorValue) -> Void)?

    func open(with color: ColorValue, onChange: @escaping (ColorValue) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = color.rgba.nsColor
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(ColorValue(RGBA(sender.color)))
    }
}

/// The editor window. Created on first use; closing it only hides it.
@MainActor
final class ColorEditorWindow: NSObject, NSWindowDelegate {
    let model: ColorEditorModel
    private var window: NSWindow?

    init(model: ColorEditorModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(selecting color: ColorValue? = nil) {
        if let color { model.current = color }
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 580, height: 420),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Color Picker"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 460, height: 340)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            w.contentView = NSHostingView(rootView: ColorEditorView(model: model))
            w.setFrameAutosaveName("MacToysColorEditor")
            if w.frame.origin == .zero { w.center() }
            w.delegate = self
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Hides without forgetting the position (while picking from the editor).
    func hide() { window?.orderOut(nil) }

    func close() {
        model.showAdjust = false
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.showAdjust = false
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.orderOut(nil) }
    }
}
