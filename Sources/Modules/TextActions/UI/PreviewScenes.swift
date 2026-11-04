import AppKit
import MacToysCore
import SwiftUI

// MARK: - Mock content for the hero and preview scenes

/// A run of text in a mock document; selected runs are highlighted like a text selection.
struct MockSegment {
    var text: String
    var selected = false
    /// The bar or card is attached to this run.
    var anchor = false

    static func plain(_ text: String) -> MockSegment { MockSegment(text: text) }
    static func selected(_ text: String, anchor: Bool = false) -> MockSegment { MockSegment(text: text, selected: true, anchor: anchor) }
}

/// Lines of text laid out as written, with an overlay (the bar, a card) attached above or
/// below the anchor run, the way Text Actions places it next to a selection.
struct MockText<Overlay: View>: View {
    let lines: [[MockSegment]]
    var font: Font = .system(size: 15)
    var lineSpacing: CGFloat = 7
    var below = false
    let overlay: Overlay

    init(_ lines: [[MockSegment]], font: Font = .system(size: 15), lineSpacing: CGFloat = 7, below: Bool = false,
         @ViewBuilder overlay: () -> Overlay) {
        self.lines = lines
        self.font = font
        self.lineSpacing = lineSpacing
        self.below = below
        self.overlay = overlay()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(lines.indices, id: \.self) { li in
                let line = lines[li]
                HStack(spacing: 0) {
                    ForEach(line.indices, id: \.self) { si in
                        let segment = line[si]
                        Text(verbatim: segment.text)
                            .font(font)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .padding(.vertical, 1)
                            .background(segment.selected ? Color(nsColor: .selectedTextBackgroundColor) : .clear)
                            .overlay(alignment: below ? .bottom : .top) {
                                if segment.anchor {
                                    // A zero-size point on the run's edge; the overlay hangs off it.
                                    Color.clear
                                        .frame(width: 0, height: 0)
                                        .overlay(alignment: below ? .top : .bottom) {
                                            overlay
                                                .fixedSize()
                                                .padding(below ? .top : .bottom, 8)
                                        }
                                }
                            }
                            .zIndex(segment.anchor ? 1 : 0)
                    }
                }
                .zIndex(line.contains { $0.anchor } ? 1 : 0)
            }
        }
    }
}

/// The macOS arrow pointer.
struct PointerArrow: View {
    var body: some View {
        PointerShape()
            .fill(.black)
            .overlay(PointerShape().stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)))
            .frame(width: 13, height: 20)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }

    private struct PointerShape: Shape {
        func path(in r: CGRect) -> Path {
            let sx = r.width / 12, sy = r.height / 19
            var p = Path()
            let points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16), CGPoint(x: 4, y: 12.4), CGPoint(x: 6.6, y: 18.4),
                                     CGPoint(x: 9.2, y: 17.3), CGPoint(x: 6.7, y: 11.5), CGPoint(x: 11.6, y: 11.5)]
            p.addLines(points.map { CGPoint(x: r.minX + $0.x * sx, y: r.minY + $0.y * sy) })
            p.closeSubpath()
            return p
        }
    }
}

/// A plain app window frame for preview scenes.
struct MockWindow<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Tint
    let content: Content

    init(title: String, symbol: String, tint: Tint, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                    Circle().fill(c).frame(width: 12, height: 12)
                }
                Spacer()
                HStack(spacing: 7) {
                    ModuleIcon(symbol: symbol, tint: tint, size: 18)
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)))
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            // Not clipped: the bar and cards may reach past the window, as they do on screen.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The shadow belongs to the window shape alone: on the whole stack it would also fall
        // from every line of text and from the bar.
        .background(shape.fill(Color(nsColor: .textBackgroundColor)).shadow(color: .black.opacity(0.35), radius: 30, y: 14))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The design boards' wallpaper.
private let wallpaper = LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)

/// A preview scene on the wallpaper, filling the whole snapshot (under its toolbar too).
private struct SceneStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            wallpaper
            content
        }
        .ignoresSafeArea()
    }
}

/// A static bar model for previews.
@MainActor
func previewBar(_ items: [BarItem], settings: TextActionsSettings, page: BarPage = .main, hovered: Int? = nil,
                keyboard: Int? = nil, below: Bool = false, pointer: Bool = false) -> BarModel {
    let model = BarModel()
    model.reset(items: items, settings: settings, keyboard: keyboard != nil)
    model.page = page
    model.hovered = hovered
    model.highlighted = keyboard
    model.isShown = true
    model.below = below
    model.drawsPointer = pointer
    return model
}

// MARK: - Hero

/// The settings hero: the bar, as configured, over a selection in a small document.
struct TextActionsHero: View {
    let settings: TextActionsSettings

