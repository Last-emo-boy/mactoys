import MacToysCore
import SwiftUI

/// Offscreen scenes for `MacToys --snapshot … --only menubar`: real panels and drawn menu bars with
/// believable sample icons, sized like the real thing.
@MainActor
enum MenuBarScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("collapsed", size: CGSize(width: 1440, height: 220), wallpaper: false) {
                AnyView(SceneStage { MenuBarStage(open: false) })
            },
            PreviewScene("expanded", size: CGSize(width: 1440, height: 220), wallpaper: false) {
                AnyView(SceneStage { MenuBarStage(open: true) })
            },
            PreviewScene("hidden-bar", size: CGSize(width: 1512, height: 260), wallpaper: false) {
                AnyView(SceneStage { NotchBarStage() })
            },
            PreviewScene("hidden-bar-empty", size: CGSize(width: 620, height: 150), wallpaper: false) {
                let model = HiddenBarModel()
                return AnyView(SceneStage {
                    HiddenBarView(model: model).shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                })
            },
            PreviewScene("onboarding", size: CGSize(width: 1440, height: 520), wallpaper: false) {
                AnyView(SceneStage { ArrangeStage() })
            },
            PreviewScene("search", size: CGSize(width: 860, height: 600), wallpaper: false) {
                let model = sampleSearch(trusted: true)
                model.selection = "s3"
                return AnyView(SceneStage { searchPanel(model) })
            },
            PreviewScene("search-results", size: CGSize(width: 860, height: 600), wallpaper: false) {
                let model = sampleSearch(trusted: true)
                model.query = "dr"
                return AnyView(SceneStage { searchPanel(model) })
            },
            PreviewScene("search-access", size: CGSize(width: 860, height: 600), wallpaper: false) {
                let model = SearchModel()
                model.trusted = false
                model.all = appOnlyEntries
                return AnyView(SceneStage { searchPanel(model) })
            },
            PreviewScene("appearance", size: CGSize(width: 1440, height: 330), wallpaper: false) {
                AnyView(SceneStage { AppearanceStage() })
            },
        ]
    }

    static func searchPanel(_ model: SearchModel) -> some View {
        SearchView(model: model) { _ in }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func sampleSearch(trusted: Bool) -> SearchModel {
        let model = SearchModel()
        model.trusted = trusted
        model.all = MockSamples.barEntries + MockSamples.visibleEntries
        return model
    }

    /// What search lists without Accessibility: one entry per app, named after it.
    static var appOnlyEntries: [BarEntry] {
        var seen: Set<String> = []
        return (MockSamples.barEntries + MockSamples.visibleEntries).filter { seen.insert($0.appName).inserted }.map {
            BarEntry(id: $0.id, title: $0.appName, appName: $0.appName, section: $0.section,
                     symbol: { if case .symbol(let s) = $0.icon { return s } else { return "app" } }($0))
        }
    }
}

/// The wallpaper reaching to the very top (the snapshot window's toolbar inset is ignored, as a
/// real menu bar sits at the top edge), with the scene on it.
private struct SceneStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                    Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
        .ignoresSafeArea()
    }
}

/// The top of a 1440-point display with its menu bar, and a magnified view of the status icons.
private struct MenuBarStage: View {
    let open: Bool

