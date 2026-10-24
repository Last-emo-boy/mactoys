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
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("Enable \(info.name)")
                    }
                    let missing = permissions.missing(info.permissions).filter { !$0.isOptional }
                    if enabled, !missing.isEmpty {
                        ForEach(missing) { p in
                            InfoBar(.warning, title: "\(p.title) access required", message: p.reason,
                                    actionTitle: "Grant Access") { permissions.request(p) }
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

/// Title + optional subtitle label used across rows.
public struct RowLabel: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row with a shortcut recorder.
public struct ShortcutRow: View {
    let title: String
    let subtitle: String?
    @Binding var shortcut: Shortcut?

    public init(_ title: String, subtitle: String? = nil, shortcut: Binding<Shortcut?>) {
        self.title = title
        self.subtitle = subtitle
        self._shortcut = shortcut
    }

    public var body: some View {
        LabeledContent {
            ShortcutRecorder(shortcut: $shortcut)
        } label: {
            RowLabel(title, subtitle: subtitle)
        }
    }
}

/// A color row: system color well plus the hex value.
public struct ColorRow: View {
    let title: String
    let subtitle: String?
    let supportsOpacity: Bool
    @Binding var color: RGBA

    public init(_ title: String, subtitle: String? = nil, color: Binding<RGBA>, supportsOpacity: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self._color = color
        self.supportsOpacity = supportsOpacity
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(color.hex).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                ColorPicker("", selection: RGBA.binding($color), supportsOpacity: supportsOpacity).labelsHidden()
            }
        } label: {
            RowLabel(title, subtitle: subtitle)
        }
    }
}

/// A slider row with a formatted value.
public struct SliderRow: View {
    let title: String
    let subtitle: String?
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String
    @Binding var value: Double

    public init(_ title: String, subtitle: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
                step: Double? = nil, format: @escaping (Double) -> String = { String(Int($0.rounded())) }) {
        self.title = title
        self.subtitle = subtitle
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
                Text(format(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        } label: {
            RowLabel(title, subtitle: subtitle)
        }
    }
}

public enum InfoKind { case info, warning, error, success }

/// Inline banner (`InfoBar` component in the design system).
public struct InfoBar: View {
    let kind: InfoKind
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ kind: InfoKind, title: String, message: String? = nil, actionTitle: String? = nil,
                action: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
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
                Text(title).fontWeight(.semibold)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action) }
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
    let title: String

    public init(_ title: String = "Excluded apps", apps: Binding<[String]>) {
        self.title = title
        self._apps = apps
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title, subtitle: "One app name or bundle identifier per line.")
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