    var body: some View {
        HeroCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 14) {
                HeroStage(settings: settings)
                    .frame(height: 178)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        (settings.autoShow ? Text("Select text in any app") : Text("Select text, then press the shortcut"))
                            .font(.system(size: 14, weight: .semibold))
                        Text("Only actions that fit appear: links open, words are looked up, sums are calculated, JSON is formatted.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if let shortcut = settings.showShortcut { Keycaps(shortcut) }
                }
            }
        }
    }
}

private struct HeroStage: View {
    let settings: TextActionsSettings
    static let sample = "on-device translation"

    var body: some View {
        let analysis = SelectionAnalysis(Self.sample)
        let context = SelectionContext(isEditable: true, clipboardHasText: true)
        var items = BarItems.actions(settings: settings, analysis: analysis, context: context)
        let cap = settings.labelStyle == .icons ? 9 : 5
        if items.count > cap { items = Array(items.prefix(cap)) }
        let hover = items.firstIndex { $0.kind == .builtIn(.translate) }
        let model = previewBar(items, settings: settings, hovered: hover)
        model.visibleCount = min(settings.visibleCount, cap)
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(wallpaper)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.15)).frame(width: 8, height: 8) }
                    Spacer()
                }
                .padding(.bottom, 54 * model.scale + (model.hasCaptionBand ? 26 * model.scale : 0) - 12)
                MockText([
                    [.plain("Fewer round trips: "), .selected(Self.sample, anchor: true), .plain(" keeps drafts private")],
                    [.plain("and works on a plane. The bar only offers what fits the selection.")],
                ], font: .system(size: 13), lineSpacing: 6) {
                    ActionBarView(model: model)
                        .environment(\.colorScheme, .dark)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: 600, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .padding(.horizontal, 24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: the bar above selected text", comment: "Accessibility: settings hero illustration"))
    }
}

// MARK: - Preview scenes

