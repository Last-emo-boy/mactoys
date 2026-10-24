import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Resize one or many images with presets.
///
/// URL actions: `open` (files, or the Finder selection when none are given) shows the resize window;
/// `resize?preset=<name or index>` resizes without asking; `settings`.
@MainActor
public final class ImageResizerModule: ToyModule {
    public let info = ModuleInfo(
        id: "imageresizer", name: "Image Resizer",
        summary: "Resize one or many images from Finder with presets.",
        symbol: "photo.on.rectangle.angled", tint: .green, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["resize", "scale", "photo", "picture", "thumbnail", "jpeg", "png", "heic"])

    let settings = Persisted("imageresizer", default: ImageResizerSettings())
    private var windows: [HostedToolWindow] = []
    private var running = false
    private let log = Log.for("imageresizer")
    private static let hotkeyID = "imageresizer.open"

    public init() {
        settings.onChange { [weak self] _ in self?.registerHotkey() }
    }

    public func start() {
        running = true
        registerHotkey()
    }

    public func stop() {
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        for w in windows { w.close() }
        windows.removeAll()
    }

    private func registerHotkey() {
        guard running else { return }
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activation) { [weak self] in
            self?.openWithFinderSelection()
        }
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "imageresizer.open", title: "Resize Images", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.activation) { [weak self] in self?.openWithFinderSelection() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        settings.value.activation.map { [ShortcutBinding("Resize the Finder selection", $0)] } ?? []
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "open", "show":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            if command.files.isEmpty { openWithFinderSelection() } else { open(command.files, source: "from Finder") }
        case "resize":
            guard isEnabled else { return true }
            if command.files.isEmpty {
                guard let urls = FinderSelection.selectionRequestingPermission() else { return true }
                resizeDirectly(urls, presetName: command.parameters["preset"])
            } else {
                resizeDirectly(command.files, presetName: command.parameters["preset"])
            }
        default:
            return false
        }
        return true
    }

    /// Whether ImageIO can read the file.
    static func isImage(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image) else { return false }
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return readable.contains { UTType($0).map { type.conforms(to: $0) } ?? false }
    }

    func openWithFinderSelection() {
        guard let urls = FinderSelection.selectionRequestingPermission() else { return }
        open(urls, source: "from Finder selection")
    }

    func open(_ urls: [URL], source: String) {
        let images = urls.filter(Self.isImage)
        guard !images.isEmpty else {
            HUD.show(urls.isEmpty ? "Select images in Finder first" : "No images MacToys can resize", symbol: "photo.badge.exclamationmark")
            return
        }
        let model = ImageResizerModel(urls: images, source: source, settings: settings.value)
        model.onStart = { [weak self] m in
            self?.settings.update { s in
                s.selectedIndex = m.selectedIndex
                s.custom = m.custom
                s.options.shrinkOnly = m.options.shrinkOnly
                s.options.replaceOriginals = m.options.replaceOriginals
                s.options.ignoreOrientation = m.options.ignoreOrientation
                s.options.removeMetadata = m.options.removeMetadata
            }
        }
        weak var window: HostedToolWindow?
        let view = ImageResizerView(model: model,
                                    onClose: { window?.close() },
                                    onEditSizes: { [weak self] in
                                        window?.close()
                                        ModuleRegistry.shared.showSettings?(self?.info.id)
                                    })
        let w = HostedToolWindow(title: model.title, size: CGSize(width: 420, height: 380), resizable: false, content: view)
        w.window.titlebarAppearsTransparent = true
        w.window.titleVisibility = .hidden
        w.window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.window.standardWindowButton(.zoomButton)?.isHidden = true
        w.window.isMovableByWindowBackground = true
        w.onClose = { [weak self, weak w] in
            model.cancel()
            self?.windows.removeAll { $0 === w }
        }
        windows.append(w)
        window = w
        w.show()
    }

    /// Resizes with a preset (by name or index) without the window; reports with a HUD.
    func resizeDirectly(_ urls: [URL], presetName: String?) {
        let images = urls.filter(Self.isImage)
        guard !images.isEmpty else { HUD.show("No images to resize", symbol: "photo.badge.exclamationmark"); return }
        let s = settings.value
        let preset: ResizePreset
        if let name = presetName, let i = Int(name), s.presets.indices.contains(i) {
            preset = s.presets[i]
        } else if let name = presetName, let p = s.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            preset = p
        } else if presetName?.lowercased() == "custom" {
            preset = s.custom
        } else {
            preset = s.selectedPreset
        }
        let options = s.options
        let log = log
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> Int in
                var failed = 0
                for url in images {
                    do {
                        _ = try ImageResizerEngine.resize(url: url, preset: preset, options: options)
                    } catch {
                        failed += 1
                        log.error("\(error.localizedDescription, privacy: .public)")
                    }
                }
                return failed
            }.value
            let written = images.count - failures
            HUD.show(failures == 0 ? "Resized \(written) image\(written == 1 ? "" : "s") · \(preset.name)"
                                   : "Resized \(written) · \(failures) failed",
                     symbol: failures == 0 ? "photo.on.rectangle.angled" : "exclamationmark.triangle")
        }
    }

    // MARK: Settings

    public func settingsView() -> AnyView {
        AnyView(ImageResizerSettingsView(module: self))
    }

    // MARK: Previews

    public var previewScenes: [PreviewScene] {
        [
            PreviewScene("window", size: CGSize(width: 460, height: 440), wallpaper: false) {
                AnyView(Self.previewWindow(Self.sampleModel()))
            },
            PreviewScene("progress", size: CGSize(width: 460, height: 160), wallpaper: false) {
                let m = Self.sampleModel()
                m.showPhase(.resizing(done: 7, current: "IMG_4830.HEIC"))
                return AnyView(Self.previewWindow(m))
            },
            PreviewScene("done", size: CGSize(width: 460, height: 230), wallpaper: false) {
                let m = Self.sampleModel()
                let outs = (1...11).map { URL(fileURLWithPath: "/tmp/IMG_\($0) (Medium).HEIC") }
                m.showPhase(.finished(.init(outputs: outs, failures: ["scan.pdf: Not an image MacToys can read"], cancelled: false)))
                return AnyView(Self.previewWindow(m))
            },
        ]
    }

    private static func previewWindow(_ model: ImageResizerModel) -> some View {
        ImageResizerView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func sampleModel() -> ImageResizerModel {
        var s = ImageResizerSettings()
        s.custom = ResizePreset(name: "Custom", fit: .stretch, width: 50, height: 50, unit: .percent)
        s.presets[3].fit = .fill
        s.options.shrinkOnly = true
        s.options.ignoreOrientation = true
        let urls = (1...12).map { URL(fileURLWithPath: "/tmp/IMG_\($0).HEIC") }
        return ImageResizerModel(urls: urls, source: "from Finder selection", settings: s, live: false)
    }
}

