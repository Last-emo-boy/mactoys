import AppKit
import MacToysCore
import SwiftUI

/// Colors of the dark glass panel (the Command Palette's palette), a step stronger with Increase Contrast.
struct ClipStyle {
    var highContrast = false

    var primary: Color { .white.opacity(highContrast ? 1 : 0.94) }
    var secondary: Color { .white.opacity(highContrast ? 0.78 : 0.58) }
    var tertiary: Color { .white.opacity(highContrast ? 0.6 : 0.38) }
    var hairline: Color { .white.opacity(highContrast ? 0.22 : 0.09) }
    var card: Color { .white.opacity(highContrast ? 0.1 : 0.05) }
    var selection: Color { .white.opacity(highContrast ? 0.2 : 0.11) }
    var stroke: Color { .white.opacity(highContrast ? 0.3 : 0.13) }

    static let snippetTint = Tint.yellow
}

extension EnvironmentValues {
    @Entry var clipStyle = ClipStyle()
}

/// The dark Liquid Glass shell of the panel, the bar and the HUD (solid with Reduce Transparency).
struct ClipGlass: ViewModifier {
    var cornerRadius: CGFloat
    /// How much of the dark tint backs the glass: menus and dialogs inside the panel need it nearly opaque.
    var backing: Double = 0.55
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .environment(\.clipStyle, ClipStyle(highContrast: contrast == .increased))
            .background(reduceTransparency ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.11, green: 0.11, blue: 0.13).opacity(backing))
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.32 : 0.13), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func clipGlass(cornerRadius: CGFloat, backing: Double = 0.55) -> some View {
        modifier(ClipGlass(cornerRadius: cornerRadius, backing: backing))
    }
}

/// A keycap in the panel's footer and menus.
struct KeyCap: View {
    let key: String
    @Environment(\.clipStyle) private var style

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(style.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// "Paste ↩"
struct KeyHint: View {
    let title: Text
    let keys: [String]
    @Environment(\.clipStyle) private var style

    var body: some View {
        HStack(spacing: 6) {
            title.font(.system(size: 12)).foregroundStyle(style.secondary).lineLimit(1)
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap(key: $0) } }
        }
        .fixedSize()
    }
}

// MARK: Icons

/// The leading visual of a row: a type tile, a color swatch, an image or a file thumbnail.
struct ClipIcon: View {
    let item: ClipItem
    var size: CGFloat = 32

    var body: some View {
        let type = ClipContentType.of(item)
        let radius = size * 0.25
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            switch type {
            case .color:
                shape.fill((ColorValue.parse(item.text ?? "") ?? .black).color)
                    .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 1))
            case .image:
                if let image = ClipThumbnails.image(item, maxPixel: Int(size * 2)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size).clipShape(shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
                } else {
                    TypeTile(type: type, size: size)
                }
            case .file:
                if let url = item.files.first {
                    let picture = ClipThumbnails.isPictureFile(url)
                    Image(nsImage: ClipThumbnails.file(url, maxPixel: Int(size * 2)))
                        .resizable().aspectRatio(contentMode: picture ? .fill : .fit)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: picture ? radius : 0, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if item.files.count > 1 { CountBadge(count: item.files.count) }
                        }
                } else {
                    TypeTile(type: type, size: size)
                }
            default:
                TypeTile(type: type, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A tinted tile with the type's symbol.
struct TypeTile: View {
    let type: ClipContentType
    var size: CGFloat = 32

    var body: some View {
        let color = type == .text ? Color.white : type.tint.color
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(color.opacity(type == .text ? 0.09 : 0.2))
            .overlay {
                Image(systemName: type.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(type == .text ? Color.white.opacity(0.7) : Color(nsColor: type.tint.nsColor.blended(withFraction: 0.25, of: .white) ?? type.tint.nsColor))
            }
            .frame(width: size, height: size)
    }
}

struct SnippetTile: View {
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(ClipStyle.snippetTint.color.opacity(0.2))
            .overlay {
                Image(systemName: "text.quote")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(ClipStyle.snippetTint.color)
            }
            .frame(width: size, height: size)
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count.formatted())
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(Color.accentColor))
            .offset(x: 4, y: 4)
    }
}

