import MacToysCore
import PreviewKit
import SwiftUI

struct FinderAddonsSettingsView: View {
    let module: FinderAddonsModule
    @Bindable var settings: Persisted<FinderAddonsSettings>
    @Bindable var status: StatusModel

    init(module: FinderAddonsModule) {
        self.module = module
        self.settings = module.settings
        self.status = module.status
    }

    /// Size limits in KB.
    private static let sizeChoices = [256, 1024, 5120, 10_240, 25_600, 51_200, 102_400]

    /// "256 KB", "10 MB" in the user's language.
    private static func sizeTitle(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    var body: some View {
        SettingsPage(module: module) {
            hero
        } content: {
            previews
            thumbnails
            sourceCode
            markdown
            graphics
            ownership
        }
        .onAppear { status.refresh() }
    }

    // MARK: Hero

    private var hero: some View {
        HeroCard(tint: .cyan) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Look extensions").font(.system(size: 14, weight: .semibold))
                    StatusLine(title: "Previews", status: status.preview)
                    StatusLine(title: "Thumbnails", status: status.thumbnails)
                    Text("Select a file in Finder and press Space to preview it; thumbnails appear as file icons. The extensions also work while MacToys isn't running.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if status.preview.state == .notRegistered || status.thumbnails.state == .notRegistered {
                        Button("Register Extensions") { status.run { await QuickLookControl.register() } }
                            .buttonStyle(.borderedProminent)
                    } else if status.preview.state == .disabled || status.thumbnails.state == .disabled {
                        Button("Turn On Extensions") { status.run { await QuickLookControl.enable() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Reset Quick Look Cache") {
                        status.run {
                            await QuickLookControl.resetCache()
                            await MainActor.run { HUD.show("Quick Look cache reset", symbol: "doc.viewfinder") }
                        }
                    }
                    Button("Quick Look Extensions…") { QuickLookControl.openExtensionSettings() }
                }
                .disabled(status.busy)
                .fixedSize()
            }
        }
    }

    // MARK: Sections

    private var previews: some View {
        Section("Previews") {
            Toggle(isOn: $settings.value.previewMarkdown) {
                RowLabel("Markdown", subtitle: "GitHub-flavored: tables, task lists, footnotes, highlighted code")
            }
            Toggle(isOn: $settings.value.previewSourceCode) {
                RowLabel("Source code", subtitle: "\(Language.all.count) languages with line numbers — Swift, C, Python, Rust, Go, shell…")
            }
            Toggle(isOn: $settings.value.previewJSONXML) { RowLabel("JSON and XML") }
            Toggle(isOn: $settings.value.previewDelimited) { RowLabel("CSV and TSV", subtitle: "Shown as a table") }
            Toggle(isOn: $settings.value.previewSVG) { RowLabel("SVG images") }
            Toggle(isOn: $settings.value.previewGCode) {
                RowLabel("G-code and binary G-code", subtitle: "Rendered toolpath of 3D prints, CNC and laser jobs")
            }
            Toggle(isOn: $settings.value.previewSTL) { RowLabel("STL models", subtitle: "Shaded 3D render") }
            Toggle(isOn: $settings.value.previewQOI) { RowLabel("QOI images") }
        }
    }

    private var thumbnails: some View {
        Section("Thumbnails") {
            Toggle(isOn: $settings.value.thumbnailSVG) { RowLabel("SVG images") }
            Toggle(isOn: $settings.value.thumbnailGCode) {
                RowLabel("G-code and binary G-code", subtitle: "The slicer's embedded image when there is one, otherwise the toolpath")
            }
            Toggle(isOn: $settings.value.gcodeThumbnailUsesEmbedded) { RowLabel("Prefer the embedded slicer thumbnail") }
                .disabled(!settings.value.thumbnailGCode)
            Toggle(isOn: $settings.value.thumbnailSTL) { RowLabel("STL models") }
            Toggle(isOn: $settings.value.thumbnailQOI) { RowLabel("QOI images") }
            Toggle(isOn: $settings.value.thumbnailMarkdown) { RowLabel("Markdown", subtitle: "A page with the document's headings and text") }
            Toggle(isOn: $settings.value.thumbnailPDF) {
                RowLabel("PDF", subtitle: "macOS normally draws PDF thumbnails itself; this one is used only where it doesn't")
            }
        }
    }