    var body: some View {
        let elements = MockSamples.elements(open: open, hidden: Array(MockSamples.hidden.prefix(6)))
        ZStack(alignment: .topLeading) {
            MockMenuBar(width: 1440, elements: elements, clock: MockSamples.clock)
            Loupe(elements: elements, open: open)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
                .padding(.top, 62)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The status icons at twice their size on a glass card, with a line up to where they are.
private struct Loupe: View {
    let elements: [MockMenuBar.Element]
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: open ? "eye" : "eye.slash")
                (open ? Text("Hidden icons shown", comment: "Preview caption") : Text("6 icons hidden behind the chevron", comment: "Preview caption"))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            MockMenuBar(width: nil, height: 44, showsAppMenus: false, elements: elements, clock: MockSamples.time,
                        appearance: MenuBarAppearance(enabled: true, shape: .rounded, tint: RGBA(red: 1, green: 1, blue: 1, alpha: 0.08),
                                                      gradient: false, border: true, borderColor: RGBA(red: 1, green: 1, blue: 1, alpha: 0.12),
                                                      shadow: false),
                        scale: 1.75)
        }
        .padding(16)
        .barSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

/// A MacBook display with a notch: shown icons right of it, hidden ones in the separate bar below.
private struct NotchBarStage: View {
    var body: some View {
        let model = HiddenBarModel()
        model.hidden = Array(MockSamples.barEntries.prefix(8))
        model.alwaysHidden = Array(MockSamples.barEntries.suffix(2))
        model.hovered = "s6"
        model.searchEnabled = true
        let width: CGFloat = 1512
        let elements: [MockMenuBar.Element] = [.chevron(open: true)] + MockSamples.shown.map(MockMenuBar.Element.icon)
        return ZStack(alignment: .topTrailing) {
            MockMenuBar(width: width, height: 37, notchWidth: 196, appName: "Xcode",
                        menus: ["File", "Edit", "View", "Find", "Navigate", "Editor", "Product", "Debug"],
                        elements: elements, clock: MockSamples.clock)
            HiddenBarView(model: model)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                .padding(.top, 37 + 6)
                .padding(.trailing, 352)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The arrangement card under the chevron while both sections show.
private struct ArrangeStage: View {
    /// Where the drawn menu bar's chevron sits (its clock and icons are fixed sample content).
    private let chevronX: CGFloat = 1094

    var body: some View {
        let model = ArrangeModel()
        model.hiddenCount = 6
        model.alwaysHiddenCount = 1
        model.alwaysHiddenSection = true
        let elements = MockSamples.elements(open: true, hidden: Array(MockSamples.hidden.prefix(6)),
                                            alwaysHidden: [MockSamples.alwaysHidden[0]], showAlwaysHidden: true)
        return ZStack(alignment: .topLeading) {
            MockMenuBar(width: 1440, elements: elements, clock: MockSamples.clock, accentDividers: true)
            // As OnboardingController places it: the caret 36 points in from the right edge, under the chevron.
            ArrangeCard(model: model, caretX: ArrangeCard.width - 36)
                .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
                .offset(x: chevronX - ArrangeCard.width + 36, y: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Four menu bar tints, each with its name.
private struct AppearanceStage: View {
    var body: some View {
        let styles: [(MenuBarAppearance, Bool)] = [
            (MenuBarAppearance(enabled: true, shape: .rounded, tint: RGBA(red: 0.369, green: 0.361, blue: 0.902, alpha: 0.5), shadow: true), false),
            (MenuBarAppearance(enabled: true, shape: .fullWidth, tint: RGBA(red: 0.369, green: 0.361, blue: 0.902, alpha: 0.55), gradient: true,
                               secondTint: RGBA(red: 1, green: 0.176, blue: 0.333, alpha: 0.45), shadow: false), false),
            (MenuBarAppearance(enabled: true, shape: .rounded, tint: RGBA(red: 0.05, green: 0.05, blue: 0.08, alpha: 0.35), border: true,
                               borderColor: RGBA(red: 1, green: 1, blue: 1, alpha: 0.45), borderWidth: 1, shadow: true), false),
            (MenuBarAppearance(enabled: true, shape: .split, tint: RGBA(red: 0.188, green: 0.69, blue: 0.78, alpha: 0.5), gradient: true,
                               secondTint: RGBA(red: 0.204, green: 0.78, blue: 0.349, alpha: 0.42), shadow: true), true),
        ]
        let elements = MockSamples.elements(open: false)
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: label(pair.0))
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.leading, 20)
                    MockMenuBar(width: 1440, height: pair.1 ? 37 : 28, notchWidth: pair.1 ? 196 : nil, elements: elements,
                                clock: MockSamples.clock, appearance: pair.0)
                }
            }
        }
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ a: MenuBarAppearance) -> String {
        var parts = [a.shape.title]
        if a.gradient { parts.append(String(localized: "Gradient", comment: "Menu bar background option")) }
        if a.border { parts.append(String(localized: "Border", comment: "Menu bar background option")) }
        if a.shadow { parts.append(String(localized: "Shadow", comment: "Menu bar background option")) }
        return parts.formatted(.list(type: .and))
    }
}
