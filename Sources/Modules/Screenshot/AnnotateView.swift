import AppKit
import MacToysCore
import SwiftUI

/// The annotate window: tools and palette on top, the canvas, and the background panel on the right.
struct AnnotateView: View {
    @Bindable var model: AnnotateModel
    /// Draw a fake title bar (offscreen previews) instead of using the window toolbar.
    var chrome = false
    static let panelWidth: CGFloat = 284

    var body: some View {
        if chrome {
            HostedToolWindowChrome(title: model.item.title, symbol: "camera.viewfinder", tint: .pink) {
                toolbarButtons
            } content: {
                main
            }
        } else {
            main
                .toolbar {
                    ToolbarItem(placement: .navigation) { ModuleIcon(symbol: "camera.viewfinder", tint: .pink, size: 20) }
                    ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
                }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            ToolStrip(model: model)
            Divider()
            HStack(spacing: 0) {
                canvasArea
                if model.showsBeautify {
                    Divider()
                    BeautifyPanel(model: model)
                        .frame(width: Self.panelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.showsBeautify)
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private var canvasArea: some View {
        ZStack(alignment: .bottom) {
            CanvasBackdrop()
            MarkupCanvas(model: model)
            CanvasFooter(model: model)
                .padding(.bottom, 12)
            if let toast = model.toast {
                Label { Text(verbatim: toast) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.toast)
    }

    @ViewBuilder private var toolbarButtons: some View {
        ControlGroup {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help(Text("Undo (⌘Z)"))
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help(Text("Redo (⇧⌘Z)"))
        }
        Toggle(isOn: Binding(get: { model.document.beautify != nil }, set: { _ in model.toggleBeautify() })) {
            Label { Text("Background", comment: "Annotate toolbar: show the background frame panel") } icon: {
                Image(systemName: "photo.artframe")
            }
        }
        .toggleStyle(.button)
        .help(Text("Background frame (⌘B)", comment: "Annotate toolbar tooltip"))
        Button { model.actions.copyText(model) } label: {
            Label { Text("Copy Text", comment: "Annotate toolbar: recognize and copy the text") } icon: { Image(systemName: "text.viewfinder") }
        }
        .help(Text("Copy the text in the image (⇧⌘C)", comment: "Annotate toolbar tooltip"))
        Button { model.actions.pin(model) } label: {
            Label { Text("Pin", comment: "Annotate toolbar: pin the image to the screen") } icon: { Image(systemName: "pin") }
        }
        .help(Text("Pin to the screen (⇧⌘P)", comment: "Annotate toolbar tooltip"))
        Button { model.actions.share(model, NSApp.keyWindow?.contentView) } label: {
            Label { Text("Share", comment: "Annotate toolbar") } icon: { Image(systemName: "square.and.arrow.up") }
        }
        Button { model.actions.copy(model) } label: { Text("Copy", comment: "Annotate toolbar: copy the finished image") }
            .help(Text("Copy the image (⌘C)", comment: "Annotate toolbar tooltip"))
        Button { model.actions.save(model) } label: { Text("Save", comment: "Annotate toolbar: save the finished image") }
            .buttonStyle(.borderedProminent)
            .help(Text("Save (⌘S) · Save As (⇧⌘S)", comment: "Annotate toolbar tooltip"))
    }
}

/// A quiet dotted surface behind the capture.
struct CanvasBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 18
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var y: CGFloat = 9
            while y < size.height {
                var x: CGFloat = 9
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(scheme == .dark ? 0.09 : 0.08)))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.93))
    }
}

/// Pixel size, zoom and the drag-out handle, floating at the bottom of the canvas.
struct CanvasFooter: View {
    let model: AnnotateModel

