import AppKit
import MacToysCore
import SwiftUI

/// Run's settings page, grouped like PowerToys Run's (activation, search & results, position, plugins).
struct RunSettingsView: View {
    let module: RunModule
    @Bindable var settings: Persisted<RunSettings>
    @Bindable var options: Persisted<ProviderOptions>

    init(module: RunModule) {
        self.module = module
        settings = module.settings
        options = module.engine.options
    }

    var body: some View {
        SettingsPage(module: module) {
            Section("Activation") {
                ShortcutRow("Activation shortcut", subtitle: "Shows or hides Run", shortcut: $settings.value.activation)
                Toggle(isOn: $settings.value.ignoreInFullScreen) { RowLabel("Ignore the shortcut while an app is full screen") }
            }
            Section("Search & results") {
                Stepper(value: $settings.value.maxResults, in: 1...12) {
                    RowLabel(title: Text("Results shown before scrolling"), subtitle: Text(settings.value.maxResults, format: .number))
                }
                Toggle(isOn: $settings.value.clearOnOpen) { RowLabel("Clear the previous query when opening") }
                Toggle(isOn: $settings.value.clearOnLaunch) { RowLabel("Clear the query after running a result") }
                SliderRow("Input smoothing", subtitle: "Wait for more typing before searching", value: $settings.value.searchDelay,
                          in: 0...400, step: 10,
                          format: { Measurement(value: $0, unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated, usage: .asProvided)) })
                SliderRow("Selected item weight", subtitle: "How fast results you pick rise (0 turns it off)",
                          value: $settings.value.usageWeight, in: 0...10, step: 1)
                Toggle(isOn: $settings.value.showPluginHints) { RowLabel("Show plugin keywords under the search box") }
            }
            Section("Position") {
                Picker(selection: $settings.value.screen) {
                    ForEach([LauncherScreen.mouse, .primary, .focusedWindow]) { Text($0.title).tag($0) }
                } label: { RowLabel("Open Run on") }
            }
            Section {
                ForEach(module.engine.providers, id: \.id) { p in
                    PluginRow(provider: p, settings: settings, options: options)
                }
                LabeledContent {
                    Button("Restore Default Keywords") {
                        for key in settings.value.plugins.keys {
                            if let p = module.engine.provider(key) { settings.value.plugins[key]?.keyword = p.defaultKeyword }
                        }
                    }
                } label: { RowLabel("Keywords", subtitle: "Type ? in Run to list every plugin and its keyword") }
            } header: {
                Text("Plugins")
            } footer: {
                Text("A keyword runs only that plugin: “\("= 2+2")”, “\("> ls")”. Characters used in math or paths (\(". , + - ( / ~")) can clash with global results.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// One plugin: on/off, keyword, global results, its options.
private struct PluginRow: View {
    let provider: any SearchProvider
    @Bindable var settings: Persisted<RunSettings>
    @Bindable var options: Persisted<ProviderOptions>
    @State private var expanded = false

    var body: some View {
        let p = settings.value.plugin(for: provider)
        DisclosureGroup(isExpanded: $expanded) {
            LabeledContent {
                TextField(String(localized: "none", comment: "Placeholder: the plugin has no keyword"),
                          text: Binding(get: { p.keyword }, set: { v in update { $0.keyword = v.trimmingCharacters(in: .whitespaces) } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 90)
            } label: {
                RowLabel(title: Text("Direct activation keyword"),
                         subtitle: provider.defaultKeyword.isEmpty ? Text("Default: none", comment: "The plugin has no keyword by default")
                             : Text("Default: \(provider.defaultKeyword)", comment: "%@ is the plugin's default keyword, e.g. ="))
            }
            Toggle(isOn: Binding(get: { p.global }, set: { v in update { $0.global = v } })) {
                RowLabel("Include in global results", subtitle: "Off: only with the keyword")
            }
            if providersWithOptions.contains(provider.id) {
                ProviderOptionsView(providerID: provider.id, options: options)
            }
        } label: {
            HStack {
                ProviderHeader(provider: provider, detail: p.keyword.isEmpty ? nil : "\(p.keyword)  ·  \(provider.summary)")
                Spacer()
                Toggle(isOn: Binding(get: { p.enabled }, set: { v in update { $0.enabled = v } })) { Text(verbatim: provider.name) }
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private func update(_ change: (inout PluginSetting) -> Void) {
        var p = settings.value.plugin(for: provider)
        change(&p)
        settings.value.plugins[provider.id] = p
    }
}