/// The source app's icon, small.
struct AppIconView: View {
    let item: ClipItem
    var size: CGFloat = 14

    var body: some View {
        if let icon = AppIcons.icon(bundleID: item.sourceBundleID, name: item.sourceApp) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        }
    }
}

/// The abbreviation of a snippet, as a small monospaced chip.
struct AbbreviationChip: View {
    let text: String
    @Environment(\.clipStyle) private var style

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(ClipStyle.snippetTint.color)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(Capsule().fill(ClipStyle.snippetTint.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(ClipStyle.snippetTint.color.opacity(0.3)))
            .fixedSize()
    }
}

// MARK: Text

enum ClipTextStyle {
    /// Title of a row: monospaced for code and colors.
    static func titleFont(_ type: ClipContentType, size: CGFloat = 13.5) -> Font {
        switch type {
        case .code, .color: .system(size: size - 1, weight: .medium, design: .monospaced)
        default: .system(size: size, weight: .medium)
        }
    }

    /// "Safari · 4 min ago · github.com"; for a named entry the content takes the detail's place.
    static func subtitle(_ item: ClipItem, now: Date) -> String {
        var parts: [String] = []
        if let app = item.sourceApp, !app.isEmpty { parts.append(app) }
        parts.append(ClipFormat.relative(item.date, now: now))
        let named = !(item.name ?? "").isEmpty
        if let extra = (named ? content(item) : nil) ?? detail(item) { parts.append(extra) }
        return parts.joined(separator: " · ")
    }

    /// The content in a few words, for entries whose title is a name.
    static func content(_ item: ClipItem) -> String? {
        switch item.kind {
        case .image: return nil
        case .files: return item.files.first?.lastPathComponent
        default:
            let text = ClipText.oneLine(item.text ?? "", limit: 80)
            return text.isEmpty ? nil : text
        }
    }

    /// Short fact about the content: link host, line count, dimensions, file count.
    static func detail(_ item: ClipItem) -> String? {
        switch ClipContentType.of(item) {
        case .link: return ClipText.link(in: item.text ?? "").map(ClipText.host(of:))
        case .image: return item.image.flatMap(ClipThumbnails.pixelSize(of:)).map { "\(Int($0.width)) × \(Int($0.height))" }
        case .code, .text, .richText:
            let lines = ClipText.lineCount(item.text ?? "")
            return lines > 1 ? String(localized: "\(lines) lines", comment: "Line count of a clipboard entry") : nil
        case .file:
            return item.files.count > 1 ? nil : item.files.first.map { $0.deletingLastPathComponent().lastPathComponent }
        case .color: return nil
        }
    }

    /// Highlights `{placeholders}` in a snippet template.
    static func template(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text.prefix(4000))
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += AttributedString(String(rest[rest.startIndex..<open]))
            var token = AttributedString(String(rest[open...close]))
            token.foregroundColor = ClipStyle.snippetTint.color
            token.font = .system(size: 12.5, weight: .semibold, design: .monospaced)
            out += token
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

/// A light syntax tint for code previews: comments, strings, numbers and common keywords.
enum CodeTint {
    private static let keywords: Set<String> = [
        "func", "def", "class", "struct", "enum", "protocol", "extension", "let", "var", "const", "import", "return",
        "if", "else", "for", "while", "in", "guard", "switch", "case", "default", "try", "catch", "throw", "async", "await",
        "public", "private", "static", "self", "true", "false", "nil", "null", "None", "new", "function", "fn", "pub",
        "SELECT", "FROM", "WHERE", "JOIN", "ORDER", "BY", "GROUP", "INSERT", "UPDATE", "DELETE", "sudo", "git", "swift",
    ]

