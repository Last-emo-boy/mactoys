import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Which control the editor shows.
@MainActor
@Observable
final class ControlsEditorState {
    var selection: UUID?
}

/// The custom controls editor: the list on the left, the selected control's steps and options on
/// the right. Edits go straight into the settings.
struct ControlsEditorView: View {
    let settings: Persisted<WindowControlsSettings>
    @Bindable var state: ControlsEditorState

    var body: some View {
        @Bindable var s = settings
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            Group {
                if let i = s.value.controls.firstIndex(where: { $0.id == state.selection }) {
                    ControlDetail(control: $s.value.controls[i], keyNumber: keyNumber(of: s.value.controls[i].id))
                        .id(s.value.controls[i].id)
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("No control selected", comment: "Window Controls editor: nothing is selected in the list")
                        } icon: {
                            Image(systemName: "macwindow.on.rectangle")
                        }
                    } description: {
                        Text("Pick a control on the left, or add one with +.",
                             comment: "Window Controls editor: what to do when nothing is selected")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, minHeight: 460)
    }

    private func keyNumber(of id: UUID) -> Int? {
        settings.value.keyboardControls.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var s = settings
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $state.selection) {
                    ForEach(s.value.controls) { control in
                        ControlRow(control: control, keyNumber: keyNumber(of: control.id))
                            .tag(control.id)
                            .id(control.id)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in s.value.controls.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Opening the editor on a control further down the list shows that control.
                .onAppear {
                    // After the list has laid out its rows.
                    guard let id = state.selection else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: state.selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("New Control") { add() }
                    Button("Duplicate") { duplicate() }.disabled(state.selection == nil)
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Add a control", comment: "Window Controls editor: tooltip of the + button"))
                Button { delete() } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(state.selection == nil)
                .help(Text("Delete the selected control", comment: "Window Controls editor: tooltip of the − button"))
                Spacer()
                Button("Restore Built-ins") {
                    s.value.controls = BuiltInControls.restored(in: s.value.controls)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(Text("Bring back the built-in controls with their original settings; your own controls stay",
                           comment: "Window Controls editor: tooltip of Restore Built-ins"))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func add() {
        let control = WindowControl(name: String(localized: "New Control", comment: "Name of a newly added Window Controls control"),
                                    steps: [.resize(.fraction(0.6), .fraction(0.7))], inPalette: true)
        settings.value.controls.append(control)
        state.selection = control.id
    }

    private func duplicate() {
        guard let i = settings.value.controls.firstIndex(where: { $0.id == state.selection }) else { return }
        var copy = settings.value.controls[i]
        copy.id = UUID()
        copy.name = String(localized: "\(copy.displayName) copy", comment: "Name of a duplicated Window Controls control; %@ is the original name")
        copy.builtIn = nil
        copy.shortcut = nil
        copy.steps = copy.steps.map { step in
            var s = step
            s.id = UUID()
            return s
        }
        settings.value.controls.insert(copy, at: i + 1)
        state.selection = copy.id
    }

    private func delete() {
        guard let i = settings.value.controls.firstIndex(where: { $0.id == state.selection }) else { return }
        settings.value.controls.remove(at: i)
        let list = settings.value.controls
        state.selection = list.isEmpty ? nil : list[min(i, list.count - 1)].id
    }
}

/// A row of the sidebar: glyph, name, where it shows.
private struct ControlRow: View {
    let control: WindowControl
    let keyNumber: Int?

    var body: some View {
        HStack(spacing: 10) {
            ControlGlyph(control, style: .light)
                .frame(width: 34, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: control.displayName).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let sc = control.shortcut {
                badge(Text(verbatim: sc.description))
                    .help(Text("Shortcut \(sc.description)", comment: "Window Controls editor: tooltip of a control's shortcut; %@ is the key combination"))
            }
            if let keyNumber {
                badge(Text(verbatim: "\(keyNumber)"))
                    .help(Text("Key \(keyNumber) in keyboard mode", comment: "Window Controls editor: this control's number key"))
            }
        }
        .padding(.vertical, 3)
    }

    private func badge(_ text: Text) -> some View {
        text.font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary.opacity(0.5)))
    }

    /// A chain's kind, or that the control stays out of the palette.
    private var detail: String? {
        if control.isChain {
            return control.chainMode == .cycle
                ? String(localized: "\(control.steps.count) steps in turn", comment: "Window Controls editor: a chain that runs one step per use")
                : String(localized: "\(control.steps.count) steps at once", comment: "Window Controls editor: a chain that runs every step together")
        }
        return control.inPalette ? nil
            : String(localized: "Not in the palette", comment: "Window Controls editor: the control doesn't show in the zoom button palette")
    }
}

/// The selected control: name, steps, and where it shows.
private struct ControlDetail: View {
    @Binding var control: WindowControl
    let keyNumber: Int?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    ControlGlyph(control, style: .light, highlighted: true)
                        .frame(width: 120, height: 75)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(text: $control.name, prompt: Text(verbatim: BuiltInControls.title(control.builtIn ?? "") ?? "")) {
                            Text("Name", comment: "Window Controls editor: the control's name")
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15, weight: .semibold))
                        .labelsHidden()
                        Text(summary)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(Array(control.steps.indices), id: \.self) { i in
                    StepEditor(step: $control.steps[i], number: i + 1, count: control.steps.count,
                               move: { delta in moveStep(i, by: delta) }, remove: { control.steps.remove(at: i) })
                }
                HStack {
                    Button { control.steps.append(.place(UnitRect(x: 0, y: 0, width: 0.5, height: 1))) } label: {
                        Label { Text("Add Step", comment: "Window Controls editor: add a step to the chain") } icon: { Image(systemName: "plus") }
                    }
                    Spacer()
                }
                if control.steps.count > 1 {
                    Picker(selection: $control.chainMode) {
                        ForEach(WindowControl.ChainMode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    } label: {
                        RowLabel("Chain", subtitle: "Several steps make a chain: run them together, or one per use (use it again for the next)")
                    }
                }
            } header: {
                Text("Steps", comment: "Window Controls editor section")
            }

            Section {
                Toggle(isOn: $control.inPalette) {
                    RowLabel("Show in the zoom button palette")
                }
                Toggle(isOn: $control.inKeyboard) {
                    RowLabel(title: Text("Number it in keyboard mode"),
                             subtitle: control.inKeyboard
                                ? (keyNumber.map { Text("Press \($0) in keyboard mode", comment: "Window Controls editor: the number key of this control") }
                                   ?? Text("Only the first nine numbered controls get a key", comment: "Window Controls editor"))
                                : nil)
                }
                ShortcutRow("Shortcut", subtitle: "Runs it on the focused window", shortcut: $control.shortcut)
            } header: {
                Text(String(localized: "windowcontrols.section.use", defaultValue: "Use", comment: "Window Controls editor section heading (a noun): where the control can be used"))
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        let names = control.steps.map(StepDescription.text)
        guard control.steps.count > 1 else { return names.first ?? "" }
        let list = names.joined(separator: control.chainMode == .cycle ? " · " : " → ")
        return control.chainMode == .cycle
            ? String(localized: "In turn: \(list)", comment: "Window Controls: a chain that runs one step per use; %@ lists the steps")
            : String(localized: "Together: \(list)", comment: "Window Controls: a chain that runs all steps at once; %@ lists the steps")
    }

    private func moveStep(_ i: Int, by delta: Int) {
        let j = i + delta
        guard control.steps.indices.contains(j) else { return }
        control.steps.swapAt(i, j)
    }
}

/// Words for what a step does: "Left 50 % × 100 %", "Resize to 1280 × 800, center".
enum StepDescription {
    static func text(_ step: ControlStep) -> String {
        let pct = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0...1))
        switch step.kind {
        case .place:
            let r = step.region
            return String(localized: "Place at \(r.x.formatted(pct)), \(r.y.formatted(pct)), \(r.width.formatted(pct)) × \(r.height.formatted(pct))",
                          comment: "Window Controls step summary: left, top, width × height as shares of the screen")
        case .resize:
            let size = String(localized: "\(dimension(step.width)) × \(dimension(step.height))",
                              comment: "Window Controls: width × height of a resize")
            let place = step.inPlace ? String(localized: "in place", comment: "Window Controls: resize around the window's center")
                                     : step.anchor.title.lowercased()
            return String(localized: "Resize to \(size), \(place)", comment: "Window Controls step summary: the size, then where the window goes")
        case .move:
            return String(localized: "Move to \(step.anchor.title.lowercased())", comment: "Window Controls step summary: a corner, edge or the center")
        case .display:
            return step.display.title
        }
    }

    private static func dimension(_ d: Dimension) -> String {
        switch d.unit {
        case .fraction: d.value.formatted(.percent.precision(.fractionLength(0...1)))
        case .points: Int(d.value).formatted()
        case .unchanged: String(localized: "same", comment: "Window Controls: this side of the window keeps its size")
        }
    }
}

