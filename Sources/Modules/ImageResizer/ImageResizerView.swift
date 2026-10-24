import AppKit
import MacToysCore
import SwiftUI

/// The resize window (`design/exports/07-tool-windows.png`, "Resize 12 images").
struct ImageResizerView: View {
    @Bindable var model: ImageResizerModel
    var onClose: () -> Void = {}
    var onEditSizes: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ModuleIcon(symbol: "photo.on.rectangle.angled", tint: .green, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 15, weight: .semibold))
                    Text(model.source).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            switch model.phase {
            case .choosing: choosing
            case .resizing(let done, let current): progress(done: done, current: current)
            case .finished(let summary): finished(summary)
            }
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Choosing

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(Array(model.presets.enumerated()), id: \.element.id) { i, preset in
                    if i > 0 { Divider().padding(.leading, 40) }
                    SizeRow(title: preset.name, detail: preset.summary, selected: model.selectedIndex == i) {
                        model.selectedIndex = i
                    }
                }
                if !model.presets.isEmpty { Divider().padding(.leading, 40) }
                SizeRow(title: "Custom", detail: model.custom.summary, selected: model.selectedIndex == -1) {
                    model.selectedIndex = -1
                }
                if model.selectedIndex == -1 {
                    PresetEditor(preset: $model.custom, showsName: false)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 7) {
                Toggle("Make pictures smaller but not larger", isOn: $model.options.shrinkOnly)
                Toggle("Resize the original pictures (don’t create copies)", isOn: $model.options.replaceOriginals)
                Toggle("Ignore the orientation of pictures", isOn: $model.options.ignoreOrientation)
                    .help("Swap width and height to match portrait or landscape pictures")
                Toggle("Keep metadata", isOn: Binding(get: { !model.options.removeMetadata },
                                                      set: { model.options.removeMetadata = !$0 }))
                    .help("EXIF, GPS and IPTC information. Color profiles are always kept.")
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Edit Sizes…", action: onEditSizes).buttonStyle(.link)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Resize") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.urls.isEmpty)
            }
        }
    }

    // MARK: Progress and result

    private func progress(done: Int, current: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(1, model.urls.count)))
            HStack {
                Text("\(done) of \(model.urls.count) · \(current)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Stop") { model.cancel() }
            }
        }
    }

    private func finished(_ s: ImageResizerModel.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let ok = s.failures.isEmpty && !s.cancelled
            Label {
                Text(s.cancelled ? "Stopped after \(s.outputs.count) of \(model.urls.count) images"
                     : "Resized \(s.outputs.count) of \(model.urls.count) image\(model.urls.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
            if !s.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(s.failures.enumerated()), id: \.offset) { _, f in
                            Text(f).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(s.outputs) }
                    .disabled(s.outputs.isEmpty)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct SizeRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                Text(detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Width × height, unit and fit for a size; empty width or height means auto.
struct PresetEditor: View {
    @Binding var preset: ResizePreset
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            if showsName {
                TextField("Name", text: $preset.name, prompt: Text("Name")).frame(width: 110)
            }
            TextField("Width", text: dimension(\.width), prompt: Text("auto")).frame(width: 64)
                .multilineTextAlignment(.trailing)
            Text("×").foregroundStyle(.secondary)
            TextField("Height", text: dimension(\.height), prompt: Text("auto")).frame(width: 64)
                .multilineTextAlignment(.trailing)
            Picker("Unit", selection: $preset.unit) {
                ForEach(ResizeUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("Fit", selection: $preset.fit) {
                ForEach(ResizeFit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .controlSize(.small)
    }

    private func dimension(_ key: WritableKeyPath<ResizePreset, Double>) -> Binding<String> {
        Binding(get: { preset[keyPath: key] > 0 ? ResizeFileNamer.format(preset[keyPath: key]) : "" },
                set: { preset[keyPath: key] = max(0, Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0) })
    }
}