    static func attributed(_ code: String) -> AttributedString {
        let text = String(code.prefix(6000))
        var out = AttributedString()
        let comment = Color(red: 0.5, green: 0.55, blue: 0.6)
        let string = Color(red: 0.99, green: 0.47, blue: 0.4)
        let number = Color(red: 0.85, green: 0.79, blue: 0.49)
        let keyword = Color(red: 1, green: 0.48, blue: 0.7)
        var i = text.startIndex
        func append(_ s: Substring, _ color: Color?) {
            var piece = AttributedString(String(s))
            if let color { piece.foregroundColor = color }
            out += piece
        }
        while i < text.endIndex {
            let ch = text[i]
            if ch == "/", text[i...].hasPrefix("//") {
                let end = text[i...].firstIndex(of: "\n") ?? text.endIndex
                append(text[i..<end], comment)
                i = end
            } else if ch == "#", i == text.startIndex || text[text.index(before: i)] == "\n" || text[text.index(before: i)] == " " {
                let end = text[i...].firstIndex(of: "\n") ?? text.endIndex
                append(text[i..<end], comment)
                i = end
            } else if ch == "\"" || ch == "'" || ch == "`" {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != ch, text[j] != "\n" {
                    j = text[j] == "\\" && text.index(after: j) < text.endIndex ? text.index(j, offsetBy: 2) : text.index(after: j)
                }
                let end = j < text.endIndex && text[j] == ch ? text.index(after: j) : j
                append(text[i..<end], string)
                i = end
            } else if ch.isLetter || ch == "_" {
                var j = i
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" { j = text.index(after: j) }
                let word = text[i..<j]
                append(word, keywords.contains(String(word)) ? keyword : nil)
                i = j
            } else if ch.isNumber {
                var j = i
                while j < text.endIndex, text[j].isNumber || text[j] == "." { j = text.index(after: j) }
                append(text[i..<j], number)
                i = j
            } else {
                append(text[i...i], nil)
                i = text.index(after: i)
            }
        }
        return out
    }
}

// MARK: Rows

/// One entry in the panel's list.
struct ClipRowView: View {
    let row: ClipboardPanelModel.Row
    let selected: Bool
    let marked: Bool
    let now: Date
    @Environment(\.clipStyle) private var style