/// Edits one step: its kind and its parameters.
private struct StepEditor: View {
    @Binding var step: ControlStep
    let number: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ControlGlyph(steps: [step], style: .light)
                    .frame(width: 30, height: 19)
                if count > 1 {
                    Text(verbatim: "\(number)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
                Picker(selection: $step.kind) {
                    ForEach(ControlStep.Kind.allCases, id: \.self) { kind in
                        Label { Text(verbatim: kind.title) } icon: { Image(systemName: kind.symbol) }.tag(kind)
                    }
                } label: {
                    Text("Step", comment: "Window Controls editor: what this step does")
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if count > 1 {
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(number == 1)
                        .help(Text("Move up", comment: "Window Controls editor: move the step earlier in the chain"))
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(number == count)
                        .help(Text("Move down", comment: "Window Controls editor: move the step later in the chain"))
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(Text("Remove step", comment: "Window Controls editor"))
                }
            }
            switch step.kind {
            case .place: PlaceEditor(region: $step.region)
            case .resize: ResizeEditor(step: $step)
            case .move:
                HStack(alignment: .center, spacing: 14) {
                    AnchorPicker(anchor: $step.anchor)
                    Text(verbatim: step.anchor.title).foregroundStyle(.secondary)
                    Spacer()
                }
            case .display:
                Picker(selection: $step.display) {
                    ForEach(DisplayTarget.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    Text("Display", comment: "Window Controls editor: which display the window moves to")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Drag across a fine grid (or type the numbers) to set the part of the screen a window covers.
private struct PlaceEditor: View {
    @Binding var region: UnitRect
    @State private var dragStart: GridCell?

    private let grid = GridSpec(columns: 12, rows: 12)
    private let size = CGSize(width: 208, height: 130)

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Canvas { ctx, canvas in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 8, style: .continuous),
                         with: .color(.primary.opacity(0.05)))
                for i in 1..<grid.columns {
                    let x = canvas.width * CGFloat(i) / CGFloat(grid.columns)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: canvas.height)) },
                               with: .color(.primary.opacity(i % 2 == 0 ? 0.12 : 0.06)), lineWidth: 0.5)
                }
                for i in 1..<grid.rows {
                    let y = canvas.height * CGFloat(i) / CGFloat(grid.rows)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: canvas.width, y: y)) },
                               with: .color(.primary.opacity(i % 2 == 0 ? 0.12 : 0.06)), lineWidth: 0.5)
                }
                let r = region.clamped
                let rect = CGRect(x: r.x * canvas.width, y: r.y * canvas.height, width: r.width * canvas.width,
                                  height: r.height * canvas.height).insetBy(dx: 2, dy: 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 5, style: .continuous), with: .color(.accentColor.opacity(0.8)))
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.2)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let a = grid.cell(at: value.startLocation, in: size), b = grid.cell(at: value.location, in: size)
                region = grid.unitRect(from: a, to: b)
            })
            .accessibilityLabel(Text("Part of the screen", comment: "Accessibility: the region picker in the Window Controls editor"))

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    Text("Left", comment: "Window Controls editor: distance from the screen's left edge").foregroundStyle(.secondary)
                    percentField($region.x)
                    Text("Top", comment: "Window Controls editor: distance from the screen's top edge").foregroundStyle(.secondary)
                    percentField($region.y)
                }
                GridRow {
                    Text("Width", comment: "Window Controls editor").foregroundStyle(.secondary)
                    percentField($region.width)
                    Text("Height", comment: "Window Controls editor").foregroundStyle(.secondary)
                    percentField($region.height)
                }
                GridRow {
                    Text("Drag across the grid, or type shares of the screen.", comment: "Window Controls editor hint")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(4)
                }
            }
        }
    }

    private func percentField(_ value: Binding<Double>) -> some View {
        TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 0), 1); region = region.clamped }),
                  format: .percent.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 66)
            .labelsHidden()
    }
}

