import MacToysCore
import SwiftUI

/// What the overlay shows right now.
@MainActor
@Observable
final class KeystrokeOverlayModel {
    var feed = KeystrokeFeed()
    var visible = false
    var settings = KeystrokeSettings()
}

/// Metrics and colors of the pill for a theme and size. Radii are concentric: keycap radius plus
/// the pill's padding gives the pill's radius.
struct PillStyle {
    let theme: KeystrokeSettings.Theme
    let size: KeystrokeSettings.Size
    var reduceTransparency = false
    var increaseContrast = false

    var font: CGFloat { size.fontSize }
    var keyHeight: CGFloat { (font * 1.7).rounded() }
    var keyRadius: CGFloat { (font * 0.38).rounded() }
    var padding: CGFloat { (font * 0.42).rounded() }
    var pillRadius: CGFloat { keyRadius + padding }
    var itemGap: CGFloat { (font * 0.8).rounded() }
    var keyGap: CGFloat { max(3, (font * 0.2).rounded()) }

    /// Glass falls back to the solid dark style with Reduce Transparency.
    var effectiveTheme: KeystrokeSettings.Theme { theme == .glass && reduceTransparency ? .dark : theme }
    var isLight: Bool { effectiveTheme == .light }

    var foreground: Color { isLight ? Color(white: 0.1) : .white }
    var secondary: Color { isLight ? Color(white: 0.1).opacity(increaseContrast ? 0.85 : 0.62) : .white.opacity(increaseContrast ? 0.92 : 0.72) }
    var accent: Color { isLight ? Color(nsColor: Tint.orange.nsColor) : Color(nsColor: Tint.yellow.nsColor) }

    var keyFill: LinearGradient {
        switch effectiveTheme {
        case .glass:
            LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)
        case .dark:
            LinearGradient(colors: [Color(white: 0.27), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
        case .light:
            LinearGradient(colors: [.white, Color(white: 0.955)], startPoint: .top, endPoint: .bottom)
        }
    }

    var keyStroke: Color {
        let boost = increaseContrast ? 2.0 : 1.0
        return isLight ? .black.opacity(0.13 * boost) : .white.opacity(0.16 * boost)
    }

    /// The darker bottom edge that gives keycaps their depth.
    var keyEdge: Color { isLight ? .black.opacity(0.14) : .black.opacity(0.45) }
}

/// One keycap.
struct KeyCapView: View {
    let label: String
    let style: PillStyle

    var body: some View {
        // Words ("esc", "Space", "F12") are set smaller than single glyphs so caps keep one height.
        let word = label.count > 1
        Text(verbatim: label)
            .font(.system(size: style.font * (word ? 0.72 : 1), weight: .semibold))
            .foregroundStyle(style.foreground)
            .lineLimit(1)
            .padding(.horizontal, style.font * (word ? 0.5 : 0.36))
            .frame(minWidth: style.keyHeight, minHeight: style.keyHeight)
            .background {
                RoundedRectangle(cornerRadius: style.keyRadius, style: .continuous)
                    .fill(style.keyFill)
                    .shadow(color: style.keyEdge, radius: 0, y: max(1, style.font * 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: style.keyRadius, style: .continuous)
                    .strokeBorder(style.keyStroke, lineWidth: 1)
            }
            .fixedSize()
    }
}

/// One entry of the pill: a shortcut with its name, typed text, a click or the privacy notice.
struct KeystrokeItemView: View {
    let item: KeystrokeFeed.Item
    let style: PillStyle

    var body: some View {
        HStack(spacing: style.keyGap) {
            switch item.content {
            case .keys(let keys, let name):
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCapView(label: key, style: style) }
                if let name {
                    Text(verbatim: name)
                        .font(.system(size: style.font * 0.8, weight: .medium))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                        .padding(.leading, style.font * 0.3)
                }
            case .text(let text):
                Text(verbatim: text)
                    .font(.system(size: style.font * 1.05, weight: .medium))
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: style.keyHeight)
                    .padding(.horizontal, style.font * 0.25)
            case .click(let click):
                ForEach(Array(click.modifiers.enumerated()), id: \.offset) { _, key in KeyCapView(label: key, style: style) }
                Image(systemName: click.count > 1 ? "cursorarrow.click.2" : "cursorarrow.click")
                    .font(.system(size: style.font * 0.95, weight: .semibold))
                    .foregroundStyle(style.foreground)
                    .frame(minHeight: style.keyHeight)
                    .padding(.leading, click.modifiers.isEmpty ? style.font * 0.2 : style.font * 0.15)
                Text(verbatim: Self.title(of: click))
                    .font(.system(size: style.font * 0.8, weight: .medium))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            case .hidden:
                Image(systemName: "lock.fill")
                    .font(.system(size: style.font * 0.8, weight: .semibold))
                    .foregroundStyle(style.foreground)
                    .frame(minHeight: style.keyHeight)
                    .padding(.leading, style.font * 0.2)
                Text("Typing hidden in a password field")
                    .font(.system(size: style.font * 0.8, weight: .medium))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
                    .padding(.trailing, style.font * 0.2)
            }
            if item.count > 1 {
                Text(verbatim: "×\(item.count.formatted())")
                    .font(.system(size: style.font * 0.8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(style.accent)
                    .padding(.leading, style.font * 0.2)
                    .contentTransition(.numericText())
            }
        }
        .fixedSize()
    }

