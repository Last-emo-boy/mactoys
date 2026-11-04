import AppKit
import Foundation
import MacToysCore
import Observation
import UniformTypeIdentifiers

/// What a job does with its file.
enum JobOperation: Equatable, Sendable {
    case optimize
    /// Downscale to this factor of the original (and optimize).
    case downscale(Double)
    /// Write a copy in another image format.
    case convert(ImageFormat)
}

/// Per-request tweaks on top of the settings.
struct JobOptions: Equatable, Sendable {
    /// ⌥ held while dropping: smaller files, lower quality.
    var aggressive = false
    var speed: Double?
    var removeAudio: Bool?
}

/// One file (or clipboard image) being optimized; shown as a result card.
@MainActor
@Observable
final class OptimizationJob: Identifiable {
    enum Origin: Equatable {
        case file(URL)
        case clipboard
    }

    enum State: Equatable {
        case queued
        /// Progress 0…1 when known.
        case working(Double?)
        case done
        /// The result wasn't smaller; nothing changed.
        case unchanged
        case failed(String)
        case cancelled
        case restored
    }

    let id = UUID()
    let origin: Origin
    let kind: MediaKind
    var operation: JobOperation
    var options: JobOptions
    /// Groups the jobs of one multi-file request into a batch card.
    var batchID: UUID?

    var name: String
    var state: State = .queued
    var originalSize: Int64 = 0
    var resultSize: Int64?
    var resultURL: URL?
    /// The untouched original, the source of every re-run and of Restore.
    var backupURL: URL?
    var thumbnail: CGImage?
    /// "2880 × 1800 · PNG · 256 colors".
    var detail = ""
    /// Downscale factor of the current result, relative to the original.
    var scale = 1.0
    var startedAt: Date?
    var finishedAt: Date?
    /// True once the original file was replaced or removed (Restore then puts it back).
    var replacedOriginal = false

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var transcoder: VideoTranscoder?
    @ObservationIgnored var originalDate: Date?

    init(origin: Origin, kind: MediaKind, name: String, operation: JobOperation = .optimize, options: JobOptions = JobOptions()) {
        self.origin = origin
        self.kind = kind
        self.name = name
        self.operation = operation
        self.options = options
    }

    var fileURL: URL? {
        if case .file(let url) = origin { return url }
        return nil
    }

    var isWorking: Bool {
        switch state {
        case .queued, .working: true
        default: false
        }
    }

    var progress: Double? {
        if case .working(let p) = state { return p }
        return nil
    }

    /// 0.74 for 74 % smaller, once done.
    var saving: Double? {
        guard state == .done, let resultSize else { return nil }
        return SizeGate.saving(original: originalSize, result: resultSize)
    }

    /// GIF → MP4 and format conversions write a new file next to the original instead of replacing it.
    var isConversion: Bool {
        if case .convert = operation { return true }
        if kind == .video, let url = fileURL, VideoTranscoder.isGIF(url) { return true }
        return false
    }

    var canDownscale: Bool {
        guard kind != .pdf, !isConversion, state == .done || state == .unchanged else { return false }
        return DownscaleMath.nextFactor(after: scale) != nil
    }

    var canRestore: Bool {
        state == .done && (replacedOriginal || resultURL != nil || origin == .clipboard)
    }

    /// Estimated seconds left for a running job (after a few seconds of progress).
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let p = progress, p > 0.03, p < 1, let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        return elapsed / p * (1 - p)
    }
}

/// The multi-file request a batch card summarizes.
struct JobBatch: Identifiable, Equatable {
    let id: UUID
    var jobIDs: [UUID]
}

/// What the result panel shows, newest last.
enum ResultCardItem: Identifiable {
    case job(OptimizationJob)
    case batch(JobBatch, [OptimizationJob])

    var id: UUID {
        switch self {
        case .job(let j): j.id
        case .batch(let b, _): b.id
        }
    }
}
