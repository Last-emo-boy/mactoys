import SwiftUI

/// The standard module settings page (`design/exports/03-settings-module-page.png`):
/// header with icon, name, summary and the enable switch, a permission banner when
/// something is missing, then grouped `Section`s supplied by the module.
///
///     SettingsPage(module: self) {
///         Section("Activation") {
///             ShortcutRow("Activation shortcut", shortcut: $settings.value.activation)
///         }
///     }
///
/// Controls are disabled while the module is off.
public struct SettingsPage<Content: View, Hero: View>: View {
    let module: any ToyModule
    let content: Content
    let hero: Hero
    @State private var registry = ModuleRegistry.shared
    @State private var permissions = PermissionCenter.shared

    public init(module: any ToyModule, @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content) {
        self.module = module
        self.hero = hero()
        self.content = content()
    }

    public var body: some View {
        let info = module.info
        let enabled = registry.isEnabled(info.id)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        ModuleIcon(info, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.name).font(.system(size: 24, weight: .bold)).kerning(-0.4)
                            Text(info.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("Enabled", isOn: Binding(get: { enabled }, set: { registry.setEnabled(info.id, $0) }))
                            .toggleStyle(.adaptiveSwitch)
                            .labelsHidden()
                            .accessibilityLabel("Enable \(info.name)")
                    }
                    let missing = permissions.missing(info.permissions).filter { !$0.isOptional }
                    if enabled, !missing.isEmpty {
                        ForEach(missing) { p in
                            InfoBar(.warning, title: Text("\(p.title) access required"), message: Text(verbatim: p.reason),
                                    actionTitle: Text("Grant Access")) { permissions.request(p) }
                        }
                    }
                    hero.disabled(!enabled)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
            Group { content }.disabled(!enabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

extension SettingsPage where Hero == EmptyView {
    public init(module: any ToyModule, @ViewBuilder content: () -> Content) {
        self.init(module: module, hero: { EmptyView() }, content: content)
    }
}

/// A rich hero card under the header (e.g. "Launch layout editor").
public struct HeroCard<Content: View>: View {
    let tint: Tint
    let content: Content

    public init(tint: Tint = .blue, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [tint.color.opacity(0.09), Tint.indigo.color.opacity(0.05)],
                                         startPoint: .leading, endPoint: .trailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.color.opacity(0.22)))
    }
}

// Every component below takes its text three ways, like SwiftUI's own `Text`:
// a `LocalizedStringKey` (string literals: extracted into the String Catalog and translated),
// `Text` (when mixing a literal with a runtime value), and a disfavored `String` that is shown
// as is (runtime values; localize them at the source with `String(localized:)`).
//
// A literal title with a runtime `String` subtitle can't be told apart from an all-runtime call by
// overload ranking, so `RowLabel("Title", subtitle: path)` shows *both* verbatim. Write
// `RowLabel("Title", verbatimSubtitle: path)` instead (title localized, subtitle as is).

/// Title + optional subtitle label used across rows.
public struct RowLabel: View {
    let title: Text
    let subtitle: Text?

    public init(title: Text, subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) })
    }

    public init(_ title: LocalizedStringKey, verbatimSubtitle: String?) {
        self.init(title: Text(title), subtitle: verbatimSubtitle.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) })
    }

    // The verbatim fallbacks are generic: a plain `String` parameter would beat
    // `LocalizedStringKey` for literals even when disfavored.
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, subtitle: String? = nil) {
        self.init(title: Text(verbatim: String(title)), subtitle: subtitle.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let subtitle {
                subtitle.font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row with a shortcut recorder.
public struct ShortcutRow: View {
    let label: RowLabel
    @Binding var shortcut: Shortcut?

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, shortcut: Binding<Shortcut?>) {
        self.label = RowLabel(title, subtitle: subtitle)
        self._shortcut = shortcut
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, subtitle: String? = nil, shortcut: Binding<Shortcut?>) {
        self.label = RowLabel(String(title), subtitle: subtitle)
        self._shortcut = shortcut
    }

    public init(_ title: LocalizedStringKey, verbatimSubtitle: String?, shortcut: Binding<Shortcut?>) {
        self.init(label: RowLabel(title, verbatimSubtitle: verbatimSubtitle), shortcut: shortcut)
    }

    public init(label: RowLabel, shortcut: Binding<Shortcut?>) {
        self.label = label
        self._shortcut = shortcut
    }

    public var body: some View {
        LabeledContent {
            ShortcutRecorder(shortcut: $shortcut)
        } label: {
            label
        }
    }
}

/// A color row: system color well plus the hex value.
public struct ColorRow: View {
    let label: RowLabel
    let supportsOpacity: Bool
    @Binding var color: RGBA

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, color: Binding<RGBA>,
                supportsOpacity: Bool = true) {
        self.init(label: RowLabel(title, subtitle: subtitle), color: color, supportsOpacity: supportsOpacity)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, subtitle: String? = nil, color: Binding<RGBA>, supportsOpacity: Bool = true) {
        self.init(label: RowLabel(title, subtitle: subtitle), color: color, supportsOpacity: supportsOpacity)
    }

    public init(_ title: LocalizedStringKey, verbatimSubtitle: String?, color: Binding<RGBA>, supportsOpacity: Bool = true) {
        self.init(label: RowLabel(title, verbatimSubtitle: verbatimSubtitle), color: color, supportsOpacity: supportsOpacity)
    }

    public init(label: RowLabel, color: Binding<RGBA>, supportsOpacity: Bool = true) {
        self.label = label
        self._color = color
        self.supportsOpacity = supportsOpacity
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: color.hex).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                ColorPicker("", selection: RGBA.binding($color), supportsOpacity: supportsOpacity).labelsHidden()
            }
        } label: {
            label
        }
    }
}

