import AppKit
import MacToysCore
import SwiftUI

/// A miniature photo split down the middle: the original on the left, the optimized version on the
/// right with as many gradient steps as the current settings keep, and the sizes they would give.
struct BeforeAfterIllustration: View {
    /// Gradient steps visible on the After side (fewer colors or lower quality: fewer steps).
    var bands: Int
    var before: Int64
    var after: Int64

    var body: some View {
        ZStack {
            HeroScene(bands: nil)
            HeroScene(bands: bands)
                .mask(alignment: .trailing) {
                    GeometryReader { geo in Rectangle().frame(width: geo.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing) }
                }
            // The split handle.
            Rectangle().fill(.white).frame(width: 2).shadow(color: .black.opacity(0.3), radius: 2)
            Circle().fill(.white).frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(white: 0.3))
                }
        }
        .overlay(alignment: .topLeading) {
            label(Text("Before", comment: "Optimizer settings hero: the original file"), size: before, saving: nil).padding(8)
        }
        .overlay(alignment: .topTrailing) {
            label(Text("After", comment: "Optimizer settings hero: the optimized file"), size: after,
                  saving: SizeGate.saving(original: before, result: after)).padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Before \(FileSize.format(before)), after \(FileSize.format(after))",
                                 comment: "Optimizer settings hero, accessibility: estimated sizes"))
    }

    private func label(_ title: Text, size: Int64, saving: Double?) -> some View {
        VStack(alignment: saving == nil ? .leading : .trailing, spacing: 1) {
            title.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).textCase(.uppercase)
            HStack(spacing: 4) {
                Text(verbatim: FileSize.format(size)).font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                if let saving { SavingBadge(saving: saving) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35)))
    }
}

/// A dusk landscape drawn in code; `bands` posterizes its sky and water like a reduced palette.
private struct HeroScene: View {
    var bands: Int?

    private static let sky: [Color] = [Color(red: 0.13, green: 0.16, blue: 0.42), Color(red: 0.45, green: 0.27, blue: 0.6),
                                       Color(red: 0.95, green: 0.55, blue: 0.42), Color(red: 1, green: 0.8, blue: 0.5)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                gradient(Self.sky).frame(height: h * 0.72)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.93, blue: 0.75), Color(red: 1, green: 0.75, blue: 0.45).opacity(0)],
                                         center: .center, startRadius: 2, endRadius: h * 0.32))
                    .frame(width: h * 0.64, height: h * 0.64)
                    .position(x: w * 0.68, y: h * 0.6)
                Circle().fill(Color(red: 1, green: 0.95, blue: 0.82)).frame(width: h * 0.16).position(x: w * 0.68, y: h * 0.6)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.42))
                    p.addLine(to: CGPoint(x: w * 0.33, y: h * 0.56))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.34))
                    p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.72))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.25, green: 0.18, blue: 0.42))
                Path { p in
                    p.move(to: CGPoint(x: w * 0.45, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.47))
                    p.addLine(to: CGPoint(x: w, y: h * 0.58))
                    p.addLine(to: CGPoint(x: w, y: h * 0.72))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.33, green: 0.22, blue: 0.47))
                gradient([Color(red: 0.55, green: 0.33, blue: 0.5), Color(red: 0.12, green: 0.12, blue: 0.3)])
                    .frame(height: h * 0.28)
                    .offset(y: h * 0.72)
            }
        }
    }

    @ViewBuilder private func gradient(_ colors: [Color]) -> some View {
        if let bands, bands > 1 {
            VStack(spacing: 0) {
                ForEach(0..<bands, id: \.self) { i in
                    Rectangle().fill(Self.interpolate(colors, at: (Double(i) + 0.5) / Double(bands)))
                }
            }
        } else {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        }
    }

    private static func interpolate(_ colors: [Color], at t: Double) -> Color {
        let resolved = colors.map { $0.resolve(in: EnvironmentValues()) }
        let x = min(0.999, max(0, t)) * Double(resolved.count - 1)
        let i = Int(x), f = Float(x - Double(i))
        let a = resolved[i], b = resolved[i + 1]
        return Color(red: Double(a.red + (b.red - a.red) * f), green: Double(a.green + (b.green - a.green) * f),
                     blue: Double(a.blue + (b.blue - a.blue) * f))
    }
}

/// The hero's numbers: a 12-megapixel photo of about 4.8 MB, run through the current settings.
enum HeroEstimate {
    static let before: Int64 = 4_800_000

