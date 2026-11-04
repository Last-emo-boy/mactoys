import AppKit
import MacToysCore
import Translation

/// On-device translation through Apple's Translation framework.
@MainActor
enum Translator {
    enum Outcome: Equatable {
        case translated(String)
        /// The text is already in the target language.
        case sameLanguage
        /// The language pair is supported, but its on-device models still have to be downloaded.
        case needsDownload
        case unsupported
        case failed(String)
    }

    /// The language to translate into: the setting, or the Mac's first preferred language.
    static func target(_ setting: String?) -> Locale.Language {
        if let setting, !setting.isEmpty { return Locale.Language(identifier: setting) }
        return Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// "English", "Chinese (Simplified)" in the UI language.
    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && (a.script == nil || b.script == nil || a.script == b.script)
    }

    /// Translates with installed models; reports when a download is needed instead of prompting.
    static func translate(_ text: String, source: String?, target: Locale.Language) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(String(localized: "There’s no text to translate.")) }
        let sourceLanguage = source.map { Locale.Language(identifier: $0) }
        if let sourceLanguage, sameLanguage(sourceLanguage, target) { return .sameLanguage }
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let sourceLanguage {
            status = await availability.status(from: sourceLanguage, to: target)
        } else {
            do {
                status = try await availability.status(for: trimmed, to: target)
            } catch {
                return .failed(String(localized: "The language of the text couldn’t be identified."))
            }
        }
        switch status {
        case .unsupported:
            return .unsupported
        case .supported:
            return .needsDownload
        case .installed:
            guard let sourceLanguage else { return .needsDownload }
            let session = TranslationSession(installedSource: sourceLanguage, target: target)
            do {
                return .translated(try await session.translate(trimmed).targetText)
            } catch {
                Log.for("textextractor").error("Translation failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        @unknown default:
            return .unsupported
        }
    }

    /// Opens System Settings at Language & Region, where translation languages are downloaded.
    static func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Languages the picker offers before the framework's own list has loaded.
    static let commonTargets = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "it", "pt-BR", "ru", "ar",
                                "nl", "pl", "tr", "uk", "vi", "th", "id", "hi"]
}
