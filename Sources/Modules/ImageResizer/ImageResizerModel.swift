import Foundation
import Observation

/// State of one Image Resizer window.
@MainActor
@Observable
final class ImageResizerModel {
    enum Phase: Equatable {
        case choosing
        case resizing(done: Int, current: String)
        case finished(Summary)
    }

    struct Summary: Equatable {
        var outputs: [URL]
        var failures: [String]
        var cancelled: Bool
    }

    let urls: [URL]
    /// Shown under the title: "from Finder selection".
    let source: String
    var presets: [ResizePreset]
    var custom: ResizePreset
    /// Index into `presets`, or -1 for the custom size.
    var selectedIndex: Int
    var options: ResizeOptions
    private(set) var phase: Phase = .choosing

    /// Called when a batch starts, so the module can remember the choices.
    @ObservationIgnored var onStart: ((ImageResizerModel) -> Void)?
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private let live: Bool

    init(urls: [URL], source: String, settings: ImageResizerSettings, live: Bool = true) {
        self.urls = urls
        self.source = source
        presets = settings.presets
        custom = settings.custom
        selectedIndex = settings.selectedIndex == -1 || settings.presets.indices.contains(settings.selectedIndex)
            ? settings.selectedIndex : 0
        options = settings.options
        self.live = live
    }

    var selectedPreset: ResizePreset {
        selectedIndex == -1 ? custom : (presets.indices.contains(selectedIndex) ? presets[selectedIndex] : custom)
    }

    var title: String { "Resize \(urls.count) image\(urls.count == 1 ? "" : "s")" }

    func start() {
        guard live, !urls.isEmpty, phase == .choosing else { return }
        onStart?(self)
        let urls = urls, preset = selectedPreset, options = options
        let flag = CancelFlag()
        cancelFlag = flag
        phase = .resizing(done: 0, current: urls.first?.lastPathComponent ?? "")
        Task { [weak self] in
            var outputs: [URL] = []
            var failures: [String] = []
            for (i, url) in urls.enumerated() {
                if flag.isSet { break }
                self?.phase = .resizing(done: i, current: url.lastPathComponent)
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try ImageResizerEngine.resize(url: url, preset: preset, options: options) }
                }.value
                switch result {
                case .success(let out): outputs.append(out)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
            self?.phase = .finished(Summary(outputs: outputs, failures: failures, cancelled: flag.isSet))
        }
    }

    func cancel() { cancelFlag.set() }

    /// For previews.
    func showPhase(_ phase: Phase) { self.phase = phase }
}

/// A thread-safe stop flag for the background batch.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
