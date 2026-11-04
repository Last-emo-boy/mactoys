import AppKit
import MacToysCore
import SwiftUI

/// A menu bar item as the separate bar, search and the settings page draw it.
struct BarEntry: Identifiable, Equatable {
    enum Icon: Equatable {
        case app(NSImage)
        case symbol(String)
    }

    let id: String
    let title: String
    let appName: String
    let section: MenuBarSection
    let icon: Icon

    /// The window server can't show another app's icon image without Screen Recording, so items
    /// show their app's icon, or a symbol for Apple's own items.
    @MainActor
    init(_ item: MenuBarItem) {
        id = item.id
        title = item.title
        appName = item.appName
        section = item.section
        if let symbol = SystemItemSymbols.symbol(for: item.identifier) {
            icon = .symbol(symbol)
        } else if let image = AppIcons.icon(pid: item.pid) {
            icon = .app(image)
        } else {
            icon = .symbol("app.dashed")
        }
    }

    /// Sample entries for previews.
    init(id: String, title: String, appName: String, section: MenuBarSection, symbol: String) {
        self.id = id
        self.title = title
        self.appName = appName
        self.section = section
        self.icon = .symbol(symbol)
    }
}

/// App icons by process, cached for the life of each process.
@MainActor
enum AppIcons {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(pid: pid_t) -> NSImage? {
        if let hit = cache[pid] { return hit }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let icon = app.icon else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[pid] = icon
        return icon
    }
}

/// An entry's icon: the app icon, or a symbol drawn like a menu bar icon.
struct EntryIcon: View {
    let icon: BarEntry.Icon
    var size: CGFloat = 18

    var body: some View {
        switch icon {
        case .app(let image):
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.78, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: size, height: size)
        }
    }
}

/// Dark Liquid Glass for the separate bar, the arrangement card and search; solid with Reduce
/// Transparency, with a stronger edge for Increase Contrast.
struct BarSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content
                    .background(shape.fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .environment(\.colorScheme, .dark)
            } else {
                GlassPanel(cornerRadius: cornerRadius) { content }
            }
        }
        .overlay {
            if contrast == .increased { shape.strokeBorder(.white.opacity(0.6), lineWidth: 1) }
        }
    }
}

extension View {
    func barSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(BarSurface(cornerRadius: cornerRadius))
    }
}

/// A filled capsule (accent unless told otherwise) drawn in SwiftUI, for buttons on dark glass (offscreen renders can't
/// capture AppKit's accent fill, and this reads better on glass anyway).
struct GlassProminentButtonStyle: ButtonStyle {
    var fill: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 30)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}

/// The tint drawn behind the menu bar, for one display: full width, a rounded bar, or two rounded
/// halves around the notch. `notch` is in the view's own coordinates.
struct BackdropShapeView: View {
    let appearance: MenuBarAppearance
    var notch: ClosedRange<CGFloat>?
    /// Solid colors (Reduce Transparency).
    var solid = false
    /// Stronger edge (Increase Contrast).
    var highContrast = false
    /// Room under the bar for the shadow.
    var shadowPad: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let barHeight = geo.size.height - shadowPad
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects(width: geo.size.width, height: barHeight).enumerated()), id: \.offset) { _, r in
                    piece(r)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func rects(width: CGFloat, height: CGFloat) -> [CGRect] {
        switch appearance.shape {
        case .fullWidth:
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        case .rounded:
            return [CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 6, dy: 3)]
        case .split:
            guard let notch, notch.lowerBound > 40, notch.upperBound < width - 40 else {
                return [CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 6, dy: 3)]
            }
            return [CGRect(x: 6, y: 3, width: notch.lowerBound - 6 - 10, height: height - 6),
                    CGRect(x: notch.upperBound + 10, y: 3, width: width - notch.upperBound - 10 - 6, height: height - 6)]
        }
    }

    private func piece(_ r: CGRect) -> some View {
        let radius: CGFloat = appearance.shape == .fullWidth ? 0 : min(r.height / 2, 12)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let first = solid ? appearance.tint.withAlpha(1) : appearance.tint
        let second = solid ? appearance.secondTint.withAlpha(1) : appearance.secondTint
        let fill: AnyShapeStyle = appearance.gradient
            ? AnyShapeStyle(LinearGradient(colors: [first.color, second.color], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(first.color)
        let borderWidth = appearance.border ? max(appearance.borderWidth, highContrast ? 1.5 : 0.5) : (highContrast ? 1 : 0)
        let borderColor = appearance.border ? appearance.borderColor.color : Color.white.opacity(0.6)
        return shape.fill(fill)
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .shadow(color: .black.opacity(appearance.shadow ? 0.32 : 0), radius: appearance.shadow ? 5 : 0, y: appearance.shadow ? 2 : 0)
            .frame(width: max(0, r.width), height: max(0, r.height))
            .offset(x: r.minX, y: r.minY)
    }
}
