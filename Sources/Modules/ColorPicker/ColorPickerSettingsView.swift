import MacToysCore
import SwiftUI

struct ColorPickerSettingsView: View {
    let module: ColorPickerModule
    @Bindable var settings: Persisted<ColorPickerSettings>
    @State private var editing: ColorFormat?
    @State private var editingIsNew = false

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .pink) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pick colors from anywhere").font(.headline)
                        Text("Scroll to zoom the loupe, use the arrow keys to move one pixel, press Esc to cancel.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Editor") { module.openEditor() }
                    Button("Pick a Color") { module.pick(fromEditor: false) }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", shortcut: $settings.value.activationShortcut)
                Picker(selection: activationBinding) {
                    ForEach(ColorPickerActivation.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Activation behavior", subtitle: "What the shortcut does.")
                }
            }
            Section("Mouse actions") {
                clickPicker("Left click", $settings.value.leftClick)
                clickPicker("Middle click", $settings.value.middleClick)
                clickPicker("Right click", $settings.value.rightClick)
                Picker(selection: $settings.value.magnifierCells) {
                    ForEach(LoupeZoom.steps.reversed(), id: \.self) { n in
                        Text(String(format: "%.1f×", LoupeView.diameter / CGFloat(n))).tag(n)
                    }
                } label: {
                    RowLabel("Initial magnification", subtitle: "Scroll while picking to change it.")
                }
            }
            Section("Editor") {
                Picker(selection: $settings.value.defaultFormat) {
                    ForEach(settings.value.formats) { Text($0.name).tag($0.name) }
                } label: {
                    RowLabel("Default color format", subtitle: "Used when a picked color is copied.")
                }
                Toggle(isOn: $settings.value.showColorName) {
                    RowLabel("Show color name", subtitle: "A high-level name such as “Light Green”, “Green” or “Dark Green”.")
                }
                Stepper(value: $settings.value.historyLimit, in: 1...100) {
                    RowLabel("Colors kept in history", subtitle: "\(settings.value.historyLimit) colors")
                }
            }
            Section {
                ForEach(Array(settings.value.formats.enumerated()), id: \.element.id) { index, format in
                    FormatSettingsRow(format: format,
                                      isEnabled: Binding(get: { settings.value.formats[index].enabled },
                                                         set: { settings.value.formats[index].enabled = $0 }),
                                      canMoveUp: index > 0, canMoveDown: index < settings.value.formats.count - 1,
                                      move: { move(index, by: $0) },
                                      edit: { editingIsNew = false; editing = format },
                                      delete: { delete(format) })
                }
                Button("Add Custom Format…") {
                    editingIsNew = true
                    editing = ColorFormat(name: uniqueName("Custom"), format: ColorFormat.newFormatTemplate)
                }
            } header: {
                Text("Color formats")
            } footer: {
                Text("Turned-off formats are hidden in the editor. Sample values show #FF5F4A.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { format in
            FormatEditor(original: format, isNew: editingIsNew, existingNames: Set(settings.value.formats.map(\.name))) { saved in
                save(saved, replacing: editingIsNew ? nil : format.name)
            }
        }
    }

    private var activationBinding: Binding<ColorPickerActivation> {
        Binding(get: { settings.value.activation }, set: { value in
            settings.update { s in
                s.activation = value
                switch value {
                case .pickThenEditor: s.leftClick = .pickThenEditor
                case .pickOnly: s.leftClick = .pickAndClose
                case .openEditor: break
                }
            }
        })
    }

    private func clickPicker(_ title: String, _ binding: Binding<ColorPickerClick>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ColorPickerClick.allCases) { Text($0.title).tag($0) }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.value.formats.indices.contains(target) else { return }
        settings.update { $0.formats.swapAt(index, target) }
    }

    private func delete(_ format: ColorFormat) {
        settings.update { s in
            s.formats.removeAll { $0.name == format.name }
            if s.defaultFormat == format.name { s.defaultFormat = "HEX" }
        }
    }

    private func save(_ format: ColorFormat, replacing old: String?) {
        settings.update { s in
            if let old, let i = s.formats.firstIndex(where: { $0.name == old }) {
                s.formats[i] = format
                if s.defaultFormat == old { s.defaultFormat = format.name }
            } else {
                s.formats.append(format)
            }
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(settings.value.formats.map(\.name))
        var n = 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

private let sampleColor = ColorValue(red: 255, green: 95, blue: 74)

struct FormatSettingsRow: View {
    let format: ColorFormat
    @Binding var isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(format.name)
                Text(ColorFormatter.format(sampleColor, format.format))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Move Up") { move(-1) }.disabled(!canMoveUp)
                Button("Move Down") { move(1) }.disabled(!canMoveDown)
                if !format.builtIn {
                    Divider()
                    Button("Edit…", action: edit)
                    Button("Delete", role: .destructive, action: delete)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Name + template editor with a live preview and the parameter reference.
struct FormatEditor: View {
    let original: ColorFormat
    let isNew: Bool
    let existingNames: Set<String>
    let save: (ColorFormat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""

    private static let reference: [(String, String)] = [
        ("%Re %Gr %Bl %Al", "red, green, blue, alpha"), ("%Cy %Ma %Ye %Bk", "cyan, magenta, yellow, black key"),
        ("%Hu", "hue"), ("%Si %Sl %Sb", "saturation (HSI, HSL, HSB)"), ("%Br %Va %In", "brightness, value, intensity"),
        ("%Hn %Ll", "hue and lightness (natural)"), ("%Lc %Ca %Cb", "CIE lightness, chromaticity A and B"),
        ("%Wh %Bn", "whiteness, blackness"), ("%Xv %Yv %Zv", "CIE X, Y, Z"), ("%Lo %Oa %Ob %Oc %Oh", "Oklab / Oklch"),
        ("%Dv %Dr", "decimal value (BGR, RGB)"), ("%Na %Cs", "color name, CSS color name"),
    ]
    private static let formatters = "After %Re %Gr %Bl %Al: b byte (default), h/H hex digit, x/X two hex digits, f float 0.##, F float .## — e.g. %ReX. After other values: i integer, p percent (%Lop%)."

    private var nameTaken: Bool { name != original.name && existingNames.contains(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Custom Color Format" : "Edit Custom Color Format").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Format", text: $template).font(.system(size: 12.5, design: .monospaced))
                LabeledContent("Preview") {
                    Text(ColorFormatter.format(sampleColor, template)).font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .frame(height: 150)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Self.reference, id: \.0) { row in
                        GridRow {
                            Text(row.0).font(.system(size: 11.5, design: .monospaced))
                            Text(row.1).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(Self.formatters).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            .frame(height: 170)
            HStack {
                if nameTaken { Text("A format with this name already exists.").font(.system(size: 11.5)).foregroundStyle(.red) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    save(ColorFormat(name: name.trimmingCharacters(in: .whitespaces), format: template,
                                     enabled: original.enabled, builtIn: false))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || template.isEmpty || nameTaken)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { name = original.name; template = original.format }
    }
}