/// A slider row with a formatted value.
public struct SliderRow: View {
    let label: RowLabel
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String
    @Binding var value: Double

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, value: Binding<Double>,
                in range: ClosedRange<Double>, step: Double? = nil,
                format: @escaping (Double) -> String = { Int($0.rounded()).formatted() }) {
        self.init(label: RowLabel(title, subtitle: subtitle), value: value, in: range, step: step, format: format)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, subtitle: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
                step: Double? = nil, format: @escaping (Double) -> String = { Int($0.rounded()).formatted() }) {
        self.init(label: RowLabel(title, subtitle: subtitle), value: value, in: range, step: step, format: format)
    }

    public init(_ title: LocalizedStringKey, verbatimSubtitle: String?, value: Binding<Double>,
                in range: ClosedRange<Double>, step: Double? = nil,
                format: @escaping (Double) -> String = { Int($0.rounded()).formatted() }) {
        self.init(label: RowLabel(title, verbatimSubtitle: verbatimSubtitle), value: value, in: range, step: step, format: format)
    }

    public init(label: RowLabel, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
                format: @escaping (Double) -> String = { Int($0.rounded()).formatted() }) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let step { Slider(value: $value, in: range, step: step).frame(width: 180) }
                else { Slider(value: $value, in: range).frame(width: 180) }
                Text(verbatim: format(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        } label: {
            label
        }
    }
}

public enum InfoKind { case info, warning, error, success }

/// Inline banner (`InfoBar` component in the design system).
public struct InfoBar: View {
    let kind: InfoKind
    let title: Text
    let message: Text?
    let actionTitle: Text?
    let action: (() -> Void)?

    public init(_ kind: InfoKind, title: Text, message: Text? = nil, actionTitle: Text? = nil,
                action: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public init(_ kind: InfoKind, title: LocalizedStringKey, message: LocalizedStringKey? = nil,
                actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.init(kind, title: Text(title), message: message.map { Text($0) },
                  actionTitle: actionTitle.map { Text($0) }, action: action)
    }

    /// Localized title and action, runtime message (a path, an error description…).
    public init(_ kind: InfoKind, title: LocalizedStringKey, verbatimMessage: String?,
                actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.init(kind, title: Text(title), message: verbatimMessage.map { Text(verbatim: $0) },
                  actionTitle: actionTitle.map { Text($0) }, action: action)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ kind: InfoKind, title: S, message: String? = nil, actionTitle: String? = nil,
                                   action: (() -> Void)? = nil) {
        self.init(kind, title: Text(verbatim: String(title)), message: message.map { Text(verbatim: $0) },
                  actionTitle: actionTitle.map { Text(verbatim: $0) }, action: action)
    }

    var tint: Color {
        switch kind {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.shield.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                title.fontWeight(.semibold)
                if let message { message.font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(action: action) { actionTitle } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// One-app-per-line editor for exclusion lists (matches by app name or bundle id, case-insensitive).
public struct ExcludedAppsEditor: View {
    @Binding var apps: [String]
    @State private var text = ""
    let title: Text

    public init(_ title: LocalizedStringKey = "Excluded apps", apps: Binding<[String]>) {
        self.title = Text(title)
        self._apps = apps
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, apps: Binding<[String]>) {
        self.title = Text(verbatim: String(title))
        self._apps = apps
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title: title, subtitle: Text("One app name or bundle identifier per line."))
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onAppear { text = apps.joined(separator: "\n") }
                .onChange(of: text) { _, new in
                    apps = new.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            Menu("Add running app") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                        let name = app.localizedName ?? app.bundleIdentifier ?? ""
                        if !apps.contains(name) { apps.append(name); text = apps.joined(separator: "\n") }
                    }
                }
            }
            .fixedSize()
        }
    }
}

extension Array where Element == String {
    /// Whether an app (by name or bundle id) is in an exclusion list.
    public func matches(app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let name = app.localizedName?.lowercased() ?? ""
        let bid = app.bundleIdentifier?.lowercased() ?? ""
        return contains { entry in
            let e = entry.lowercased()
            return e == bid || (!name.isEmpty && name.contains(e))
        }
    }
}
