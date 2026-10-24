import MacToysCore
import SwiftUI

/// The glass layout picker (design 08): display selector, template and custom layouts,
/// parameters of the selected layout and its quick-apply key.
struct LayoutPickerCard: View {
    @Bindable var model: EditorModel

    static let cardWidth: CGFloat = 132
    static let columns = 6
    private let grid = Array(repeating: GridItem(.fixed(LayoutPickerCard.cardWidth), spacing: 14, alignment: .top),
                             count: LayoutPickerCard.columns)

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                header
                sectionTitle("Templates")
                LazyVGrid(columns: grid, alignment: .leading, spacing: 14) {
                    ForEach(model.library.templates) { card($0) }
                }
                sectionTitle("Custom")
                customSection
                Divider().overlay(Color.white.opacity(0.08))
                footer
            }
            .padding(22)
            .frame(width: CGFloat(Self.columns) * Self.cardWidth + CGFloat(Self.columns - 1) * 14 + 44)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.38))
            .overlay { if model.mode == .creating { createSheet } }
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Layouts").font(.system(size: 20, weight: .bold))
            Spacer()
            ForEach(model.displays) { d in
                let on = d.key == model.selectedKey
                Button { model.selectDisplay(d.key) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: d.key == ZoneDisplay.allDisplaysKey ? "rectangle.on.rectangle" : "display")
                        Text(model.displays.count > 1 ? "\(d.number)  \(d.name)" : d.name)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Color.accentColor : Color.white.opacity(0.08)))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.55)).padding(.top, 2)
    }

    // MARK: Cards

    private var customSection: some View {
        let rows = (model.library.custom.count + 1 + Self.columns - 1) / Self.columns
        let rowHeight: CGFloat = 116
        let content = LazyVGrid(columns: grid, alignment: .leading, spacing: 14) {
            ForEach(model.library.custom) { card($0) }
            createCard
        }
        return Group {
            if rows > 2 {
                ScrollView { content }.frame(height: rowHeight * 2 + 14).scrollIndicators(.visible)
            } else {
                content
            }
        }
    }

    private func card(_ layout: ZoneLayout) -> some View {
        let selected = layout.id == model.selectedLayout.id
        return VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.055))
                LayoutThumbnail(layout: layout, reference: model.selectedDisplay.workArea.size, selected: selected)
                    .padding(2)
            }
            .frame(width: Self.cardWidth, height: 88)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1))
            HStack(spacing: 5) {
                Text(layout.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let k = layout.quickKey {
                    Text("\(k)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.2)))
                        .help("⌃⌥⇧\(k)")
                }
                if selected && !layout.isTemplate {
                    Button { model.edit(layout) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Edit zones")
                }
            }
        }
        .frame(width: Self.cardWidth)
        .contentShape(Rectangle())
        .onTapGesture { model.choose(layout) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.choose(layout); model.onClose() })
        .contextMenu { menu(for: layout) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func menu(for layout: ZoneLayout) -> some View {
        Button("Apply") { model.choose(layout) }
        if !layout.isTemplate { Button("Edit Zones…") { model.choose(layout); model.edit(layout) } }
        Button("Duplicate") { model.duplicate(layout) }
        quickKeyMenu(for: layout)
        if !layout.isTemplate {
            Divider()
            Button("Delete", role: .destructive) {
                model.pendingDelete = layout.id
                model.delete(layout)
            }
        }
    }

    private func quickKeyMenu(for layout: ZoneLayout) -> some View {
        Menu("Apply with") {
            Button("None") { model.setQuickKey(nil, for: layout.id) }
            ForEach(1...9, id: \.self) { n in
                let owner = model.library.layout(quickKey: n)
                Button(owner.map { "⌃⌥⇧\(n)  ·  \($0.name)" } ?? "⌃⌥⇧\(n)") { model.setQuickKey(n, for: layout.id) }
            }
        }
    }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(.white.opacity(0.7)))
                .frame(width: Self.cardWidth, height: 88)
            Text("Create new layout").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.beginCreate() }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Footer

    private var footer: some View {
        let layout = model.selectedLayout
        return HStack(spacing: 16) {
            if layout.isTemplate && layout.kind != .blank {
                ValueStepper(title: "Zones", value: layout.zoneCount, unit: "", range: 1...20, step: 1) { v in
                    model.updateSelected { $0.zoneCount = v }
                }
            }
            if layout.kind != .blank && layout.kind != .focus && layout.kind != .canvas {
                Toggle(isOn: Binding(get: { layout.showSpacing },
                                     set: { v in model.updateSelected { $0.showSpacing = v } })) {
                    Text("Zone spacing")
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                ValueStepper(title: nil, value: Int(layout.spacing), unit: "px", range: 0...100, step: 2) { v in
                    model.updateSelected { $0.spacing = Double(v); $0.showSpacing = true }
                }
                .opacity(layout.showSpacing ? 1 : 0.45)
            }
            if layout.kind != .blank {
                ValueStepper(title: "Highlight distance", value: Int(layout.highlightDistance), unit: "px",
                             range: 0...100, step: 5) { v in
                    model.updateSelected { $0.highlightDistance = Double(v) }
                }
            }
            Spacer(minLength: 8)
            if layout.kind != .blank {
                HStack(spacing: 6) {
                    Text("Apply with").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55)).fixedSize()
                    if let k = layout.quickKey {
                        Keycaps(["⌃", "⌥", "⇧", "\(k)"], dark: true)
                    } else {
                        Text("None").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.8))
                    }
                    Menu {
                        Button("None") { model.setQuickKey(nil, for: layout.id) }
                        ForEach(1...9, id: \.self) { n in
                            let owner = model.library.layout(quickKey: n)
                            Button(owner.map { "⌃⌥⇧\(n)  ·  \($0.name)" } ?? "⌃⌥⇧\(n)") { model.setQuickKey(n, for: layout.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose the quick-apply key")
                }
            }
            iconButton("plus.square.on.square", help: "Duplicate") { model.duplicate(layout) }
            if !layout.isTemplate {
                iconButton("square.and.pencil", help: "Edit zones") { model.edit(layout) }
                iconButton(model.pendingDelete == layout.id ? "trash.fill" : "trash",
                           help: model.pendingDelete == layout.id ? "Click again to delete" : "Delete",
                           tint: model.pendingDelete == layout.id ? .red : nil) { model.delete(layout) }
            }
            Button("Done") { model.onClose() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .font(.system(size: 12))
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint ?? Color.white.opacity(0.75))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Create

    private var createSheet: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.45))
                .onTapGesture { model.mode = .picker }
            VStack(alignment: .leading, spacing: 14) {
                Text("Create new layout").font(.system(size: 16, weight: .semibold))
                TextField("Name", text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { model.create() }
                Picker("Type", selection: $model.newIsCanvas) {
                    Label("Grid", systemImage: "rectangle.split.3x3").tag(false)
                    Label("Canvas", systemImage: "rectangle.on.rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.newIsCanvas
                     ? "Free-form zones you move and resize, which may overlap. Scales to other displays."
                     : "Split and merge zones on a grid that keeps its proportions on any display.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.mode = .picker }
                    Button("Create") { model.create() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .fixedSize()
        }
    }
}

/// "Highlight distance  20 px  [– +]" in the editor footer.
private struct ValueStepper: View {
    let title: String?
    let value: Int
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let title { Text(title).foregroundStyle(Color.white.opacity(0.55)) }
            Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)").monospacedDigit().frame(minWidth: unit.isEmpty ? 16 : 34, alignment: .trailing)
            Stepper("", onIncrement: { set(min(range.upperBound, value + step)) },
                    onDecrement: { set(max(range.lowerBound, value - step)) })
                .labelsHidden()
                .controlSize(.mini)
        }
        .font(.system(size: 12))
        .fixedSize()
    }
}