    static func title(of click: KeystrokeFeed.Click) -> String {
        switch (click.button, click.count) {
        case (.left, 2): String(localized: "Double Click", comment: "Keystroke Overlay: a double click with the main button")
        case (.left, 3...): String(localized: "Triple Click", comment: "Keystroke Overlay: a triple click with the main button")
        case (.left, _): String(localized: "Click", comment: "Keystroke Overlay: a click with the main mouse button")
        case (.right, _): String(localized: "Right Click", comment: "Keystroke Overlay: a click with the secondary mouse button")
        case (.middle, _): String(localized: "Middle Click", comment: "Keystroke Overlay: a click with the middle mouse button")
        case (.other, _): String(localized: "Button Click", comment: "Keystroke Overlay: a click with an extra mouse button")
        }
    }
}

/// The pill of recent presses, newest on the right; older entries recede.
struct KeystrokePill: View {
    let items: [KeystrokeFeed.Item]
    let style: PillStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: style.itemGap) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                KeystrokeItemView(item: item, style: style)
                    .opacity(Self.recency(items.count - 1 - index))
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                                      removal: .opacity))
            }
        }
        .padding(style.padding)
        .background { background }
        .fixedSize()
    }

    /// Opacity by age: the newest entry is fully opaque.
    static func recency(_ age: Int) -> Double {
        [1, 0.78, 0.6, 0.46, 0.36][min(age, 4)]
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: style.pillRadius, style: .continuous)
        switch style.effectiveTheme {
        case .glass:
            shape.fill(Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.42))
                .glassEffect(.regular, in: .rect(cornerRadius: style.pillRadius))
                .overlay(shape.strokeBorder(.white.opacity(style.increaseContrast ? 0.35 : 0.14), lineWidth: 1))
                .environment(\.colorScheme, .dark)
        case .dark:
            shape.fill(Color(white: 0.1).opacity(0.97))
                .overlay(shape.strokeBorder(.white.opacity(style.increaseContrast ? 0.35 : 0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        case .light:
            shape.fill(Color(white: 0.985).opacity(0.97))
                .overlay(shape.strokeBorder(.black.opacity(style.increaseContrast ? 0.3 : 0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        }
    }
}

/// The overlay panel's content: the pill at its place on the screen, fading in and out.
struct KeystrokeOverlayRoot: View {
    let model: KeystrokeOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let s = model.settings
        let style = PillStyle(theme: s.theme, size: s.size, reduceTransparency: reduceTransparency,
                              increaseContrast: contrast == .increased)
        GeometryReader { geo in
            KeystrokePill(items: model.feed.items, style: style)
                .opacity(model.visible ? 1 : 0)
                .scaleEffect(model.visible || reduceMotion ? 1 : 0.96)
                .modifier(OverlayPlacement(position: s.position, custom: CGPoint(x: s.customX, y: s.customY), size: geo.size))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .snappy(duration: 0.24), value: model.feed.items)
        .animation(.easeOut(duration: 0.3), value: model.visible)
        .allowsHitTesting(false)
    }
}

/// Puts the pill at a preset spot (with margins clear of the menu bar and Dock) or at the custom
/// center point.
struct OverlayPlacement: ViewModifier {
    let position: KeystrokeSettings.Position
    let custom: CGPoint
    let size: CGSize

    static let margin: CGFloat = 48

    func body(content: Content) -> some View {
        if position == .custom {
            content.position(x: size.width * min(max(custom.x, 0), 1), y: size.height * min(max(custom.y, 0), 1))
        } else {
            content
                .padding(.horizontal, Self.margin)
                .padding(.vertical, Self.margin)
                .frame(width: size.width, height: size.height, alignment: alignment)
        }
    }

    private var alignment: Alignment {
        switch position {
        case .bottomCenter, .custom: .bottom
        case .topCenter: .top
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        }
    }
}

/// Sample presses for the hero, the position editor and preview scenes. The menu names are localized
/// the way an app's own menus would be; the typed sample text stays as it is.
enum KeystrokeSamples {
    static func feed(_ mode: KeystrokeSettings.Mode, size: KeystrokeSettings.Size) -> KeystrokeFeed {
        var feed = KeystrokeFeed(maxItems: min(size.maxItems, 3), maxText: size.maxText)
        switch mode {
        case .shortcuts:
            let paste = String(localized: "Paste", comment: "Sample menu item name in the keystroke overlay preview")
            feed.add(keys: ["⌘", "C"], name: String(localized: "Copy", comment: "Sample menu item name in the keystroke overlay preview"))
            feed.add(keys: ["⌘", "V"], name: paste)
            feed.add(keys: ["⌘", "V"], name: paste)
        case .allKeys:
            feed.add(keys: ["⇧", "H"])
            feed.add(keys: ["I"])
            feed.add(keys: ["⌘", "S"], name: String(localized: "Save", comment: "Sample menu item name in the keystroke overlay preview"))
        case .text:
            feed.add(keys: ["⌘", "N"],
                     name: String(localized: "New Message", comment: "Sample menu item name in the keystroke overlay preview"))
            feed.type("See you at 8 in Alfama")
        }
        return feed
    }
}
