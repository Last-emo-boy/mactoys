import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Audio/video conversion for the Transcode actions. `.m4a` (AAC) and `.mp4` (H.264/AAC) use
/// AVFoundation and keep the source's dimensions and metadata. macOS has no MP3 encoder, so
/// `.mp3` uses ffmpeg, or LAME after an AAC → WAV step, when one of them is installed.
enum MediaTranscoder {
    enum Format: String, Sendable {
        case mp3, m4a, mp4
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func transcode(_ source: URL, to format: Format, into folder: URL,
                          progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "." + format.rawValue)
        switch format {
        case .m4a:
            try await export(source, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: output, progress: progress)
        case .mp4:
            let asset = AVURLAsset(url: source)
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw AdvancedPasteTransforms.TransformError.unsupportedInput(String(localized: "Transcode to .mp4 needs a video file."))
            }
            try await export(source, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: output, progress: progress)
        case .mp3:
            try await mp3(source, to: output, scratch: folder, progress: progress)
        }
        return output
    }

    private static func export(_ source: URL, preset: String, type: AVFileType, to output: URL,
                               progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isExportable) else {
            throw AdvancedPasteTransforms.TransformError.failed(String(localized: "This media file can't be exported (it may be protected)."))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AdvancedPasteTransforms.TransformError.failed(
                String(localized: "AVFoundation can't convert this file to .\(output.pathExtension).",
                       comment: "%@ is a file extension such as m4a or mp4"))
        }
        try? FileManager.default.removeItem(at: output)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: type)
        progress?(1)
    }

    private static func mp3(_ source: URL, to output: URL, scratch: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        if let ffmpeg = tool("ffmpeg") {
            try await run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source.path, "-vn",
                                   "-map_metadata", "0", "-codec:a", "libmp3lame", "-q:a", "2", output.path])
            return
        }
        guard let lame = tool("lame") else {
            throw AdvancedPasteTransforms.TransformError.encoderMissing(
                String(localized: "macOS has no MP3 encoder. Install ffmpeg or LAME (brew install lame) to transcode to .mp3, or use .m4a."))
        }
        let aac = scratch.appendingPathComponent("intermediate.m4a")
        let wav = scratch.appendingPathComponent("intermediate.wav")
        defer {
            try? FileManager.default.removeItem(at: aac)
            try? FileManager.default.removeItem(at: wav)
        }
        try await export(source, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: aac) { progress?($0 * 0.5) }
        try await run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", aac.path, wav.path])
        try await run(lame, ["--quiet", "-V", "2", wav.path, output.path])
        progress?(1)
    }

    /// An installed command-line tool (Homebrew or system locations).
    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool to completion; cancelling the task terminates it.
    private static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = URL(fileURLWithPath: executable).lastPathComponent
            throw AdvancedPasteTransforms.TransformError.failed(
                String(localized: "\(tool) failed: \(String(message.suffix(300)))",
                       comment: "%1$@ is a command-line tool (ffmpeg, lame, afconvert), %2$@ the error it printed"))
        }
    }
}