    var body: some View {
        let rendered = model.item.rendered
        HStack(spacing: 10) {
            Text(verbatim: "\(rendered.width) × \(rendered.height)")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 12)
            Label {
                Text("Drag", comment: "Annotate: drag the finished image into another app")
            } icon: {
                Image(systemName: "hand.draw")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .contentShape(Capsule())
            .help(Text("Drag the image into another app", comment: "Annotate footer tooltip"))
            .onDrag {
                guard let url = model.actions.dragFile(model), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
                return provider
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Tool strip

/// Tools, colors, sizes and the current tool's options.
struct ToolStrip: View {
    @Bindable var model: AnnotateModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarkupTool.allCases) { tool in
                    ToolButton(symbol: tool.symbol, selected: model.tool == tool, help: tool.help) { model.selectTool(tool) }
                    if tool == .select || tool == .counter || tool == .spotlight {
                        Divider().frame(height: 18).padding(.horizontal, 3)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
            Spacer(minLength: 8)
            options
            if showsPalette {
                Divider().frame(height: 22)
                SizePicker(size: Binding(get: { model.size }, set: { model.setSize($0) }))
                Divider().frame(height: 22)
                ColorSwatches(color: Binding(get: { model.color }, set: { model.setColor($0) }))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var showsPalette: Bool {
        switch model.tool {
        case .blur, .pixelate, .spotlight, .crop: false
        case .select: model.selectedItem.map { !$0.isEffect } ?? true
        default: true
        }
    }

    /// The kind of thing the options apply to: the selection's, else the tool's.
    private var subject: MarkupTool {
        if let item = model.selectedItem {
            switch item.shape {
            case .arrow: return .arrow
            case .rectangle: return .rectangle
            case .ellipse: return .ellipse
            case .text: return .text
            case .spotlight: return .spotlight
            default: return model.tool
            }
        }
        return model.tool
    }

    @ViewBuilder private var options: some View {
        switch subject {
        case .arrow:
            Picker(selection: Binding(get: { model.curvedArrows }, set: { model.setCurved($0) })) {
                Image(systemName: "arrow.up.right").help(Text("Straight arrow", comment: "Arrow style")).tag(false)
                Image(systemName: "arrow.uturn.right").help(Text("Curved arrow", comment: "Arrow style")).tag(true)
            } label: { Text("Arrow style", comment: "Annotate option") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .rectangle, .ellipse:
            Picker(selection: Binding(get: { model.filledShapes }, set: { model.setFilled($0) })) {
                Image(systemName: subject == .ellipse ? "circle" : "square").help(Text("Outline", comment: "Shape style")).tag(false)
                Image(systemName: subject == .ellipse ? "circle.fill" : "square.fill").help(Text("Filled", comment: "Shape style")).tag(true)
            } label: { Text("Shape style", comment: "Annotate option") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .text:
            Picker(selection: Binding(get: { model.textStyle }, set: { model.setTextStyle($0) })) {
                ForEach(TextStyle.allCases) { Text($0.title).tag($0) }
            } label: { Text("Text style", comment: "Annotate option") }
            .labelsHidden().fixedSize()
        case .spotlight:
            Picker(selection: Binding(get: { model.ovalSpotlight }, set: { model.setOvalSpotlight($0) })) {
                Image(systemName: "rectangle").help(Text("Rectangle", comment: "Spotlight shape")).tag(false)
                Image(systemName: "circle").help(Text("Oval", comment: "Spotlight shape")).tag(true)
            } label: { Text("Spotlight shape", comment: "Annotate option") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .crop:
            HStack(spacing: 8) {
                Button { model.resetCrop() } label: { Text("Reset", comment: "Annotate crop: show the whole capture again") }
                    .disabled(model.document.crop == nil && model.cropDraft == model.document.imageBounds)
                Button { model.applyCrop() } label: { Text("Done", comment: "Annotate crop: apply the crop") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .blur, .pixelate:
            Group {
                if subject == .blur {
                    Text("Drag over what should be unreadable", comment: "Annotate hint for the blur tool")
                } else {
                    Text("Drag over what should be hidden", comment: "Annotate hint for the pixelate tool")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        default:
            if model.selection != nil {
                Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .help(Text("Delete (⌫)", comment: "Annotate: delete the selected annotation"))
            }
        }
    }
}

struct ToolButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// Four stroke weights as dots.
struct SizePicker: View {
    @Binding var size: MarkupSize

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MarkupSize.allCases) { s in
                Button { size = s } label: {
                    Circle()
                        .fill(Color.primary.opacity(size == s ? 0.85 : 0.45))
                        .frame(width: s.dot, height: s.dot)
                        .frame(width: 24, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(size == s ? 0.1 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.title)
                .accessibilityLabel(Text(verbatim: s.title))
            }
        }
    }
}

extension MarkupSize {
    fileprivate var dot: CGFloat {
        switch self {
        case .small: 4
        case .medium: 7
        case .large: 10
        case .extraLarge: 14
        }
    }
}

/// The eight annotation colors and a custom color well.
struct ColorSwatches: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MarkupPalette.colors, id: \.self) { c in
                Button { color = c } label: {
                    Circle()
                        .fill(c.color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                        .frame(width: 17, height: 17)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: color == c ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(MarkupPalette.name(of: c))
                .accessibilityLabel(Text(verbatim: MarkupPalette.name(of: c)))
            }
            customWell
        }
    }

    /// A rainbow dot over an invisible system color well, so it matches the swatches.
    private var customWell: some View {
        let custom = !MarkupPalette.colors.contains(color)
        return ZStack {
            Circle()
                .fill(custom ? AnyShapeStyle(color.color) : AnyShapeStyle(Self.rainbow))
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .frame(width: 17, height: 17)
                .padding(2.5)
                .overlay(Circle().strokeBorder(custom ? AnyShapeStyle(Self.rainbow) : AnyShapeStyle(Color.clear), lineWidth: 2))
                .allowsHitTesting(false)
            ColorPicker(selection: RGBA.binding($color), supportsOpacity: false) {
                Text("Custom color", comment: "Annotate: pick any color")
            }
            .labelsHidden()
            .opacity(0.02)
            .frame(width: 22, height: 22)
            .clipShape(Circle())
        }
        .frame(width: 22, height: 22)
        .help(String(localized: "Custom color", comment: "Annotate: pick any color"))
    }

    private static let rainbow = AngularGradient(
        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center)
}

// MARK: - Beautify panel

/// Background frame controls: backdrop, padding, corners, shadow, position and shape.
struct BeautifyPanel: View {
    @Bindable var model: AnnotateModel

    private var style: BeautifyStyle { model.document.beautify ?? model.defaultBeautify }

    private func binding<T>(_ key: WritableKeyPath<BeautifyStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: { value in model.editBeautify { $0[keyPath: key] = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(Text("Background", comment: "Background frame panel section")) {
                    BackdropGrid(selection: binding(\.backdrop))
                }
                section(Text("Frame", comment: "Background frame panel section: padding, corners, shadow")) {
                    PanelSlider(title: Text("Padding", comment: "Background frame: space around the screenshot"),
                                value: binding(\.padding), range: 0...200,
                                format: { Self.points($0) })
                    PanelSlider(title: Text("Corner radius", comment: "Background frame: rounded corners of the screenshot"),
                                value: binding(\.cornerRadius), range: 0...40,
                                format: { Self.points($0) })
                    PanelSlider(title: Text("Shadow", comment: "Background frame: shadow under the screenshot"),
                                value: binding(\.shadow), range: 0...1,
                                format: { $0.formatted(.percent.precision(.fractionLength(0))) })
                }
                section(Text("Position", comment: "Background frame panel section: where the screenshot sits")) {
                    AlignmentGrid(selection: binding(\.alignment))
                }
                section(Text("Shape", comment: "Background frame panel section: aspect ratio of the result")) {
                    AspectPicker(selection: binding(\.aspect))
                }
                Button {
                    model.actions.makeDefaultBackground(style)
                    model.showToast(String(localized: "New captures use this background", comment: "Annotate toast"))
                } label: {
                    Text("Use for New Captures", comment: "Background frame panel: make this the default background")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title.font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    static func points(_ v: Double) -> String {
        String(localized: "\(Int(v.rounded())) pt", comment: "A length in points, e.g. 56 pt")
    }
}

struct PanelSlider: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                title.font(.system(size: 12))
                Spacer()
                Text(verbatim: format(value)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// Preset backdrops as swatches, then transparent and a custom solid color.
struct BackdropGrid: View {
    @Binding var selection: Backdrop

    private var solidColor: RGBA {
        if case .solid(let c) = selection { return c }
        return RGBA(hex: "#2C2C34") ?? .black
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(BackdropPreset.allCases) { preset in
                swatch(.preset(preset), help: preset.title) { BackdropSwatch(backdrop: .preset(preset)) }
            }
            swatch(.none, help: String(localized: "Transparent", comment: "Background: none, see-through")) {
                TransparencyChecker()
            }
            ZStack {
                swatch(.solid(solidColor), help: String(localized: "Solid color", comment: "Background: one color")) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(solidColor.color)
                }
                ColorPicker(selection: Binding(get: { solidColor.color }, set: { selection = .solid(RGBA(NSColor($0))) }),
                            supportsOpacity: false) { Text("Solid color", comment: "Background: one color") }
                    .labelsHidden()
                    .opacity(0.02)
            }
        }
    }

    private func swatch<Content: View>(_ value: Backdrop, help: String, @ViewBuilder content: () -> Content) -> some View {
        let selected: Bool = {
            switch (value, selection) {
            case (.solid, .solid): true
            default: value == selection
            }
        }()
        return Button { selection = value } label: {
            content()
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// A backdrop painted by the same code as the output.
struct BackdropSwatch: View {
    let backdrop: Backdrop

    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in Beautifier.paint(backdrop, in: cg, rect: CGRect(origin: .zero, size: size)) }
        }
    }
}

struct TransparencyChecker: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.85)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}

/// Nine positions for the screenshot inside its frame.
struct AlignmentGrid: View {
    @Binding var selection: BeautifyAlignment

    var body: some View {
        HStack(spacing: 14) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let a = BeautifyAlignment.allCases[row * 3 + col]
                            Button { selection = a } label: {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(selection == a ? Color.accentColor : Color.primary.opacity(0.12))
                                    .frame(width: 22, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(a.title)
                            .accessibilityLabel(Text(verbatim: a.title))
                        }
                    }
                }
            }
            Text("Matters when the shape adds room on one side.", comment: "Background frame: hint next to the position grid")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AspectPicker: View {
    @Binding var selection: AspectPreset

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
            ForEach(AspectPreset.allCases) { a in
                Button { selection = a } label: {
                    Text(verbatim: a.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selection == a ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == a ? Color.accentColor : Color.primary.opacity(0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
