import AVFoundation
import MacToysCore
import Observation

/// Reads captured text aloud with the system voices.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// The id of the capture (or translation) being read, for the card's Stop button.
    private(set) var speakingID: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { speakingID != nil }

    /// Speaks `text`. `voice` is a voice identifier; nil picks a voice for `language` (the text's
    /// detected language), else the system voice. `rate` is a multiplier of the normal speed.
    func speak(_ text: String, id: String, language: String?, voice: String?, rate: Double) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(identifier: voice, language: language)
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let value = normal * min(max(rate, 0.5), 2)
        utterance.rate = Float(min(max(value, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || speakingID != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    static func voice(identifier: String?, language: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        guard let language else { return nil }
        // The best installed voice for the language: premium, then enhanced, then default quality.
        let base = Locale.Language(identifier: language).languageCode?.identifier ?? language
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language || $0.language.hasPrefix(base + "-") || $0.language == base
        }
        let preferred = candidates.filter { $0.language.hasSuffix("-" + preferredRegion(for: language)) }
        return (preferred.isEmpty ? candidates : preferred).max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The user's own region when the text is in their language (en-GB for English in the UK),
    /// otherwise the language's most likely region (zh-Hans → CN).
    static func preferredRegion(for language: String) -> String {
        let text = Locale.Language(identifier: language)
        if text.languageCode == Locale.current.language.languageCode, let own = Locale.current.region?.identifier { return own }
        return Locale(identifier: text.maximalIdentifier).region?.identifier ?? ""
    }

    /// Installed voices by language, for the settings picker: (identifier, "Ava (Premium) — English (United States)").
    static var voices: [(id: String, name: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { v in
                let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
                let quality: String? = switch v.quality {
                case .premium: String(localized: "Premium", comment: "Speech voice quality")
                case .enhanced: String(localized: "Enhanced", comment: "Speech voice quality")
                default: nil
                }
                let name = quality.map { "\(v.name) (\($0))" } ?? v.name
                return (v.identifier, "\(name) — \(language)")
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        if !synthesizer.isSpeaking { speakingID = nil }
    }
}