private struct ImageResizerSettingsView: View {
    let module: ImageResizerModule
    @Bindable var settings: Persisted<ImageResizerSettings>
    @State private var dropTargeted = false

    init(module: ImageResizerModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .green) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 22)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dropTargeted ? "Release to resize" : "Drop images here").font(.headline)
                        Text("Or select images in Finder and choose MacToys › Resize with Image Resizer.")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Resize Finder Selection") { module.openWithFinderSelection() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                module.open(urls, source: "dropped on Settings")
                return true
            } isTargeted: { dropTargeted = $0 }
        } content: {
            Section {
                ForEach($settings.value.presets) { $preset in
                    LabeledContent {
                        HStack(spacing: 8) {
                            PresetEditor(preset: $preset, showsName: false)
                            Button {
                                settings.update { s in s.presets.removeAll { $0.id == preset.id } }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Delete this size")
                        }
                    } label: {
                        TextField("Name", text: $preset.name).labelsHidden().textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                HStack {
                    Button("Add Size") {
                        settings.update { $0.presets.append(ResizePreset(name: "New size", width: 1024, height: 768)) }
                    }
                    Button("Restore Defaults") { settings.update { $0.presets = ResizePreset.defaults; $0.selectedIndex = 1 } }
                        .disabled(settings.value.presets == ResizePreset.defaults)
                }
            } header: {
                Text("Sizes")
            } footer: {
                Text("Fill covers the size and crops the rest, Fit keeps the whole picture inside it, Stretch distorts it to the exact size. Leave width or height empty to keep the proportions.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Section("Encoding") {
                Picker(selection: $settings.value.options.encoder.fallback) {
                    ForEach(FallbackEncoder.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Fallback encoder", subtitle: "Used when a picture’s own format can’t be written (RAW, PDF, ICNS…). Not a converter.")
                }
                SliderRow("JPEG quality", value: Binding(get: { Double(settings.value.options.encoder.jpegQuality) },
                                                         set: { settings.value.options.encoder.jpegQuality = Int($0.rounded()) }),
                          in: 1...100, step: 1)
                SliderRow("HEIC quality", value: Binding(get: { Double(settings.value.options.encoder.heicQuality) },
                                                         set: { settings.value.options.encoder.heicQuality = Int($0.rounded()) }),
                          in: 1...100, step: 1)
                Picker(selection: $settings.value.options.encoder.pngInterlace) {
                    ForEach(PNGInterlace.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("PNG interlacing", subtitle: "Interlaced PNGs load progressively.")
                }
                Picker("TIFF compression", selection: $settings.value.options.encoder.tiffCompression) {
                    ForEach(TIFFCompression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                LabeledContent {
                    TextField("File name format", text: $settings.value.options.fileNameFormat, prompt: Text("%1 (%2)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                } label: {
                    RowLabel("File name format", subtitle: "Example: \(example)")
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow { token("%1", "Original file name"); token("%4", "Selected height") }
                    GridRow { token("%2", "Size name"); token("%5", "Actual width") }
                    GridRow { token("%3", "Selected width"); token("%6", "Actual height") }
                }
                .font(.system(size: 11.5))
                Toggle(isOn: $settings.value.options.keepDateModified) {
                    RowLabel("Keep the original modification date", subtitle: "Otherwise resized files are dated now.")
                }
            } header: {
                Text("File")
            } footer: {
                Text("Use / to save into subfolders, e.g. %2/%1. Characters that can’t be in a file name become _.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Section("Defaults") {
                Toggle("Make pictures smaller but not larger", isOn: $settings.value.options.shrinkOnly)
                Toggle("Resize the original pictures", isOn: $settings.value.options.replaceOriginals)
                Toggle(isOn: $settings.value.options.ignoreOrientation) {
                    RowLabel("Ignore the orientation of pictures",
                             subtitle: "The smaller number of a size applies to the smaller side of each picture.")
                }
                Toggle("Remove metadata", isOn: $settings.value.options.removeMetadata)
            }
            Section("Finder") {
                Toggle(isOn: $settings.value.showInFinderMenu) {
                    RowLabel("Show Image Resizer in the Finder menu", subtitle: "Under MacToys when images are selected.")
                }
                Toggle("Only while holding ⌥ Option", isOn: $settings.value.finderMenuNeedsOption)
                    .disabled(!settings.value.showInFinderMenu)
                ShortcutRow("Resize the Finder selection", subtitle: "Optional.", shortcut: $settings.value.activation)
            }
        }
    }

    private var example: String {
        let p = settings.value.selectedPreset
        let values = ResizeFileNamer.Values(original: "example", sizeName: p.name, selectedWidth: p.width,
                                            selectedHeight: p.height, actualWidth: Int(p.width), actualHeight: Int(p.height))
        return ResizeFileNamer.components(format: settings.value.options.fileNameFormat, values: values).joined(separator: "/") + ".jpg"
    }

    private func token(_ t: String, _ meaning: String) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary)
            Text(meaning).foregroundStyle(.secondary)
        }
    }
}
