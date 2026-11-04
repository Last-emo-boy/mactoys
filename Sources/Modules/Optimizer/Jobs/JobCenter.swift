import AppKit
import Foundation
import MacToysCore
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Runs optimization jobs, places their results, keeps originals for undo and drives the result cards.
///
/// Images and PDFs run three at a time, videos one at a time. Every run starts from the backed-up
/// original, so "Downscale" and "Convert" on a card never compound quality loss.
@MainActor
@Observable
final class JobCenter {
    private(set) var jobs: [OptimizationJob] = []
    private(set) var batches: [JobBatch] = []
    /// The pointer is over the result cards: they stay, and show their actions.
    var pointerInside = false {
        didSet {
            guard oldValue != pointerInside, !pointerInside else { return }
            // Give every finished card its full time again after the pointer leaves.
            let now = Date()
            for job in jobs where job.finishedAt != nil { job.finishedAt = now }
        }
    }

    @ObservationIgnored var settings: () -> OptimizerSettings = { OptimizerSettings() }
    /// Writes an optimized image to the clipboard (the module marks the write as its own).
    @ObservationIgnored var writeClipboard: (Data, UTType) -> Void = { _, _ in }
    /// Called when a job ends, for a HUD when result cards are off.
    @ObservationIgnored var onFinish: (OptimizationJob) -> Void = { _ in }
    @ObservationIgnored let backups: BackupStore
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private let clipboardFolder: URL
    @ObservationIgnored private var hideTimer: Timer?
    @ObservationIgnored private let log = Log.for("optimizer")

    static let batchThreshold = 4
    private static let parallelFiles = 3

    init(backups: BackupStore = .standard,
         scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MacToys Optimizer", isDirectory: true),
         clipboardFolder: URL = Paths.data(for: "optimizer").appendingPathComponent("Clipboard", isDirectory: true)) {
        self.backups = backups
        self.scratch = scratch
        self.clipboardFolder = clipboardFolder
    }

    // MARK: Cards

    /// Cards in order: batches collapse their jobs into one card.
    var cards: [ResultCardItem] {
        var items: [ResultCardItem] = []
        var seen: Set<UUID> = []
        for job in jobs {
            if let b = job.batchID, let batch = batches.first(where: { $0.id == b }) {
                guard seen.insert(b).inserted else { continue }
                items.append(.batch(batch, batch.jobIDs.compactMap { id in jobs.first { $0.id == id } }))
            } else {
                items.append(.job(job))
            }
        }
        return items
    }

    var hasWork: Bool { jobs.contains(where: \.isWorking) }

    // MARK: Submitting