@MainActor
enum TextActionsPreviews {
    static func scenes(settings base: TextActionsSettings) -> [PreviewScene] {
        var s = TextActionsSettings()
        s.visibleCount = 7
        // Two of the examples offered under New Action, as a user would have added them.
        let examples = CustomActionExamples.all
        let github = examples[0], sortLines = examples[1]
        s.add(github)
        s.add(sortLines)
        var labels = s
        labels.labelStyle = .iconsAndLabels
        let size = CGSize(width: 1000, height: 620)
        let editable: [BarItem] = [.builtIn(.cut), .builtIn(.copy), .builtIn(.paste), .builtIn(.search), .builtIn(.translate),
                                   .builtIn(.changeCase), .builtIn(.count), .builtIn(.speak), .custom(github), .custom(sortLines)]

        return [
            PreviewScene("bar", size: size, wallpaper: false) {
                AnyView(SceneStage {
                    notes(selection: "Liquid Glass") {
                        ActionBarView(model: previewBar(editable, settings: s, hovered: 4, pointer: true))
                    }
                })
            },
            PreviewScene("bar-labels", size: size, wallpaper: false) {
                let items: [BarItem] = [.builtIn(.copy), .builtIn(.openLink), .builtIn(.search), .builtIn(.markdownLink),
                                        .builtIn(.count), .builtIn(.speak)]
                return AnyView(SceneStage {
                    mail {
                        ActionBarView(model: previewBar(items, settings: labels, keyboard: 1, below: true))
                    }
                })
            },
            PreviewScene("overflow", size: size, wallpaper: false) {
                AnyView(SceneStage {
                    notes(selection: "Liquid Glass") {
                        ActionBarView(model: previewBar(editable, settings: s, page: .overflow, hovered: 3, pointer: true))
                    }
                })
            },
            PreviewScene("case", size: size, wallpaper: false) {
                AnyView(SceneStage {
                    notes(selection: "Liquid Glass") {
                        ActionBarView(model: previewBar(editable, settings: s, page: .cases, keyboard: 3))
                    }
                })
            },
            PreviewScene("count", size: size, wallpaper: false) {
                AnyView(SceneStage { countScene() })
            },
            PreviewScene("calculation", size: size, wallpaper: false) {
                AnyView(SceneStage { calculationScene() })
            },
            PreviewScene("translation", size: size, wallpaper: false) {
                AnyView(SceneStage { translationScene() })
            },
            PreviewScene("editor", size: CGSize(width: 560, height: 680), wallpaper: false) {
                let action = CustomAction(name: "Word Frequency", symbol: "list.bullet", kind: .shell,
                                          script: "tr -cs '[:alpha:]' '\\n' | tr '[:upper:]' '[:lower:]' \\\n  | sort | uniq -c | sort -rn | head -5",
                                          output: .show)
                return AnyView(CustomActionEditor(action: action, isNew: false,
                                                  trial: .success("   3 the\n   2 glass\n   1 light\n   1 soft\n   1 texture"),
                                                  height: nil, onSave: { _ in }, onDelete: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .ignoresSafeArea())
            },
        ]
    }

    // MARK: Scenes

    /// A note being edited, one phrase selected, the bar (or a card) above it.
    private static func notes<Overlay: View>(selection: String, @ViewBuilder overlay: () -> Overlay) -> some View {
        MockWindow(title: "Notes", symbol: "note.text", tint: .yellow) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: "Launch plan")
                    .font(.system(size: 24, weight: .bold))
                Text(verbatim: "Tuesday, 3 November 2026 at 09:41")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, -12)
                MockText([
                    [.plain("The demo now opens with the "), .selected(selection, anchor: true), .plain(" walkthrough. Keep it")],
                    [.plain("under two minutes: trim the settings tour, keep the translation")],
                    [.plain("example, and send the final cut to the press team by noon.")],
                    [.plain("The release itself ships on Thursday.")],
                ], overlay: overlay)
                .padding(.top, 64)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(width: 720, height: 440)
    }

    /// A message with a link selected, the bar below it.
    private static func mail<Overlay: View>(@ViewBuilder overlay: () -> Overlay) -> some View {
        MockWindow(title: "Mail", symbol: "envelope", tint: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Tint.teal.gradient).frame(width: 34, height: 34)
                        .overlay(Text(verbatim: "MS").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Mara Sato").font(.system(size: 14, weight: .semibold))
                        Text(verbatim: "Re: Launch film — final cut").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                MockText([
                    [.plain("Hi Jonas,")],
                    [.plain(" ")],
                    [.plain("Comments by Thursday would be perfect — the press kit goes out Friday.")],
                    [.plain("The 4K master is up for review: "), .selected("https://review.example.com/launch-film", anchor: true)],
                    [.plain(" ")],
                    [.plain(" ")],
                    [.plain("Thanks, Mara")],
                ], below: true, overlay: overlay)
                .padding(.top, 20)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(width: 760, height: 440)
    }

    private static func countScene() -> some View {
        let lines = ["The new release ships on Thursday. The demo opens on the",
                     "Liquid Glass walkthrough and should stay under two minutes,",
                     "so trim the settings tour and keep the translation example."]
        let card = ResultCard(title: BuiltInAction.count.title, symbol: BuiltInAction.count.symbol, tint: .orange,
                              content: .stats(TextStats(lines.joined(separator: "\n"))), canReplace: false)
        return MockWindow(title: "Notes", symbol: "note.text", tint: .yellow) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: "Launch plan").font(.system(size: 24, weight: .bold))
                MockText([
                    [.selected(lines[0], anchor: true)],
                    [.selected(lines[1])],
                    [.selected(lines[2])],
                    [.plain("Send the final cut to the press team by noon on Wednesday.")],
                ]) {
                    ResultCardView(card: card, scale: 1) { _ in }
                        .environment(\.colorScheme, .dark)
                }
                .padding(.top, 196)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(width: 720, height: 500)
    }

    private static func calculationScene() -> some View {
        let expression = "1,280 × 0.85 + 64"
        let value = ArithmeticEvaluator.evaluateIfExpression(expression) ?? 0
        let card = ResultCard(title: BuiltInAction.calculate.title, symbol: BuiltInAction.calculate.symbol, tint: .orange,
                              content: .calculation(expression: expression, value: value), canReplace: true)
        return MockWindow(title: "Notes", symbol: "note.text", tint: .yellow) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: "Offsite budget").font(.system(size: 24, weight: .bold))
                MockText([
                    [.plain("Venue deposit: "), .selected(expression, anchor: true), .plain(" (member rate, cleaning)")],
                    [.plain("Catering: 42 people × 38 per person")],
                    [.plain("Travel: trains booked, two taxis to confirm")],
                ]) {
                    ResultCardView(card: card, scale: 1) { _ in }
                        .environment(\.colorScheme, .dark)
                }
                .padding(.top, 168)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(width: 720, height: 440)
    }

    private static func translationScene() -> some View {
        let ja = Locale.current.localizedString(forLanguageCode: "ja") ?? "ja"
        let en = Locale.current.localizedString(forLanguageCode: "en") ?? "en"
        let output = OnDeviceTranslator.Output(source: ja, target: en,
                                               text: "The new design is defined by a glass-like texture and soft light that follows the content beneath it.")
        let card = ResultCard(title: BuiltInAction.translate.title, symbol: BuiltInAction.translate.symbol, tint: .indigo,
                              content: .translation(.done(output)), canReplace: false)
        return MockWindow(title: "Safari", symbol: "safari", tint: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: "デザインの新しい方向性")
                    .font(.system(size: 24, weight: .bold))
                Text(verbatim: "今年のアップデートで、画面の見た目が大きく変わりました。")
                    .font(.system(size: 16))
                MockText([
                    [.selected("新しいデザインは、ガラスのような質感と、下にある")],
                    [.selected("コンテンツに寄り添う柔らかな光が特徴です。", anchor: true)],
                ], font: .system(size: 16), lineSpacing: 9, below: true) {
                    ResultCardView(card: card, scale: 1) { _ in }
                        .environment(\.colorScheme, .dark)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(width: 720, height: 460)
    }
}
