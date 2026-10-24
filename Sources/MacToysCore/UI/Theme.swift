import SwiftUI

/// Utility tints from the design system (`design/exports/01-design-system.png`).
public enum Tint: String, CaseIterable, Codable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, graphite, brown

    public var color: Color { Color(nsColor: nsColor) }

    public var nsColor: NSColor {
        switch self {
        case .blue: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)
        case .indigo: NSColor(srgbRed: 0.369, green: 0.361, blue: 0.902, alpha: 1)
        case .purple: NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1)
        case .pink: NSColor(srgbRed: 1, green: 0.176, blue: 0.333, alpha: 1)
        case .red: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
        case .orange: NSColor(srgbRed: 1, green: 0.584, blue: 0, alpha: 1)
        case .yellow: NSColor(srgbRed: 0.961, green: 0.722, blue: 0, alpha: 1)
        case .green: NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
        case .mint: NSColor(srgbRed: 0, green: 0.780, blue: 0.745, alpha: 1)
        case .teal: NSColor(srgbRed: 0.188, green: 0.690, blue: 0.780, alpha: 1)
        case .cyan: NSColor(srgbRed: 0.196, green: 0.678, blue: 0.902, alpha: 1)
        case .graphite: NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)
        case .brown: NSColor(srgbRed: 0.635, green: 0.518, blue: 0.369, alpha: 1)
        }
    }

    /// Light-to-base gradient used on icon tiles.
    public var gradient: LinearGradient {
        LinearGradient(colors: [Color(nsColor: nsColor.blended(withFraction: 0.25, of: .white) ?? nsColor), color],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The rounded, tinted SF Symbol tile that represents a utility.
public struct ModuleIcon: View {
    let symbol: String
    let tint: Tint
    let size: CGFloat

    public init(_ info: ModuleInfo, size: CGFloat = 28) {
        self.symbol = info.symbol
        self.tint = info.tint
        self.size = size
    }

    public init(symbol: String, tint: Tint, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
    }
}

/// Keycap chips: ⌃ ⌥ C.
public struct Keycaps: View {
    let keys: [String]
    var dark: Bool

    public init(_ keys: [String], dark: Bool = false) {
        self.keys = keys
        self.dark = dark
    }

    public init(_ shortcut: Shortcut?, dark: Bool = false) {
        self.keys = shortcut?.keys ?? []
        self.dark = dark
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(dark ? Color.white.opacity(0.75) : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 21)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(dark ? Color.white.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(dark ? 0 : 0.08), radius: 0, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .fixedSize()
    }
}

/// Dark Liquid Glass container used by every overlay (palette, pickers, HUDs).
public struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    public init(cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.55))
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}