    static func after(_ s: ImageSettings) -> Int64 {
        let q = Double(min(100, max(10, s.quality))) / 100
        var ratio = 0.1 + 0.55 * q * q * q
        switch s.downscale {
        case .off: break
        case .maxSide: ratio *= pow(min(1, Double(s.maxSide) / 4032), 2)
        case .factor: ratio *= s.factor * s.factor
        }
        return Int64(Double(before) * max(0.02, ratio))
    }

    static func bands(_ s: ImageSettings) -> Int {
        let q = Double(min(100, max(10, s.quality))) / 100
        let colors = s.reduceColors ? Double(s.maxColors) : 256
        return max(5, Int((colors.squareRoot() * 1.5 * q).rounded()))
    }
}

/// A miniature display with four clickable corners.
struct CornerPicker: View {
    @Binding var corner: ScreenCorner

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.3, blue: 0.62), Color(red: 0.72, green: 0.42, blue: 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack {
                Rectangle().fill(.white.opacity(0.35)).frame(height: 4)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            ForEach(ScreenCorner.allCases, id: \.self) { c in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(c == corner ? Color.accentColor : .white.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(c == corner ? 0.9 : 0), lineWidth: 1))
                    .frame(width: 20, height: 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                    .padding(EdgeInsets(top: 8, leading: 5, bottom: 5, trailing: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { corner = c }
            }
        }
        .frame(width: 80, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.15)))
        .animation(.snappy(duration: 0.2), value: corner)
        .accessibilityRepresentation {
            Picker("Corner", selection: $corner) {
                ForEach(ScreenCorner.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func alignment(_ c: ScreenCorner) -> Alignment {
        switch c {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// One watch folder: switch, kinds and action.
struct WatchFolderRow: View {
    @Binding var folder: WatchFolder
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: displayName).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        if !exists {
                            Text("Not found", comment: "Optimizer: a watch folder that no longer exists").foregroundStyle(.orange)
                            Text(verbatim: "·")
                        }
                        Text(verbatim: folder.path).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(isOn: $folder.enabled) {
                    Text("Watch \(displayName)", comment: "Optimizer: switch to watch a folder; the value is the folder name")
                }
                .toggleStyle(.adaptiveSwitch)
                .labelsHidden()
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in chip(kind) }
                    Spacer(minLength: 8)
                    Picker(selection: $folder.action) {
                        ForEach(WatchAction.all, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Text("Action", comment: "Optimizer: what a watch folder does with new files")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!folder.enabled)
                .opacity(folder.enabled ? 1 : 0.55)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Stop watching this folder", comment: "Optimizer: remove a watch folder"))
                .accessibilityLabel(Text("Stop watching \(displayName)", comment: "Optimizer: remove a watch folder; the value is the folder name"))
            }
            .padding(.leading, 38)
        }
        .padding(.vertical, 2)
    }

    private var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var displayName: String {
        exists ? FileManager.default.displayName(atPath: folder.url.path) : folder.url.lastPathComponent
    }

    @ViewBuilder private var icon: some View {
        if exists {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.url.path)).resizable()
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().opacity(0.45)
        }
    }

    private func chip(_ kind: MediaKind) -> some View {
        let on = folder.kinds.contains(kind)
        return Button {
            if on { folder.kinds.remove(kind) } else { folder.kinds.insert(kind) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(verbatim: kind.title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Optimizer settings page.
struct OptimizerSettingsView: View {
    let module: OptimizerModule
    @Bindable var s: Persisted<OptimizerSettings>
    @State private var backupSize: Int64?
    @State private var confirmDelete = false
    @State private var heroTargeted = false

    init(module: OptimizerModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            hero
        } content: {
            clipboardSection
            dropZoneSection
            imagesSection
            videosSection
            pdfSection
            WatchFoldersSection(folders: $s.value.watchFolders)
            resultsSection
            backupsSection
            moreSection
        }
        .task(id: s.value.backupRetention) { await refreshBackupSize() }
    }

    // MARK: Hero

    private var hero: some View {
        HeroCard(tint: .green) {
            HStack(alignment: .center, spacing: 20) {
                BeforeAfterIllustration(bands: HeroEstimate.bands(s.value.image), before: HeroEstimate.before,
                                        after: HeroEstimate.after(s.value.image))
                    .frame(width: 248, height: 156)
                    .animation(.smooth(duration: 0.25), value: HeroEstimate.bands(s.value.image))
                VStack(alignment: .leading, spacing: 10) {
                    (heroTargeted ? Text("Release to optimize", comment: "Optimizer settings hero while files are dragged over it")
                                  : Text("Smaller files that look the same", comment: "Optimizer settings hero title"))
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        summary("photo", imageSummary)
                        summary("film", videoSummary)
                        summary("doc.richtext", pdfSummary)
                    }
                    HStack(spacing: 8) {
                        Button {
                            module.optimizeClipboard()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Optimize Clipboard", comment: "Optimizer: button")
                                if let shortcut = s.value.clipboardShortcut { Keycaps(shortcut) }
                            }
                        }
                        Button {
                            module.chooseFiles()
                        } label: {
                            Text("Choose Files…", comment: "Optimizer: button that opens a file picker")
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .overlay {
            if heroTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tint.green.color, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            module.center.submit(urls)
            return true
        } isTargeted: { heroTargeted = $0 }
    }

    private func summary(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Tint.green.color)
                .frame(width: 16)
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var imageSummary: String {
        let i = s.value.image
        var parts = [String(localized: "Quality \(Double(i.quality) / 100, format: .percent.precision(.fractionLength(0)))",
                            comment: "Optimizer settings hero summary: JPEG/HEIC quality")]
        if i.reduceColors { parts.append(String(localized: "PNGs to \(i.maxColors) colors", comment: "Optimizer settings hero summary")) }
        if i.stripMetadata { parts.append(String(localized: "metadata removed", comment: "Optimizer settings hero summary")) }
        switch i.downscale {
        case .off: break
        case .maxSide: parts.append(String(localized: "up to \(i.maxSide) px", comment: "Optimizer settings hero summary: longest side limit"))
        case .factor: parts.append(String(localized: "scaled to \(i.factor, format: .percent.precision(.fractionLength(0)))",
                                          comment: "Optimizer settings hero summary"))
        }
        return parts.joined(separator: " · ")
    }

    private var videoSummary: String {
        let v = s.value.video
        var parts = [v.codec == .hevc ? "HEVC" : "H.264", v.quality.title, v.maxResolution.title]
        if v.removeAudio { parts.append(String(localized: "no audio", comment: "Optimizer settings hero summary")) }
        if v.speed != 1 { parts.append(String(localized: "\(v.speed.formatted(.number.precision(.fractionLength(0...2))))× speed", comment: "Optimizer settings hero summary: playback speed")) }
        return parts.joined(separator: " · ")
    }

    private var pdfSummary: String {
        String(localized: "PDF images at \(s.value.pdf.imageResolution) dpi, text stays selectable", comment: "Optimizer settings hero summary")
    }

    // MARK: Sections

    private var clipboardSection: some View {
        Section("Clipboard") {
            Toggle(isOn: $s.value.optimizeClipboard) {
                RowLabel("Optimize copied images",
                         subtitle: "Screenshots and images you copy are shrunk right away, ready to paste. The original can be restored from its card.")
            }
            ShortcutRow("Optimize the clipboard now", subtitle: "Works on copied images and on files copied in Finder.",
                        shortcut: $s.value.clipboardShortcut)
        }
    }

    private var dropZoneSection: some View {
        Section("Drop zone") {
            Toggle(isOn: $s.value.dropZoneEnabled) {
                RowLabel("Show a drop zone while dragging files",
                         subtitle: "Drag images, videos or PDFs toward a corner of the screen and drop them on the zone that appears.")
            }
            cornerRow($s.value.dropZoneCorner) { RowLabel("Corner", subtitle: "Drag files toward this corner to show the zone.") }
                .disabled(!s.value.dropZoneEnabled)
            Picker(selection: $s.value.dropZoneConvertFormat) {
                ForEach(ImageFormat.writable, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Convert zone", subtitle: "The format of the drop zone’s Convert target.")
            }
            .disabled(!s.value.dropZoneEnabled)
        }
    }

    private var imagesSection: some View {
        Section {
            SliderRow("JPEG, HEIC and AVIF quality", subtitle: "80% looks the same as the original for nearly every photo.",
                      value: Binding(get: { Double(s.value.image.quality) }, set: { s.value.image.quality = Int($0.rounded()) }),
                      in: 40...100, step: 1, format: { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) })
            Toggle(isOn: $s.value.image.reduceColors) {
                RowLabel("Reduce PNG colors",
                         subtitle: "Screenshots with a palette of up to 256 colors look the same and are usually 60–80% smaller. Skipped when the colors would visibly change.")
            }
            Picker(selection: $s.value.image.maxColors) {
                ForEach([256, 128, 64, 32], id: \.self) { n in
                    Text("\(n) colors", comment: "Optimizer: PNG palette size").tag(n)
                }
            } label: {
                RowLabel("Palette size")
            }
            .disabled(!s.value.image.reduceColors)
            Toggle(isOn: $s.value.image.dither) {
                RowLabel("Dither gradients", subtitle: "Smooths gradients when colors are reduced. Flat areas stay clean.")
            }
            .disabled(!s.value.image.reduceColors)
            Picker(selection: $s.value.image.convertOpaquePNG) {
                Text("Keep PNG", comment: "Optimizer: don't convert opaque PNGs").tag(ImageFormat?.none)
                ForEach(ImageFormat.writable.filter { $0 == .jpeg || $0 == .heic }, id: \.self) { f in
                    Text("Convert to \(f.title)", comment: "Optimizer: convert opaque PNGs; the value is JPEG or HEIC").tag(ImageFormat?.some(f))
                }
            } label: {
                RowLabel("PNGs without transparency",
                         subtitle: "Photos saved as PNG shrink much more as JPEG or HEIC. The file’s extension changes.")
            }
            Toggle(isOn: $s.value.image.stripMetadata) {
                RowLabel("Remove metadata",
                         subtitle: "Removes camera details, location and editing history. Orientation and the color profile are kept.")
            }
            Picker(selection: $s.value.image.downscale) {
                ForEach(DownscaleMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Downscale", subtitle: "Applies to every optimized image. Cards can downscale one image further.")
            }
            switch s.value.image.downscale {
            case .off:
                EmptyView()
            case .maxSide:
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(value: $s.value.image.maxSide, format: .number) {
                            Text("Longest side", comment: "Optimizer: maximum image size in pixels")
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        Text("px", comment: "Unit: pixels").foregroundStyle(.secondary)
                        Stepper(value: $s.value.image.maxSide, in: 320...16_000, step: 160) { EmptyView() }.labelsHidden()
                    }
                } label: {
                    RowLabel("Longest side", subtitle: "Smaller images are left at their size.")
                }
            case .factor:
                SliderRow("Scale", value: $s.value.image.factor, in: 0.1...0.9, step: 0.05,
                          format: { $0.formatted(.percent.precision(.fractionLength(0))) })
            }
        } header: {
            Text("Images")
        }
    }

    private var videosSection: some View {
        Section {
            Picker(selection: $s.value.video.codec) {
                ForEach(VideoCodec.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Codec", verbatimSubtitle: s.value.video.codec.subtitle)
            }
            Picker(selection: $s.value.video.quality) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Quality")
            }
            Picker(selection: $s.value.video.maxResolution) {
                ForEach(VideoResolution.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Resolution", subtitle: "Larger videos are scaled down; smaller ones keep their size.")
            }
            Picker(selection: $s.value.video.maxFrameRate) {
                ForEach(FrameRateCap.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Frame rate")
            }
            Picker(selection: $s.value.video.speed) {
                ForEach([1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { v in
                    Text(verbatim: "\(v.formatted(.number.precision(.fractionLength(0...2))))×").tag(v)
                }
            } label: {
                RowLabel("Playback speed", subtitle: "Speeds up screen recordings. The sound keeps its pitch.")
            }
            Toggle(isOn: $s.value.video.removeAudio) {
                RowLabel("Remove audio")
            }
            Toggle(isOn: $s.value.video.convertGIFs) {
                RowLabel("Turn GIFs into MP4 videos", subtitle: "Usually 80–95% smaller. The video is saved next to the GIF.")
            }
        } header: {
            Text("Videos")
        } footer: {
            Text("Videos are encoded on this Mac’s media engine where it has one. A card shows the progress and can cancel.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var pdfSection: some View {
        Section {
            Picker(selection: $s.value.pdf.imageResolution) {
                ForEach(PDFSettings.resolutions, id: \.self) { dpi in
                    Text("\(dpi) dpi", comment: "Optimizer: PDF image resolution, dots per inch").tag(dpi)
                }
            } label: {
                RowLabel("Image resolution", subtitle: "150 dpi is sharp on screen; choose 300 dpi for printing.")
            }
            SliderRow("Image quality", value: Binding(get: { Double(s.value.pdf.imageQuality) }, set: { s.value.pdf.imageQuality = Int($0.rounded()) }),
                      in: 30...100, step: 1, format: { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) })
        } header: {
            Text("PDFs")
        } footer: {
            Text("Only embedded images are re-encoded: text and drawings stay sharp and selectable. Password-protected PDFs are left as they are.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            Toggle(isOn: $s.value.showResults) {
                RowLabel("Show result cards", subtitle: "A card per file with the size saved, Restore, Downscale, Copy and more. Off: a short message instead.")
            }
            cornerRow($s.value.resultsCorner) { RowLabel("Position", subtitle: "Cards stack up in this corner of the screen you’re working on.") }
                .disabled(!s.value.showResults)
            Picker(selection: $s.value.hideResultsAfter) {
                ForEach(AutoHide.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Hide cards after", subtitle: "Cards stay while the pointer is over them.")
            }
            .disabled(!s.value.showResults)
            Picker(selection: $s.value.output) {
                ForEach(OutputMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Optimized files", subtitle: "Originals are kept in the backups folder either way.")
            }
            Toggle(isOn: $s.value.keepModificationDate) {
                RowLabel("Keep the modification date", subtitle: "Files optimized in place stay where they were in date-sorted folders.")
            }
        }
    }

    private var backupsSection: some View {
        Section("Backups") {
            Picker(selection: $s.value.backupRetention) {
                ForEach(BackupRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Keep originals", subtitle: "Restore puts an original back while it’s kept.")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Button { module.revealBackups() } label: { Text("Show in Finder", comment: "Optimizer: reveal the backups folder") }
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete All…", comment: "Optimizer: delete every backup") }
                        .disabled((backupSize ?? 0) == 0)
                }
            } label: {
                RowLabel(title: Text("Backups folder", comment: "Optimizer settings row"),
                         subtitle: backupSize.map {
                             $0 == 0 ? Text("No originals kept yet", comment: "Optimizer: the backups folder is empty")
                                     : Text("\(FileSize.format($0)) used", comment: "Optimizer: disk space used by backups")
                         })
            }
            .alert(Text("Delete all backups?", comment: "Optimizer: confirmation title"), isPresented: $confirmDelete) {
                Button(role: .destructive) {
                    module.center.backups.deleteAll()
                    Task { await refreshBackupSize() }
                } label: { Text("Delete", comment: "Optimizer: confirm deleting backups") }
            } message: {
                Text("Originals of optimized files can no longer be restored.", comment: "Optimizer: confirmation message")
            }
        }
    }

    private var moreSection: some View {
        Section("More") {
            LabeledContent {
                Button { ModuleRegistry.shared.showSettings?("imageresizer") } label: { Text("Open Image Resizer", comment: "Optimizer: link to the Image Resizer page") }
            } label: {
                RowLabel("Resize to preset sizes", subtitle: "Image Resizer resizes many images at once to sizes you name, like Small or Phone.")
            }
            RowLabel("Finder",
                     subtitle: "Select files and choose Services › Optimize with MacToys, Downscale with MacToys or a Convert service, or drop them on this page’s preview.")
        }
    }

    /// A row with the corner's name and the miniature display, centered on the row.
    private func cornerRow(_ corner: Binding<ScreenCorner>, @ViewBuilder label: () -> RowLabel) -> some View {
        HStack(spacing: 12) {
            label()
            Spacer(minLength: 8)
            Text(verbatim: corner.wrappedValue.title).foregroundStyle(.secondary)
            CornerPicker(corner: corner)
        }
    }

    private func refreshBackupSize() async {
        let store = module.center.backups
        backupSize = await Task.detached(priority: .utility) { store.totalSize() }.value
    }
}

/// The watch folder list with Add Folder.
struct WatchFoldersSection: View {
    @Binding var folders: [WatchFolder]

    var body: some View {
        Section {
            if folders.isEmpty {
                Text("No folders yet. Add the folder your screenshots go to, or Downloads.", comment: "Optimizer: empty watch folder list")
                    .foregroundStyle(.secondary)
            }
            ForEach($folders) { $folder in
                WatchFolderRow(folder: $folder) {
                    folders.removeAll { $0.id == folder.id }
                }
            }
            Button {
                addFolder()
            } label: {
                Label { Text("Add Folder…", comment: "Optimizer: add a watch folder") } icon: { Image(systemName: "plus") }
            }
        } header: {
            Text("Watch folders")
        } footer: {
            Text("New files in these folders are optimized as they appear. Subfolders, files already there and files MacToys wrote or restored are left alone.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch", comment: "Optimizer: open panel button to add watch folders")
        panel.message = String(localized: "Choose folders whose new images, videos and PDFs MacToys optimizes.", comment: "Optimizer: open panel message")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            folders.append(WatchFolder(path: (url.path as NSString).abbreviatingWithTildeInPath))
        }
    }
}