/// Width and height of a resize (share of the screen, points or unchanged) and where it goes.
private struct ResizeEditor: View {
    @Binding var step: ControlStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dimensionRow(Text("Width", comment: "Window Controls editor"), $step.width)
            dimensionRow(Text("Height", comment: "Window Controls editor"), $step.height)
            HStack(alignment: .center, spacing: 14) {
                Text("Position", comment: "Window Controls editor: where the resized window goes").foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                AnchorPicker(anchor: $step.anchor)
                    .disabled(step.inPlace)
                    .opacity(step.inPlace ? 0.4 : 1)
                Toggle(isOn: $step.inPlace) {
                    Text("Keep in place", comment: "Window Controls editor: resize around the window's own center")
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
        }
    }

    private func dimensionRow(_ title: Text, _ d: Binding<Dimension>) -> some View {
        HStack(spacing: 10) {
            title.foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Picker(selection: Binding(get: { d.wrappedValue.unit }, set: { unit in
                guard unit != d.wrappedValue.unit else { return }
                // Start each unit from a sensible value.
                d.wrappedValue = switch unit {
                case .fraction: .fraction(0.6)
                case .points: .points(1024)
                case .unchanged: .unchanged
                }
            })) {
                ForEach(Dimension.Unit.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { title }
            .labelsHidden()
            .fixedSize()
            switch d.wrappedValue.unit {
            case .fraction:
                TextField("", value: Binding(get: { d.wrappedValue.value }, set: { d.wrappedValue.value = min(max($0, 0.05), 1) }),
                          format: .percent.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 72).labelsHidden()
            case .points:
                TextField("", value: Binding(get: { d.wrappedValue.value }, set: { d.wrappedValue.value = min(max($0, 40), 10_000) }),
                          format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 72).labelsHidden()
                Text("pt", comment: "Unit: points").foregroundStyle(.secondary)
            case .unchanged:
                EmptyView()
            }
            Spacer()
        }
    }
}

/// Nine dots in a screen outline: corners, edge middles and the center.
struct AnchorPicker: View {
    @Binding var anchor: Anchor

    var body: some View {
        let w: CGFloat = 66, h: CGFloat = 42
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.25)))
            ForEach(Anchor.allCases, id: \.self) { a in
                let on = a == anchor
                Circle()
                    .fill(on ? Color.accentColor : Color.primary.opacity(0.22))
                    .frame(width: on ? 10 : 7, height: on ? 10 : 7)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
                    .position(x: 9 + (w - 18) * a.unit.x, y: 7 + (h - 14) * a.unit.y)
                    .onTapGesture { anchor = a }
                    .help(Text(verbatim: a.title))
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: a.title))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(width: w, height: h)
    }
}
