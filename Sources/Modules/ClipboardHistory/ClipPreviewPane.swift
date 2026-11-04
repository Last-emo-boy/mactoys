import AppKit
import MacToysCore
import SwiftUI

/// The right side of the panel: a large preview of the selected entry and its details.
struct ClipPreviewPane: View {
    let row: ClipboardPanelModel.Row?
    let now: Date
    /// Two or more marked entries: the pane shows what merging them gives.
    var merging: [ClipItem] = []
    var separator = "\n"
    var onOpen: (URL) -> Void = { _ in }
    @Environment(\.clipStyle) private var style

    var body: some View {
        Group {
            if merging.count > 1 {
                VStack(alignment: .leading, spacing: 14) { mergePreview }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            } else if let row {
                VStack(alignment: .leading, spacing: 14) {
                    switch row.content {
                    case .clip(let item): clip(item)
                    case .snippet(let snippet): snippetPreview(snippet)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(row.id)
                .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 22, weight: .light)).foregroundStyle(style.tertiary)
                    Text("Nothing selected", comment: "Clipboard preview pane without a selection")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(style.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Clip

    @ViewBuilder
    private func clip(_ item: ClipItem) -> some View {
        let type = ClipContentType.of(item)
        HStack(spacing: 8) {
            TypeTile(type: type, size: 22)
            Text(verbatim: type.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(style.secondary)
            Spacer(minLength: 6)
            if item.pinned {
                Label { Text("Pinned", comment: "Badge on a pinned clipboard entry") } icon: { Image(systemName: "pin.fill") }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tint.orange.color)
                    .labelStyle(.titleAndIcon)
            }
        }
        if let name = item.name, !name.isEmpty {
            Text(verbatim: name).font(.system(size: 17, weight: .bold)).foregroundStyle(style.primary).lineLimit(2)
        }
        content(item, type: type)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        details(item, type: type)
    }

    @ViewBuilder
    private func content(_ item: ClipItem, type: ClipContentType) -> some View {
        switch type {
        case .text:
            ScrollView {
                Text(verbatim: String((item.text ?? "").prefix(8000)))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(style.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        case .code:
            ScrollView {
                Text(CodeTint.attributed(item.text ?? ""))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(style.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .scrollIndicators(.never)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.hairline))
        case .richText:
            ScrollView {
                Text(RichText.attributed(item) ?? AttributedString(item.text ?? ""))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .scrollIndicators(.never)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.97)))
            .environment(\.colorScheme, .light)
        case .link:
            link(item)
        case .color:
            swatch(item)
        case .image:
            if let image = ClipThumbnails.image(item, maxPixel: 640) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.stroke))
                    .frame(maxWidth: .infinity, maxHeight: 220)
            }
        case .file:
            files(item)
        }
    }

    private func link(_ item: ClipItem) -> some View {
        let url = ClipText.link(in: item.text ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tint.blue.gradient)
                Image(systemName: url?.scheme == "mailto" ? "envelope.fill" : "globe")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Text(verbatim: url.map(ClipText.host(of:)) ?? "")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(style.primary).lineLimit(2)
            Text(verbatim: item.text ?? "")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(style.secondary).lineLimit(5)
                .textSelection(.enabled)
            if let url {
                Button { onOpen(url) } label: {
                    Label { Text("Open Link") } icon: { Image(systemName: "arrow.up.forward") }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(style.stroke))
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.primary)
            }
        }
    }

    private func swatch(_ item: ClipItem) -> some View {
        let color = ColorValue.parse(item.text ?? "") ?? .black
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.color)
            Text(verbatim: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(ColorSwatch.readableText(on: color))
                .padding(14)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .frame(height: 132)
    }

    @ViewBuilder
    private func files(_ item: ClipItem) -> some View {
        if item.files.count == 1, let url = item.files.first {
            VStack(spacing: 10) {
                Image(nsImage: ClipThumbnails.file(url, maxPixel: 300)).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 130)
                Text(verbatim: url.lastPathComponent).font(.system(size: 14, weight: .semibold)).foregroundStyle(style.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(verbatim: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(style.secondary)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(item.files.prefix(6).enumerated()), id: \.offset) { i, url in
                    HStack(spacing: 9) {
                        Image(nsImage: ClipThumbnails.file(url, maxPixel: 48)).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                        Text(verbatim: url.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(style.primary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    if i < min(item.files.count, 6) - 1 { Rectangle().fill(style.hairline).frame(height: 1) }
                }
                if item.files.count > 6 {
                    Text("and \(item.files.count - 6) more", comment: "More files than the preview lists")
                        .font(.system(size: 11.5)).foregroundStyle(style.secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
        }
    }

    private func details(_ item: ClipItem, type: ClipContentType) -> some View {
        var rows: [(Text, AnyView)] = []
        func add(_ label: Text, _ value: String, mono: Bool = false) {
            rows.append((label, AnyView(Text(verbatim: value).font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .foregroundStyle(style.primary).lineLimit(1).truncationMode(.middle))))
        }
        if let app = item.sourceApp, !app.isEmpty {
            rows.append((Text("Source", comment: "Clipboard detail: the app something was copied from"),
                         AnyView(HStack(spacing: 5) {
                             AppIconView(item: item, size: 14)
                             Text(verbatim: app).font(.system(size: 11.5)).foregroundStyle(style.primary).lineLimit(1)
                         })))
        }
        add(Text("Copied", comment: "Clipboard detail: when the entry was copied"),
            item.date.formatted(date: .abbreviated, time: .shortened))
        switch type {
        case .color:
            let c = ColorValue.parse(item.text ?? "") ?? .black
            add(Text(verbatim: "HEX"), c.hex, mono: true)
            add(Text(verbatim: "RGB"), ColorValue.rgbString(c), mono: true)
            add(Text(verbatim: "HSL"), ColorValue.hslString(c), mono: true)
        case .image:
            if let data = item.image {
                if let size = ClipThumbnails.pixelSize(of: data) {
                    add(Text("Dimensions", comment: "Clipboard detail: image width × height in pixels"), "\(Int(size.width)) × \(Int(size.height))")
                }
                add(Text("Size", comment: "Clipboard detail: data size"), ClipFormat.bytes(data.count))
            }
        case .file:
            if item.files.count > 1 { add(Text("Files", comment: "Clipboard detail: number of files"), item.files.count.formatted()) }
        case .link:
            break
        case .text, .code, .richText:
            let text = item.text ?? ""
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let lines = ClipText.lineCount(text)
            add(Text("Characters", comment: "Clipboard detail: number of characters in a text"), text.count.formatted())
            add(Text("Words", comment: "Clipboard detail: number of words in a text"), words.formatted())
            if lines > 1 { add(Text("Lines", comment: "Clipboard detail: number of lines in a text"), lines.formatted()) }
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 10) {
                    row.0.font(.system(size: 11.5)).foregroundStyle(style.secondary)
                    Spacer(minLength: 8)
                    row.1
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                if i < rows.count - 1 { Rectangle().fill(style.hairline).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.hairline))
    }

    // MARK: Selection

    @ViewBuilder
    private var mergePreview: some View {
        let merged = ClipMerge.merge(merging, separator: separator)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(Tint.indigo.color.opacity(0.25))
                .overlay {
                    Image(systemName: "arrow.triangle.merge").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Tint.indigo.nsColor.blended(withFraction: 0.3, of: .white) ?? Tint.indigo.nsColor))
                }
                .frame(width: 22, height: 22)
            Text("Merged", comment: "Clipboard preview header when several entries are selected: what merging them gives")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(style.secondary)
        }
        Group {
            if let merged, merged.kind == .files {
                files(merged)
            } else if let merged {
                ScrollView {
                    Text(verbatim: String((merged.text ?? "").prefix(8000)))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(style.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .scrollIndicators(.never)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.hairline))
            } else {
                Text("These entries have no text to merge.", comment: "Clipboard preview: the selected entries (images) can't be merged")
                    .font(.system(size: 12.5)).foregroundStyle(style.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        mergeDetails(merged)
    }

    private func mergeDetails(_ merged: ClipItem?) -> some View {
        var rows: [(Text, String)] = [(Text("Entries", comment: "Clipboard detail: number of selected entries"), merging.count.formatted())]
        if let text = merged?.text, merged?.kind != .files {
            rows.append((Text("Characters", comment: "Clipboard detail: number of characters in a text"), text.count.formatted()))
        }
        let apps = Array(Set(merging.compactMap(\.sourceApp).filter { !$0.isEmpty })).sorted()
        if !apps.isEmpty {
            rows.append((Text("From", comment: "Clipboard detail: the apps the selected entries were copied from"),
                         apps.formatted(.list(type: .and))))
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 10) {
                    row.0.font(.system(size: 11.5)).foregroundStyle(style.secondary)
                    Spacer(minLength: 8)
                    Text(verbatim: row.1).font(.system(size: 11.5)).foregroundStyle(style.primary).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                if i < rows.count - 1 { Rectangle().fill(style.hairline).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.hairline))
    }

    // MARK: Snippet

    @ViewBuilder
    private func snippetPreview(_ snippet: Snippet) -> some View {
        HStack(spacing: 8) {
            SnippetTile(size: 22)
            Text("Snippet", comment: "Clipboard preview header for a saved snippet")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(style.secondary)
            Spacer(minLength: 6)
            if !snippet.abbreviation.isEmpty { AbbreviationChip(text: snippet.abbreviation) }
        }
        Text(verbatim: snippet.name).font(.system(size: 17, weight: .bold)).foregroundStyle(style.primary).lineLimit(2)
        // Sized to the text, so a short snippet doesn't sit in a tall empty box.
        Text(ClipTextStyle.template(String(snippet.text.prefix(2000))))
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .lineLimit(14)
            .foregroundStyle(style.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.hairline))
        if snippet.text.contains("{") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Pastes as", comment: "Snippet preview: heading above the expanded text")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(style.tertiary)
                Text(verbatim: SnippetExpander.expand(snippet.text, date: now,
                                                      clipboard: String(localized: "(clipboard text)", comment: "Snippet preview: stands in for the clipboard")).text)
                    .font(.system(size: 12)).foregroundStyle(style.secondary).lineLimit(6)
            }
        }
        Spacer(minLength: 0)
    }
}

/// Formatted text for the preview, from RTF (or HTML), cached per entry.
@MainActor
enum RichText {
    private static var cache: [UUID: AttributedString] = [:]

    static func attributed(_ item: ClipItem) -> AttributedString? {
        if let hit = cache[item.id] { return hit }
        var ns: NSAttributedString?
        if let rtf = item.rtf { ns = NSAttributedString(rtf: rtf, documentAttributes: nil) }
        if ns == nil, let html = item.html, html.utf8.count < 200_000, let data = html.data(using: .utf8) {
            ns = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        guard let ns else { return nil }
        var out = AttributedString()
        let limit = min(ns.length, 6000)
        ns.enumerateAttributes(in: NSRange(location: 0, length: limit)) { attrs, range, _ in
            var run = AttributedString(ns.attributedSubstring(from: range).string)
            if let font = attrs[.font] as? NSFont {
                let size = min(max(font.pointSize * 0.92, 10), 22)
                run.font = Font(NSFont(descriptor: font.fontDescriptor, size: size) ?? font)
            } else {
                run.font = .system(size: 12)
            }
            if let color = attrs[.foregroundColor] as? NSColor { run.foregroundColor = Color(nsColor: color) }
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 { run.underlineStyle = .single }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { run.strikethroughStyle = .single }
            if attrs[.link] != nil {
                run.foregroundColor = Color(nsColor: .linkColor)
                run.underlineStyle = .single
            }
            out += run
        }
        if cache.count > 64 { cache.removeAll() }
        cache[item.id] = out
        return out
    }
}