    /// Queues files. Unsupported files are skipped; returns how many were queued.
    @discardableResult
    func submit(_ urls: [URL], operation: JobOperation = .optimize, options: JobOptions = JobOptions()) -> Int {
        let s = settings()
        var accepted: [OptimizationJob] = []
        for url in urls {
            guard let kind = MediaKind.of(url, gifAsVideo: s.video.convertGIFs) else { continue }
            var op = operation
            if case .convert = operation, kind != .image { op = .optimize }
            if kind == .pdf, case .downscale = op { op = .optimize }
            // Skip files that are already being worked on.
            if jobs.contains(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL && $0.isWorking }) { continue }
            accepted.append(OptimizationJob(origin: .file(url), kind: kind, name: url.lastPathComponent, operation: op, options: options))
        }
        guard !accepted.isEmpty else { return 0 }
        if accepted.count >= Self.batchThreshold {
            let batch = JobBatch(id: UUID(), jobIDs: accepted.map(\.id))
            for job in accepted { job.batchID = batch.id }
            batches.append(batch)
        }
        jobs.append(contentsOf: accepted)
        trimFinished()
        schedule()
        return accepted.count
    }

    /// Optimizes an image from the clipboard and puts the result back.
    func submitClipboard(_ data: Data, type: UTType, options: JobOptions = JobOptions()) {
        let job = OptimizationJob(origin: .clipboard, kind: .image,
                                  name: String(localized: "Clipboard image", comment: "Optimizer: result card title for a copied image"),
                                  options: options)
        job.originalSize = Int64(data.count)
        let ext = type.preferredFilenameExtension ?? "png"
        do {
            job.backupURL = try backups.store(data, name: "\(Self.clipboardName()).\(ext)")
        } catch {
            log.error("Could not keep the clipboard original: \(error.localizedDescription, privacy: .public)")
        }
        jobs.append(job)
        trimFinished()
        schedule()
    }

    private static func clipboardName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Clipboard \(f.string(from: date))"
    }

    // MARK: Scheduling

    private func schedule() {
        let running = jobs.filter { if case .working = $0.state { return true } else { return false } }
        var videoSlots = running.contains { $0.kind == .video } ? 0 : 1
        var fileSlots = Self.parallelFiles - running.filter { $0.kind != .video }.count
        for job in jobs where job.state == .queued {
            if job.kind == .video {
                guard videoSlots > 0 else { continue }
                videoSlots -= 1
            } else {
                guard fileSlots > 0 else { continue }
                fileSlots -= 1
            }
            start(job)
        }
    }

    private func start(_ job: OptimizationJob) {
        job.state = .working(job.kind == .video ? 0 : nil)
        job.startedAt = Date()
        job.finishedAt = nil
        job.task = Task { [weak self] in
            await self?.run(job)
            self?.schedule()
        }
    }

    // MARK: Running

    private func run(_ job: OptimizationJob) async {
        let s = settings()
        let workDir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let source = try await prepareSource(job)
            if thumbnailNeeded(job) { Task { await self.loadThumbnail(job, from: source) } }
            let (output, detail, scale) = try await encode(job, source: source, into: workDir, settings: s)
            try Task.checkCancellation()
            let size = FileSize.of(output)
            guard job.isConversion || SizeGate.keeps(original: job.originalSize, candidate: size) else {
                finish(job, .unchanged)
                return
            }
            try place(job, output: output, settings: s)
            job.scale = scale
            job.resultSize = size
            job.detail = detail
            finish(job, .done)
            if let result = job.resultURL { Task { await self.loadThumbnail(job, from: result) } }
        } catch is CancellationError {
            finish(job, .cancelled)
        } catch {
            if job.transcoder?.isCancelled == true {
                finish(job, .cancelled)
            } else {
                log.error("\(job.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                finish(job, .failed(error.localizedDescription))
            }
        }
    }

    private func finish(_ job: OptimizationJob, _ state: OptimizationJob.State) {
        job.state = state
        job.finishedAt = Date()
        job.task = nil
        job.transcoder = nil
        onFinish(job)
        updateHideTimer()
    }

    /// Backs up the original on the first run and returns the file to read from.
    private func prepareSource(_ job: OptimizationJob) async throws -> URL {
        if let backup = job.backupURL { return backup }
        guard case .file(let url) = job.origin else { throw ImageOptimizer.Failure.unreadable }
        job.originalSize = FileSize.of(url)
        job.originalDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let store = backups
        let backup = try await Task.detached(priority: .userInitiated) { try store.backup(url) }.value
        job.backupURL = backup
        return backup
    }

    /// Encodes into `folder`; returns the file, a detail line for the card and the downscale factor.
    private func encode(_ job: OptimizationJob, source: URL, into folder: URL,
                        settings s: OptimizerSettings) async throws -> (URL, String, Double) {
        let base = (job.fileURL ?? source).deletingPathExtension().lastPathComponent
        switch job.kind {
        case .image:
            var factor: Double?
            var target: ImageFormat?
            switch job.operation {
            case .optimize: break
            case .downscale(let f): factor = f
            case .convert(let f): target = f
            }
            if job.origin == .clipboard { target = target ?? .png }
            let plan = ImagePlan(s.image, aggressive: job.options.aggressive, factor: factor, target: target)
            let encoded = try await Task.detached(priority: .userInitiated) {
                try ImageOptimizer.optimize(url: source, plan: plan)
            }.value
            let output = folder.appendingPathComponent(base).appendingPathExtension(encoded.format.fileExtension)
            try encoded.data.write(to: output)
            return (output, Self.imageDetail(encoded), factor ?? 1)

        case .pdf:
            let output = folder.appendingPathComponent(base).appendingPathExtension("pdf")
            let pdf = s.pdf
            let result = try await Task.detached(priority: .userInitiated) {
                try PDFOptimizer.optimize(source, to: output, resolution: pdf.imageResolution, quality: Double(pdf.imageQuality) / 100)
            }.value
            return (output, Self.pdfDetail(pages: result.pageCount, resolution: pdf.imageResolution), 1)

        case .video:
            let info = try await VideoTranscoder.info(of: source)
            var factor = 1.0
            if case .downscale(let f) = job.operation { factor = f }
            let ext = VideoPlan.outputExtension(forSource: (job.fileURL ?? source).pathExtension)
            let plan = VideoPlan.make(source: info, settings: s.video, fileExtension: ext, factor: factor,
                                      aggressive: job.options.aggressive, speed: job.options.speed,
                                      removeAudio: job.options.removeAudio)
            let output = folder.appendingPathComponent(base).appendingPathExtension(ext)
            let transcoder = VideoTranscoder()
            job.transcoder = transcoder
            let jobID = job.id
            try await transcoder.run(source: source, output: output, plan: plan) { [weak self] p in
                Task { @MainActor in
                    guard let job = self?.jobs.first(where: { $0.id == jobID }), job.isWorking else { return }
                    if let old = job.progress, p - old < 0.005, p < 1 { return }
                    job.state = .working(p)
                }
            }
            return (output, Self.videoDetail(plan, duration: info.duration / plan.speed), factor)
        }
    }

    /// Moves the encoded file to its destination (see `OutputNamer`) and marks it.
    private func place(_ job: OptimizationJob, output: URL, settings s: OptimizerSettings) throws {
        let fm = FileManager.default
        guard case .file(let original) = job.origin else {
            try placeClipboard(job, output: output)
            return
        }
        let previous = job.resultURL.flatMap { $0.path == original.path ? nil : $0 }
        let ext = output.pathExtension
        let destination: URL
        if job.isConversion {
            destination = OutputNamer.convertedURL(for: original, fileExtension: ext, reusing: previous)
        } else {
            destination = OutputNamer.optimizedURL(for: original, fileExtension: ext, mode: s.output, reusing: previous)
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: output)
        } else {
            try fm.moveItem(at: output, to: destination)
        }
        FileMarker.mark(destination)
        if destination.path == original.path {
            job.replacedOriginal = true
        } else if !job.isConversion, s.output == .replace, fm.fileExists(atPath: original.path) {
            // The format changed (PNG → JPEG): the original now lives only in the backups.
            try fm.removeItem(at: original)
            job.replacedOriginal = true
        }
        if let previous, previous.path != destination.path, fm.fileExists(atPath: previous.path) {
            try? fm.removeItem(at: previous)
        }
        if s.keepModificationDate, !job.isConversion, let date = job.originalDate {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
        }
        job.resultURL = destination
        job.name = destination.lastPathComponent
    }

    private func placeClipboard(_ job: OptimizationJob, output: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: clipboardFolder, withIntermediateDirectories: true)
        let destination = clipboardFolder.appendingPathComponent("\(Self.clipboardName()).\(output.pathExtension)")
        if let previous = job.resultURL { try? fm.removeItem(at: previous) }
        try fm.moveItem(at: output, to: destination)
        job.resultURL = destination
        let type = UTType(filenameExtension: output.pathExtension) ?? .png
        writeClipboard(try Data(contentsOf: destination), type)
        pruneClipboardFolder()
    }

    /// Keeps the last 20 optimized clipboard images.
    private func pruneClipboardFolder() {
        let files = (try? FileManager.default.contentsOfDirectory(at: clipboardFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(20) where !jobs.contains(where: { $0.resultURL == old }) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Card actions

    /// Puts the original back (or the original clipboard image).
    func restore(_ job: OptimizationJob) {
        guard let backup = job.backupURL else { return }
        do {
            switch job.origin {
            case .clipboard:
                let data = try Data(contentsOf: backup)
                writeClipboard(data, UTType(filenameExtension: backup.pathExtension) ?? .png)
            case .file(let original):
                let fm = FileManager.default
                if let result = job.resultURL, result.path != original.path, fm.fileExists(atPath: result.path) {
                    try fm.removeItem(at: result)
                }
                if job.replacedOriginal {
                    try backups.restore(backup, to: original)
                    FileMarker.mark(original)
                }
                job.name = original.lastPathComponent
            }
            job.resultURL = nil
            job.resultSize = nil
            job.replacedOriginal = false
            job.scale = 1
            finish(job, .restored)
        } catch {
            log.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            finish(job, .failed(String(localized: "Could not restore the original: \(error.localizedDescription)",
                                       comment: "Optimizer: the value is the system's error message")))
        }
    }

    func restoreAll(in batch: JobBatch) {
        for job in jobs where job.batchID == batch.id && job.canRestore { restore(job) }
    }

    /// Re-runs from the original at the next smaller size.
    func downscaleMore(_ job: OptimizationJob) {
        guard let next = DownscaleMath.nextFactor(after: job.scale), !job.isWorking else { return }
        job.operation = .downscale(next)
        rerun(job)
    }

    /// Re-runs from the original with other per-request options (speed, audio) or operation.
    func rerun(_ job: OptimizationJob, options: JobOptions? = nil) {
        guard !job.isWorking else { return }
        if let options { job.options = options }
        job.state = .queued
        job.finishedAt = nil
        schedule()
    }

    /// A new job that writes the original in another format.
    func convert(_ job: OptimizationJob, to format: ImageFormat) {
        guard job.kind == .image else { return }
        switch job.origin {
        case .clipboard:
            guard let backup = job.backupURL, let data = try? Data(contentsOf: backup) else { return }
            let new = OptimizationJob(origin: .clipboard, kind: .image,
                                      name: String(localized: "Clipboard image", comment: "Optimizer: result card title for a copied image"),
                                      operation: .convert(format))
            new.originalSize = Int64(data.count)
            new.backupURL = backup
            jobs.append(new)
        case .file(let url):
            let new = OptimizationJob(origin: .file(url), kind: .image, name: url.lastPathComponent, operation: .convert(format))
            new.backupURL = job.backupURL
            new.originalSize = job.originalSize
            jobs.append(new)
        }
        trimFinished()
        schedule()
    }

    func cancel(_ job: OptimizationJob) {
        job.transcoder?.cancel()
        job.task?.cancel()
        if job.state == .queued { finish(job, .cancelled) }
    }

    func cancelAll() {
        for job in jobs where job.isWorking { cancel(job) }
    }

    func dismiss(_ job: OptimizationJob) {
        if job.isWorking { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        batches = batches.compactMap { b in
            var b = b
            b.jobIDs.removeAll { $0 == job.id }
            return b.jobIDs.isEmpty ? nil : b
        }
    }

    func dismiss(batch: JobBatch) {
        for job in jobs where job.batchID == batch.id && job.isWorking { cancel(job) }
        jobs.removeAll { $0.batchID == batch.id }
        batches.removeAll { $0.id == batch.id }
    }

    func dismissAll() {
        for job in jobs where !job.isWorking { dismiss(job) }
    }

    /// Copies the result: the file, plus its image data so it pastes into image fields too.
    func copy(_ job: OptimizationJob) {
        guard let url = job.resultURL else { return }
        if job.origin == .clipboard {
            if let data = try? Data(contentsOf: url) { writeClipboard(data, UTType(filenameExtension: url.pathExtension) ?? .png) }
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        if job.kind == .image, let data = try? Data(contentsOf: url), let type = UTType(filenameExtension: url.pathExtension) {
            pb.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        HUD.show("Copied", symbol: "doc.on.doc")
    }

    func reveal(_ job: OptimizationJob) {
        let url = job.resultURL ?? job.fileURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ job: OptimizationJob) {
        let url = job.resultURL ?? job.fileURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Hiding

    /// Removes cards whose time is up (never while the pointer is over them or work is running).
    func hideExpired(now: Date = Date()) {
        guard !pointerInside, let delay = settings().hideResultsAfter.seconds else { return }
        let expired = { (job: OptimizationJob) -> Bool in
            guard let finished = job.finishedAt, !job.isWorking else { return false }
            return now.timeIntervalSince(finished) >= delay
        }
        // A batch goes only when all of its jobs are done.
        for batch in batches where jobs.filter({ $0.batchID == batch.id }).allSatisfy(expired) {
            dismiss(batch: batch)
        }
        for job in jobs where job.batchID == nil && expired(job) { dismiss(job) }
        updateHideTimer()
    }

    private func updateHideTimer() {
        let pending = jobs.contains { $0.finishedAt != nil }
        if pending, hideTimer == nil {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.hideExpired() }
            }
        } else if !pending {
            hideTimer?.invalidate()
            hideTimer = nil
        }
    }

    /// Keeps the panel from growing without end: drops the oldest finished single cards beyond eight.
    private func trimFinished() {
        let singles = jobs.filter { $0.batchID == nil && !$0.isWorking }
        for job in singles.dropLast(8) { dismiss(job) }
    }

    /// Sample content for preview scenes (nothing runs).
    func loadPreview(_ jobs: [OptimizationJob], batches: [JobBatch]) {
        self.jobs = jobs
        self.batches = batches
    }

    func stop() {
        cancelAll()
        hideTimer?.invalidate()
        hideTimer = nil
        jobs.removeAll()
        batches.removeAll()
    }

    // MARK: Thumbnails and details

    private func thumbnailNeeded(_ job: OptimizationJob) -> Bool { job.thumbnail == nil }

    private func loadThumbnail(_ job: OptimizationJob, from url: URL) async {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            job.thumbnail = rep.cgImage
        }
    }

    static func imageDetail(_ e: EncodedImage) -> String {
        var parts = [String(localized: "\(Int(e.pixelSize.width)) × \(Int(e.pixelSize.height))",
                            comment: "Optimizer: image size in pixels, width × height"), e.format.title]
        if let colors = e.colors { parts.append(String(localized: "\(colors) colors", comment: "Optimizer: palette size of a PNG")) }
        return parts.joined(separator: " · ")
    }

    static func pdfDetail(pages: Int, resolution: Int) -> String {
        [String(localized: "\(pages) pages", comment: "Optimizer: PDF page count"),
         String(localized: "images at \(resolution) dpi", comment: "Optimizer: PDF image resolution")].joined(separator: " · ")
    }

    static func videoDetail(_ plan: VideoPlan, duration: Double) -> String {
        let time = Duration.seconds(max(0, duration.rounded())).formatted(.time(pattern: .minuteSecond))
        return [String(localized: "\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height))",
                       comment: "Optimizer: image size in pixels, width × height"),
                plan.codec == .hevc ? "HEVC" : "H.264", time].joined(separator: " · ")
    }
}
