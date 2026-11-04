import AppKit
import MacToysCore
import SwiftUI

/// A result next to the selection: counts, a calculation, a translation, a definition, a
/// script's output or an error.
struct ResultCardView: View {
    let card: ResultCard
    let scale: CGFloat
    var copied = false
    var keyboard = false
    let onAction: (CardAction) -> Void

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 12 * s) {
            header
            content
            buttons
        }
        .padding(14 * s)
        .frame(width: BarMetrics.cardWidth * s, alignment: .leading)
        .background { BarGlass(shape: RoundedRectangle(cornerRadius: 18 * s, style: .continuous)) }
    }

    // MARK: Header

    private var header: some View {
        let s = scale
        let tint = card.isError ? Tint.red : card.tint
        return HStack(spacing: 8 * s) {
            Image(systemName: card.isError ? "exclamationmark.triangle.fill" : card.symbol)
                .font(.system(size: 11 * s, weight: .bold))
                .foregroundStyle(tint.color)
                .frame(width: 22 * s, height: 22 * s)
                .background(Circle().fill(tint.color.opacity(0.2)))
            Text(verbatim: card.title)
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8 * s)
            if keyboard {
                Text("esc", comment: "Keycap label: the Escape key")
                    .font(.system(size: 10 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 5 * s)
                    .padding(.vertical, 2 * s)
                    .background(RoundedRectangle(cornerRadius: 4 * s).strokeBorder(.white.opacity(0.18)))
            }
            Button {
                onAction(.close)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * s, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20 * s, height: 20 * s)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close", comment: "Accessibility: close the result card"))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let s = scale
        switch card.content {
        case .stats(let stats):
            StatsContent(stats: stats, scale: s)
        case .calculation(let expression, let value):
            VStack(alignment: .leading, spacing: 4 * s) {
                Text(verbatim: expression)
                    .font(.system(size: 12 * s, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                    Text(verbatim: "=")
                        .font(.system(size: 22 * s, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(verbatim: ArithmeticEvaluator.display(value))
                        .font(.system(size: 30 * s, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                }
            }
        case .translation(let state):
            translation(state)
        case .definition(let word, let text):
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(verbatim: word)
                    .font(.system(size: 17 * s, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: text)
                    .font(.system(size: 12.5 * s))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(9)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .output(let text):
            if text.isEmpty {
                Text("The action finished without output.")
                    .font(.system(size: 12.5 * s))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                longText(text, monospaced: true)
            }
        case .message(let text):
            Text(verbatim: text)
                .font(.system(size: 12.5 * s))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func translation(_ state: ResultCard.Translation) -> some View {
        let s = scale
        switch state {
        case .working(let target):
            HStack(spacing: 8 * s) {
                ProgressView().controlSize(.small)
                Text("Translating into \(target) on this Mac…",
                     comment: "Text Actions: translation in progress; %@ is the target language")
                    .font(.system(size: 12.5 * s))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6 * s)
        case .done(let output):
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 5 * s) {
                    Text(verbatim: output.source)
                    Image(systemName: "arrow.right").font(.system(size: 9 * s, weight: .bold))
                    Text(verbatim: output.target)
                }
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                longText(output.text, monospaced: false)
            }
        case .failed(let message, _):
            Text(verbatim: message)
                .font(.system(size: 12.5 * s))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Short text grows the card; long text scrolls inside a fixed height.
    @ViewBuilder
    private func longText(_ text: String, monospaced: Bool) -> some View {
        let s = scale
        let font: Font = monospaced ? .system(size: 12 * s, design: .monospaced) : .system(size: 14 * s)
        let label = Text(verbatim: text)
            .font(font)
            .foregroundStyle(.white)
            .lineSpacing(2 * s)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if text.count > 420 || text.split(whereSeparator: \.isNewline).count > 9 {
            ScrollView { label.fixedSize(horizontal: false, vertical: true) }
                .frame(height: 210 * s)
                .scrollIndicators(.automatic)
        } else {
            label.fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        let s = scale
        let actions = buttonList
        if !actions.isEmpty {
            HStack(spacing: 6 * s) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, button in
                    CardButton(title: button.title, symbol: button.symbol, prominent: index == 0, scale: s,
                               confirmed: copied && button.isCopy) { onAction(button.action) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct ButtonSpec {
        var title: String
        var symbol: String
        var action: CardAction
        var isCopy = false
    }

    private var buttonList: [ButtonSpec] {
        var list: [ButtonSpec] = []
        if let text = card.copyText, !card.isError {
            if case .definition(let word, _) = card.content {
                list.append(ButtonSpec(title: String(localized: "Open in Dictionary"), symbol: "character.book.closed",
                                       action: .openDictionary(word)))
                return list
            }
            list.append(ButtonSpec(title: String(localized: "Copy", comment: "Result card button: copy the result"),
                                   symbol: "doc.on.doc", action: .copy(text), isCopy: true))
            if card.canReplace {
                list.append(ButtonSpec(title: String(localized: "Replace", comment: "Result card button: replace the selection with the result"),
                                       symbol: "text.insert", action: .replace(text)))
            }
            if case .calculation(let expression, _) = card.content, card.canReplace {
                let appended = expression.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s*=\s*$"#, with: "", options: .regularExpression) + " = " + text
                list.append(ButtonSpec(title: String(localized: "Append Result", comment: "Result card button: write “= result” after the expression"),
                                       symbol: "equal", action: .replace(appended)))
            }
        }
        if case .translation(.failed(_, let offerSettings)) = card.content, offerSettings {
            list.append(ButtonSpec(title: String(localized: "Language Settings…", comment: "Button: open Language & Region settings to download translation languages"),
                                   symbol: "globe", action: .openLanguageSettings))
        }
        return list
    }
}

/// Characters, words and lines as three tiles.
private struct StatsContent: View {
    let stats: TextStats
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(spacing: 6 * s) {
                tile(stats.characters, Text("Characters", comment: "Count card: number of characters"))
                tile(stats.words, Text("Words", comment: "Count card: number of words"))
                tile(stats.lines, Text("Lines", comment: "Count card: number of lines"))
            }
            Text("\(stats.charactersExcludingSpaces.formatted()) without spaces · about \(Self.reading(stats.readingTime)) to read",
                 comment: "Count card footer; first %@ is a number of characters, second a duration like “2 min”")
                .font(.system(size: 11.5 * s))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func reading(_ duration: Duration) -> String {
        duration < .seconds(60)
            ? duration.formatted(.units(allowed: [.seconds], width: .abbreviated))
            : duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    private func tile(_ value: Int, _ label: Text) -> some View {
        let s = scale
        return VStack(alignment: .leading, spacing: 2 * s) {
            Text(verbatim: value.formatted())
                .font(.system(size: 22 * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            label
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10 * s)
        .padding(.vertical, 8 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * s, style: .continuous).fill(.white.opacity(0.07)))
    }
}

/// A compact capsule button on a result card.
struct CardButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let scale: CGFloat
    var confirmed = false
    let action: () -> Void

    var body: some View {
        let s = scale
        Button(action: action) {
            HStack(spacing: 5 * s) {
                Image(systemName: confirmed ? "checkmark" : symbol)
                    .font(.system(size: 10.5 * s, weight: .semibold))
                Text(verbatim: confirmed ? String(localized: "Copied", comment: "Confirmation after copying a result") : title)
                    .font(.system(size: 12 * s, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10 * s)
            .frame(height: 26 * s)
            .contentShape(Capsule())
        }
        .buttonStyle(CardButtonStyle(prominent: prominent))
    }
}

struct CardButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
                                                 : .white.opacity(configuration.isPressed ? 0.24 : 0.12)))
    }
}