    var body: some View {
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                title
                subtitle
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(marked ? Color.accentColor.opacity(selected ? 0.42 : 0.26) : selected ? style.selection : .clear)
        )
        .overlay {
            if selected, marked {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leading: some View {
        switch row.content {
        case .clip(let item): ClipIcon(item: item, size: 32)
        case .snippet: SnippetTile(size: 32)
        }
    }

    @ViewBuilder private var title: some View {
        switch row.content {
        case .clip(let item):
            let type = ClipContentType.of(item)
            HStack(spacing: 6) {
                Text(verbatim: item.displayTitle)
                    .font(item.name != nil ? .system(size: 13.5, weight: .semibold) : ClipTextStyle.titleFont(type))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .snippet(let snippet):
            Text(verbatim: snippet.name.isEmpty ? ClipText.firstLine(snippet.text, limit: 80) : snippet.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(style.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch row.content {
        case .clip(let item):
            HStack(spacing: 5) {
                AppIconView(item: item, size: 13)
                Text(verbatim: ClipTextStyle.subtitle(item, now: now)).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(style.secondary)
        case .snippet(let snippet):
            Text(verbatim: ClipText.firstLine(snippet.text, limit: 120))
                .font(.system(size: 11.5))
                .foregroundStyle(style.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if let snippet = row.snippet, !snippet.abbreviation.isEmpty {
                AbbreviationChip(text: snippet.abbreviation)
            }
            if row.clip?.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tint.orange.color)
                    .rotationEffect(.degrees(35))
                    .accessibilityLabel(Text("Pinned", comment: "Accessibility: the clipboard entry is pinned"))
            }
            if let n = row.number {
                Text(verbatim: "⌘\(n)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(selected ? style.secondary : style.tertiary)
            }
        }
    }
}

/// One entry in the paste bar.
struct ClipCardView: View {
    let row: ClipboardPanelModel.Row
    let selected: Bool
    let marked: Bool
    let now: Date
    @Environment(\.clipStyle) private var style

    static let size = CGSize(width: 208, height: 196)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            header
            body(of: row.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(shape.fill(Color.white.opacity(0.07)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Color.accentColor : marked ? Color.accentColor.opacity(0.6) : style.stroke,
                                    lineWidth: selected ? 2.5 : marked ? 2 : 1))
        .shadow(color: .black.opacity(selected ? 0.35 : 0.15), radius: selected ? 10 : 4, y: selected ? 4 : 2)
        .contentShape(shape)
    }

    private var tint: Tint {
        switch row.content {
        case .clip(let item): ClipContentType.of(item).tint
        case .snippet: ClipStyle.snippetTint
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            switch row.content {
            case .clip(let item):
                let type = ClipContentType.of(item)
                Image(systemName: type.symbol).font(.system(size: 11, weight: .semibold))
                Text(verbatim: item.name ?? type.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                AppIconView(item: item, size: 18)
            case .snippet(let snippet):
                Image(systemName: "text.quote").font(.system(size: 11, weight: .semibold))
                Text(verbatim: snippet.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            LinearGradient(colors: [tint.color.opacity(0.75), tint.color.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
        )
    }

    @ViewBuilder
    private func body(of content: ClipboardPanelModel.Row.Content) -> some View {
        switch content {
        case .snippet(let snippet):
            VStack(alignment: .leading, spacing: 8) {
                Text(ClipTextStyle.template(snippet.text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(style.primary)
                    .lineLimit(5)
                if !snippet.abbreviation.isEmpty { AbbreviationChip(text: snippet.abbreviation) }
            }
            .padding(11)
        case .clip(let item):
            switch ClipContentType.of(item) {
            case .image:
                if let image = ClipThumbnails.image(item, maxPixel: 440) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Self.size.width, height: Self.size.height - 34 - 28).clipped()
                }
            case .color:
                let color = ColorValue.parse(item.text ?? "") ?? .black
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(color.color)
                    Text(verbatim: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ColorSwatch.readableText(on: color))
                        .padding(11)
                }
            case .link:
                let url = ClipText.link(in: item.text ?? "")
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: url.map(ClipText.host(of:)) ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(style.primary)
                        .lineLimit(2)
                    Text(verbatim: item.text ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(style.secondary)
                        .lineLimit(4)
                }
                .padding(11)
            case .file:
                VStack(spacing: 8) {
                    if let url = item.files.first {
                        Image(nsImage: ClipThumbnails.file(url, maxPixel: 160)).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 74)
                    }
                    Text(verbatim: item.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
            case .code:
                // Code keeps its lines: each is cut at the card's edge instead of wrapping.
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(Array(Self.codeLines(item.text ?? "").enumerated()), id: \.offset) { _, line in
                        Text(CodeTint.attributed(line)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(style.primary)
                .padding(11)
            case .text, .richText:
                Text(verbatim: String((item.text ?? "").prefix(600)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(style.primary)
                    .lineLimit(7)
                    .padding(11)
            }
        }
    }

    private static func codeLines(_ text: String) -> [String] {
        text.prefix(1200).split(separator: "\n", maxSplits: 9, omittingEmptySubsequences: false).prefix(9)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch row.content {
            case .clip(let item):
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Tint.orange.color)
                }
                Text(verbatim: ClipFormat.relative(item.date, now: now)).lineLimit(1)
            case .snippet:
                Text("Snippet", comment: "Label on a snippet card in the paste bar")
            }
            Spacer(minLength: 4)
            if let n = row.number { Text(verbatim: "⌘\(n)").monospacedDigit() }
        }
        .font(.system(size: 11))
        .foregroundStyle(style.tertiary)
        .padding(.horizontal, 11)
        .frame(height: 28)
    }
}

enum ColorSwatch {
    /// Black or white, whichever reads better on `color`.
    static func readableText(on color: RGBA) -> Color {
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.6 && color.alpha > 0.5 ? .black.opacity(0.8) : .white
    }
}
