import AppKit
import SwiftUI

/// The app's UI language. macOS picks a localization per app from `AppleLanguages`; MacToys stores
/// an override in its own defaults domain (the same thing System Settings › Language & Region ›
/// Applications does) and needs a relaunch to apply it.
public enum AppLanguage {
    /// Localizations in the bundle, English first, the pseudo-language last.
    public static var available: [String] {
        let all = (Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String])
            ?? Bundle.main.localizations
        var langs = all.filter { $0 != "Base" }
        if Bundle.main.localizations.contains("eo") && !langs.contains("eo") { langs.append("eo") }
        return langs
    }

    /// The per-app override, or nil when MacToys follows the system language.
    public static var override: String? {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier)
        return (domain?["AppleLanguages"] as? [String])?.first
    }

    /// The language the running process actually uses.
    public static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    public static func setOverride(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Native name ("简体中文", "Deutsch"); the pseudo-language is labelled as such.
    public static func displayName(_ code: String) -> String {
        if code == "eo" { return "Pseudo ⟦…⟧" }
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Whether the chosen setting differs from what this process shows (a relaunch is needed).
    public static var needsRelaunch: Bool {
        guard let override else {
            let system = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first
            return system != nil && system != current
        }
        return override != current
    }
}

/// "Language: System (简体中文) ▾" with a relaunch button when the choice changed.
public struct LanguagePicker: View {
    let relaunch: () -> Void
    @State private var selection: String = AppLanguage.override ?? ""
    @State private var pending = AppLanguage.needsRelaunch

    public init(relaunch: @escaping () -> Void) {
        self.relaunch = relaunch
    }

    public var body: some View {
        HStack(spacing: 10) {
            Picker(selection: $selection) {
                Text("System (\(AppLanguage.displayName(systemLanguage)))").tag("")
                Divider()
                ForEach(AppLanguage.available, id: \.self) { code in
                    Text(verbatim: AppLanguage.displayName(code)).tag(code)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .fixedSize()
            .onChange(of: selection) { _, new in
                AppLanguage.setOverride(new.isEmpty ? nil : new)
                pending = AppLanguage.needsRelaunch
            }
            if pending {
                Button("Relaunch to Apply", action: relaunch)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var systemLanguage: String {
        Bundle.preferredLocalizations(from: AppLanguage.available.filter { $0 != "eo" },
                                      forPreferences: Locale.preferredLanguages).first ?? "en"
    }
}
