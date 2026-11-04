import AppKit
import AVFoundation
import CoreServices
import MacToysCore
import NaturalLanguage
import Translation

/// Runs script actions as child processes, off the main thread, with a time limit.
enum ScriptRunner {
    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    static func run(_ executable: String, _ arguments: [String], input: String?, environment: [String: String],
                    timeout: TimeInterval) async -> ScriptIO.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, input: input, environment: environment,
                                                           timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], input: String?, environment: [String: String],
                                    timeout: TimeInterval) -> ScriptIO.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ScriptIO.Outcome(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        let stdout = Box(), stderr = Box()
        for (pipe, box) in [(out, stdout), (err, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if let input {
            let handle = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                // A script that doesn't read stdin closes the pipe early; that's not an error.
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Background children can keep the pipes open; don't wait for them forever.
        _ = group.wait(timeout: .now() + 2)
        return ScriptIO.Outcome(status: process.terminationStatus, stdout: String(decoding: stdout.data, as: UTF8.self),
                                stderr: String(decoding: stderr.data, as: UTF8.self), timedOut: timedOut)
    }

    /// The names of the user's Shortcuts.
    static func shortcutNames() async -> [String] {
        let outcome = await run("/usr/bin/shortcuts", ["list"], input: nil, environment: ProcessInfo.processInfo.environment,
                                timeout: 10)
        guard outcome.status == 0 else { return [] }
        return outcome.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
}

/// Dictionary definitions through Dictionary Services (the dictionaries enabled in Dictionary.app).
enum DictionaryLookup {
    static func definition(of term: String) -> String? {
        let length = (term as NSString).length
        guard length > 0, length <= 64,
              let definition = DCSCopyTextDefinition(nil, term as CFString, CFRange(location: 0, length: length)) else { return nil }
        let text = (definition.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func open(_ term: String) {
        if let url = URL(string: "dict://" + URLTemplate.encode(term)) { NSWorkspace.shared.open(url) }
    }
}

/// Spelling suggestions from the system spell checker.
@MainActor
enum SpellCheck {
    /// Suggestions when the word is misspelled; nil when it's spelled right or there are none.
    static func suggestions(for word: String) -> [String]? {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0)
        guard range.location != NSNotFound else { return nil }
        let full = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(forWordRange: full, in: word, language: nil, inSpellDocumentWithTag: 0) ?? []
        return guesses.isEmpty ? nil : Array(guesses.prefix(6))
    }
}

/// The language a text is written in.
enum LanguageGuess {
    /// The dominant language when the recognizer is confident (short texts rarely are).
    static func confident(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let threshold = words >= 4 || text.count >= 24 ? 0.6 : 0.9
        return probability >= threshold ? Locale.Language(identifier: language.rawValue) : nil
    }

    /// Best guess, however unsure.
    static func dominant(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// The target language for Translate: the setting, or the first preferred language.
    static func target(setting: String) -> Locale.Language {
        if !setting.isEmpty { return Locale.Language(identifier: setting) }
        return Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let x = a.languageCode?.identifier, let y = b.languageCode?.identifier else { return false }
        return x == y
    }

    /// "Japanese", "Chinese, Simplified" in the UI language. The script only matters for
    /// Chinese; regions and the usual script are left out ("English", not "English (Latin,
    /// United States)").
    static func name(_ language: Locale.Language, locale: Locale = .current) -> String {
        guard let code = language.languageCode?.identifier else { return language.minimalIdentifier }
        let script = code == "zh" ? Locale.Language(identifier: language.maximalIdentifier).script?.identifier : nil
        let identifier = script.map { "\(code)-\($0)" } ?? code
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// On-device translation with the Translation framework.
enum OnDeviceTranslator {
    enum Failure: Error, Equatable {
        case unknownLanguage
        case sameLanguage(String)
        case notInstalled(source: String, target: String)
        case unsupported(source: String, target: String)
        case failed(String)
    }

    struct Output: Equatable, Sendable {
        var source: String
        var target: String
        var text: String
    }

    static func translate(_ text: String, to target: Locale.Language) async throws -> Output {
        guard let source = LanguageGuess.dominant(text) else { throw Failure.unknownLanguage }
        let sourceName = LanguageGuess.name(source), targetName = LanguageGuess.name(target)
        if LanguageGuess.sameLanguage(source, target) { throw Failure.sameLanguage(targetName) }
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: break
        case .supported: throw Failure.notInstalled(source: sourceName, target: targetName)
        case .unsupported: throw Failure.unsupported(source: sourceName, target: targetName)
        @unknown default: throw Failure.unsupported(source: sourceName, target: targetName)
        }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return Output(source: sourceName, target: targetName, text: response.targetText)
        } catch TranslationError.notInstalled {
            throw Failure.notInstalled(source: sourceName, target: targetName)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    /// System Settings › General › Language & Region, where translation languages are downloaded.
    static func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads text aloud in a voice for its language.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let language = LanguageGuess.dominant(text) {
            utterance.voice = AVSpeechSynthesisVoice(language: language.maximalIdentifier)
                ?? AVSpeechSynthesisVoice(language: language.languageCode?.identifier)
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