    private var sourceCode: some View {
        Section("Source code") {
            Picker(selection: $settings.value.codeTheme) {
                ForEach(PreviewTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { RowLabel("Color theme") }
            Toggle(isOn: $settings.value.codeWrap) { RowLabel("Wrap long lines") }
            Toggle(isOn: $settings.value.codeLineNumbers) { RowLabel("Show line numbers") }
            SliderRow("Font size", value: $settings.value.codeFontSize, in: 9...24, step: 1) { "\(Int($0)) pt" }
            Toggle(isOn: $settings.value.codeFormat) {
                RowLabel("Format JSON and XML for reading", subtitle: "Re-indents the preview; the file itself is never changed")
            }
            Picker(selection: $settings.value.codeMaxFileSizeKB) {
                ForEach(Self.sizeChoices, id: \.self) { Text(verbatim: Self.sizeTitle($0)).tag($0) }
                if !Self.sizeChoices.contains(settings.value.codeMaxFileSizeKB) {
                    Text(verbatim: Self.sizeTitle(settings.value.codeMaxFileSizeKB)).tag(settings.value.codeMaxFileSizeKB)
                }
            } label: {
                RowLabel("Maximum file size to preview", subtitle: "Larger text files show a notice instead")
            }
        }
    }

    private var markdown: some View {
        Section("Markdown") {
            Picker(selection: $settings.value.markdownTheme) {
                ForEach(PreviewTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { RowLabel("Color theme") }
            Toggle(isOn: $settings.value.markdownShowLocalImages) {
                RowLabel("Show local images", subtitle: "Only images inside the document's folder. In Quick Look the macOS sandbox may still hide them; Peek always shows them.")
            }
            Toggle(isOn: $settings.value.markdownAllowRemoteImages) {
                RowLabel("Allow remote images", subtitle: "Downloads images from the internet when you preview a document, which tells their servers you opened it")
            }
            Toggle(isOn: $settings.value.markdownAllowHTML) {
                RowLabel("Render embedded HTML", subtitle: "Scripts never run; when off, HTML is shown as text")
            }
        }
    }

    private var graphics: some View {
        Group {
            Section("SVG") {
                Picker(selection: $settings.value.svgBackground) {
                    ForEach(ImageBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel("Background", subtitle: "What shows through transparent areas") }
            }
            Section("G-code") {
                Picker(selection: $settings.value.gcodeView) {
                    ForEach(ToolpathStyle.View.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel("View") }
                Toggle(isOn: $settings.value.gcodeShowTravel) { RowLabel("Show travel moves") }
            }
            Section("STL") {
                ColorRow("Model color", color: hexBinding(\.stlColor), supportsOpacity: false)
                ColorRow("Background color", subtitle: "For previews", color: hexBinding(\.stlBackground), supportsOpacity: false)
                Toggle(isOn: $settings.value.stlTransparentThumbnails) { RowLabel("Transparent thumbnail background") }
            }
        }
    }

    private var ownership: some View {
        Section("Which previewer macOS uses") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Look picks one previewer per file type:")
                    .fixedSize(horizontal: false, vertical: true)
                Bullet("Types macOS renders itself — PDF, images, plain text, HTML, and on recent versions SVG and 3D models such as STL — usually keep the system previewer. MacToys fills in where macOS shows only an icon.")
                Bullet("If another app (for example a Markdown or source-code previewer) claims the same type, macOS uses only one of them. Turn the other off in System Settings › General › Login Items & Extensions › Quick Look.")
                Bullet("A file's type comes from its extension. Extensions macOS doesn't know (.rs, .go, .kt…) are declared by MacToys; another app declaring them differently wins for its own files.")
                Bullet("Thumbnails are cached. After changing these settings MacToys resets the cache; use Reset Quick Look Cache if Finder still shows old icons.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    private func hexBinding(_ key: WritableKeyPath<FinderAddonsSettings, String>) -> Binding<RGBA> {
        Binding(get: { RGBA(hex: settings.value[keyPath: key]) ?? .accent },
                set: { settings.value[keyPath: key] = $0.hex })
    }
}

private struct StatusLine: View {
    let title: LocalizedStringKey
    let status: ExtensionStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(verbatim: status.title + (status.version.map { " · \($0)" } ?? "")).font(.system(size: 12)).foregroundStyle(.secondary)
            if status.paths.count > 1 {
                Text(verbatim: "· " + String(localized: "\(status.paths.count) copies registered",
                                             comment: "Quick Look extension status: several builds of MacToys registered the same extension"))
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .help(status.paths.joined(separator: "\n"))
            }
        }
    }

    private var color: Color {
        switch status.state {
        case .enabled: .green
        case .disabled: .orange
        case .notRegistered: .red
        case .unknown: .gray
        }
    }
}

private struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
