import MacToysCore
import SwiftUI

/// A drawn macOS 26 menu bar (transparent over the wallpaper, white text) for the settings hero and
/// the preview scenes. Status elements are listed left to right; the clock comes last.
struct MockMenuBar: View {
    enum Element: Hashable {
        case icon(String)
        case text(String)
        case chevron(open: Bool)
        case divider(double: Bool)
        /// An icon drawn faded (on its way off screen).
        case faded(String)
    }

    /// Nil sizes the bar to its content (no app menus, no notch).
    var width: CGFloat?
    var height: CGFloat = 24
    /// Width of the camera housing, centered; nil for a display without a notch.
    var notchWidth: CGFloat?
    var showsAppMenus = true
    var appName = "Finder"
    var menus = ["File", "Edit", "View", "Go", "Window", "Help"]
    var elements: [Element]
    var clock: String
    var appearance: MenuBarAppearance?
    var chevronStyle: ChevronStyle = .chevron
    var dividerStyle: DividerStyle = .line
    var accentDividers = false
    /// Draws everything smaller, for miniatures.
    var scale: CGFloat = 1

    var body: some View {
        if let width {
            ZStack(alignment: .topLeading) {
                if let appearance, appearance.enabled {
                    BackdropShapeView(appearance: appearance, notch: notchRange)
                        .frame(width: width, height: height)
                }
                content.frame(width: width, height: height)
                if let notchWidth {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10 * scale, bottomTrailingRadius: 10 * scale, style: .continuous)
                        .fill(.black)
                        .frame(width: notchWidth, height: height)
                        .offset(x: (width - notchWidth) / 2)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .accessibilityHidden(true)
        } else {
            content
                .frame(height: height)
                .fixedSize()
                .background {
                    if let appearance, appearance.enabled { BackdropShapeView(appearance: appearance) }
                }
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            if showsAppMenus {
                HStack(spacing: 19 * scale) {
                    Image(systemName: "apple.logo").font(.system(size: 14 * scale, weight: .medium))
                    Text(verbatim: appName).font(.system(size: 13 * scale, weight: .bold))
                    ForEach(menus, id: \.self) { Text(verbatim: $0).font(.system(size: 13 * scale)) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 15 * scale) {
                ForEach(Array(elements.enumerated()), id: \.offset) { _, e in element(e) }
                Text(verbatim: clock).font(.system(size: 13 * scale).monospacedDigit())
            }
        }
        .padding(.horizontal, 14 * scale)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 1.5 * scale, y: 0.5)
    }

    private var notchRange: ClosedRange<CGFloat>? {
        guard let width, let notchWidth else { return nil }
        return ((width - notchWidth) / 2)...((width + notchWidth) / 2)
    }

    @ViewBuilder private func element(_ e: Element) -> some View {
        switch e {
        case .icon(let s):
            Image(systemName: s).font(.system(size: 14 * scale, weight: .medium)).symbolRenderingMode(.monochrome)
        case .faded(let s):
            Image(systemName: s).font(.system(size: 14 * scale, weight: .medium)).opacity(0.38)
        case .text(let t):
            Text(verbatim: t).font(.system(size: 13 * scale).monospacedDigit())
        case .chevron(let open):
            Image(systemName: chevronStyle.symbol(collapsed: !open))
                .font(.system(size: (chevronStyle == .dot ? 8 : 12) * scale, weight: .bold))
        case .divider(let double):
            MockDivider(style: accentDividers && dividerStyle == .none ? .line : dividerStyle, double: double,
                        accent: accentDividers, scale: scale)
        }
    }
}

struct MockDivider: View {
    let style: DividerStyle
    let double: Bool
    var accent = false
    var scale: CGFloat = 1

    var body: some View {
        let color = accent ? Color.accentColor : Color.white.opacity(0.75)
        HStack(spacing: 2.4 * scale) {
            ForEach(0..<(double ? 2 : 1), id: \.self) { _ in
                switch style {
                case .line:
                    Capsule().fill(color).frame(width: 1.7 * scale, height: 14 * scale)
                case .dots:
                    VStack(spacing: 1.8 * scale) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: 2.6 * scale, height: 2.6 * scale) }
                    }
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

/// Sample menu bar content shared by the hero and the preview scenes.
enum MockSamples {
    /// Shown icons, left to right after the chevron: MacToys, Awake, Wi-Fi, battery, Spotlight, Control Center.
    static let shown = ["puzzlepiece.extension.fill", "cup.and.saucer", "wifi", "battery.75percent", "magnifyingglass", "switch.2"]
    /// Hidden icons, left to right.
    static let hidden = ["shippingbox.fill", "cloud.fill", "key.horizontal.fill", "music.note", "cpu", "bolt.horizontal.circle.fill",
                         "externaldrive.badge.icloud", "bubble.left.and.bubble.right.fill"]
    static let alwaysHidden = ["timer", "globe.europe.africa.fill"]

    static var sampleDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 4; c.hour = 9; c.minute = 41
        return Calendar.current.date(from: c) ?? Date()
    }

    /// "Wed, Nov 4  9:41" in the user's language, spaced like the menu bar clock.
    static var clock: String {
        sampleDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + "  " + time
    }

    /// "9:41" in the user's language.
    static var time: String { sampleDate.formatted(date: .omitted, time: .shortened) }

    static func elements(open: Bool, hidden: [String] = hidden, alwaysHidden: [String] = [], showAlwaysHidden: Bool = false,
                         dividers: Bool = true) -> [MockMenuBar.Element] {
        var e: [MockMenuBar.Element] = []
        if open {
            if showAlwaysHidden && !alwaysHidden.isEmpty {
                e += alwaysHidden.map(MockMenuBar.Element.icon)
                if dividers { e.append(.divider(double: true)) }
            }
            e += hidden.map(MockMenuBar.Element.icon)
            if dividers { e.append(.divider(double: false)) }
        }
        e.append(.chevron(open: open))
        e += shown.map(MockMenuBar.Element.icon)
        return e
    }

    /// Entries for the separate bar and search previews (app names are sample data).
    static let barEntries: [BarEntry] = [
        BarEntry(id: "s1", title: "Docker Desktop", appName: "Docker", section: .hidden, symbol: "shippingbox.fill"),
        BarEntry(id: "s2", title: "Dropbox", appName: "Dropbox", section: .hidden, symbol: "cloud.fill"),
        BarEntry(id: "s3", title: "1Password", appName: "1Password", section: .hidden, symbol: "key.horizontal.fill"),
        BarEntry(id: "s4", title: "Now Playing", appName: "Music", section: .hidden, symbol: "music.note"),
        BarEntry(id: "s5", title: "CPU 12 %", appName: "Stats", section: .hidden, symbol: "cpu"),
        BarEntry(id: "s6", title: "Tailscale VPN", appName: "Tailscale", section: .hidden, symbol: "bolt.horizontal.circle.fill"),
        BarEntry(id: "s7", title: "Backup up to date", appName: "Backblaze", section: .hidden, symbol: "externaldrive.badge.icloud"),
        BarEntry(id: "s8", title: "Slack", appName: "Slack", section: .hidden, symbol: "bubble.left.and.bubble.right.fill"),
        BarEntry(id: "a1", title: "Pomodoro 18:40", appName: "Session", section: .alwaysHidden, symbol: "timer"),
        BarEntry(id: "a2", title: "World Clock", appName: "Clocker", section: .alwaysHidden, symbol: "globe.europe.africa.fill"),
    ]

    static let visibleEntries: [BarEntry] = [
        BarEntry(id: "v1", title: "MacToys", appName: "MacToys", section: .visible, symbol: "puzzlepiece.extension.fill"),
        BarEntry(id: "v2", title: "Awake", appName: "MacToys", section: .visible, symbol: "cup.and.saucer"),
        BarEntry(id: "v3", title: "Wi‑Fi", appName: "Control Center", section: .visible, symbol: "wifi"),
        BarEntry(id: "v7", title: "AirDrop", appName: "Control Center", section: .visible, symbol: "dot.radiowaves.up.forward"),
        BarEntry(id: "v4", title: "Battery", appName: "Control Center", section: .visible, symbol: "battery.75percent"),
        BarEntry(id: "v5", title: "Control Center", appName: "Control Center", section: .visible, symbol: "switch.2"),
        BarEntry(id: "v6", title: "Spotlight", appName: "Spotlight", section: .visible, symbol: "magnifyingglass"),
    ]
}
