import AppKit
import AVFoundation
import ImageIO
import QuartzCore
import MacToysCore
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum RecorderError: Error, LocalizedError {
    case noFrames
    case notFound
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames: String(localized: "Nothing was recorded.")
        case .notFound: String(localized: "The display or window is no longer available.")
        case .writerFailed(let why):
            String(localized: "The recording couldn’t be written: \(why)", comment: "%@ is the reason, e.g. “the encoder stopped”")
        }
    }
}

/// Writes ScreenCaptureKit samples into a movie with `AVAssetWriter`, on its own queue.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.w33d.mactoys.zoomit.record")
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false
    /// Set once the writer fails; later samples are dropped.
    private var failed = false
    /// Called once, on the writer's queue, when writing fails mid-recording.
    var onFailure: (@Sendable (Error) -> Void)?
    private var lastVideoTime = CMTime.invalid
    /// `CACurrentMediaTime()` when `lastVideoTime` arrived, to extend a still screen to the stop time.
    private var lastArrival: CFTimeInterval = 0

    init(url: URL, fileType: AVFileType, width: Int, height: Int, codec: VideoCodec, fps: Int,
         systemAudio wantsSystem: Bool, microphone wantsMic: Bool, mono: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let bitrate = min(60_000_000, max(2_000_000, Double(width * height * fps) * 0.12))
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                          AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps * 2]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        video.expectsMediaDataInRealTime = true
        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudio = wantsSystem ? audioInput(channels: 2) : nil
        microphone = wantsMic ? audioInput(channels: mono ? 1 : 2) : nil
        super.init()
        for input in [video, systemAudio, microphone].compactMap({ $0 }) where writer.canAdd(input) { writer.add(input) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, !failed else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  sample.imageBuffer != nil else { return }
            let time = sample.presentationTimeStamp
            if !started {
                guard writer.startWriting() else { fail(); return }
                writer.startSession(atSourceTime: time)
                started = true
            }
            if video.isReadyForMoreMediaData {
                if video.append(sample) {
                    lastVideoTime = time
                    lastArrival = CACurrentMediaTime()
                } else if writer.status == .failed {
                    fail()
                }
            }
        case .audio:
            if started, let input = systemAudio, input.isReadyForMoreMediaData { input.append(sample) }
        case .microphone:
            if started, let input = microphone, input.isReadyForMoreMediaData { input.append(sample) }
        @unknown default:
            break
        }
    }

    private func fail() {
        failed = true
        onFailure?(writer.error ?? RecorderError.writerFailed(String(localized: "the encoder stopped",
                                                                       comment: "Reason a recording couldn’t be written")))
    }

    /// Finishes the file. ScreenCaptureKit sends no frames while the screen is still, so the
    /// session is extended from the last frame to `stoppedAt` (a `CACurrentMediaTime()`).
    func finish(stoppedAt: CFTimeInterval, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard started, !failed, writer.status == .writing else {
                if writer.status == .writing { writer.cancelWriting() }
                completion(writer.error ?? RecorderError.noFrames)
                return
            }
            for input in [video, systemAudio, microphone].compactMap({ $0 }) { input.markAsFinished() }
            let tail = CMTime(seconds: max(0, stoppedAt - lastArrival), preferredTimescale: 600)
            writer.endSession(atSourceTime: CMTimeAdd(lastVideoTime, tail))
            writer.finishWriting { [writer] in
                completion(writer.status == .completed ? nil : (writer.error ?? RecorderError.writerFailed(String(localized: "unknown error",
                                                                                   comment: "Reason a recording couldn’t be written"))))
            }
        }
    }
}

/// Records the full screen, a region or a window with ScreenCaptureKit.
@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate {
    enum Target {
        case display(NSScreen)
        /// Screen-local points, origin top-left.
        case region(NSScreen, CGRect)
        case window(CGWindowID)
    }

    /// Called when the stream stops by itself (display gone, permission revoked).
    var onInterrupted: (() -> Void)?
    private(set) var startedAt: Date?
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private let log = Log.for("zoomit")

    var isRecording: Bool { stream != nil }

    /// Starts recording. `excluding` are window numbers kept out of the video (toolbars, the indicator).
    func start(_ target: Target, settings: ZoomItSettings, excluding: [Int]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { excluding.contains(Int($0.windowID)) }
        let filter: SCContentFilter
        var size: CGSize
        var scale: CGFloat
        let config = SCStreamConfiguration()
        switch target {
        case .display(let screen), .region(let screen, _):
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw RecorderError.notFound }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            size = screen.frame.size
            scale = screen.backingScaleFactor
            if case .region(_, let rect) = target {
                config.sourceRect = rect
                size = rect.size
            }
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.notFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
            scale = ScreenGeometry.screen(forAX: window.frame)?.backingScaleFactor ?? 2
            config.ignoreShadowsSingleWindow = true
        }
        var factor = CGFloat(min(1, max(0.1, settings.recordScaling)))
        // Apple's H.264 encoders top out at 4096 pixels on a side; HEVC goes to 8192.
        let limit: CGFloat = settings.videoCodec == .h264 ? 4096 : 8192
        let longest = max(size.width, size.height) * scale * factor
        if longest > limit { factor *= limit / longest }
        let width = Self.even(size.width * scale * factor), height = Self.even(size.height * scale * factor)
        let fps = min(60, max(5, settings.frameRate))
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = settings.recordPointer
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.capturesAudio = settings.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let mic = settings.captureMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        config.captureMicrophone = mic
        if mic, !settings.microphoneID.isEmpty { config.microphoneCaptureDeviceID = settings.microphoneID }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomIt-\(UUID().uuidString)")
            .appendingPathExtension(settings.recordFormat == .mp4 ? "mp4" : "mov")
        let writer = try RecordingWriter(url: url, fileType: settings.recordFormat == .mp4 ? .mp4 : .mov,
                                         width: width, height: height, codec: settings.videoCodec, fps: fps,
                                         systemAudio: settings.captureSystemAudio, microphone: mic,
                                         mono: settings.monoMicrophone)
        writer.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.log.error("Recording writer failed: \(error.localizedDescription, privacy: .public)")
                self?.onInterrupted?()
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if settings.captureSystemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if mic { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
        try await stream.startCapture()
        self.stream = stream
        self.writer = writer
        startedAt = Date()
    }

    /// Stops and returns the finished temporary movie.
    func stop() async throws -> URL {
        guard let stream, let writer else { throw RecorderError.noFrames }
        self.stream = nil
        self.writer = nil
        startedAt = nil
        let stoppedAt = CACurrentMediaTime()
        do { try await stream.stopCapture() } catch {
            log.notice("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish(stoppedAt: stoppedAt) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        return writer.url
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.log.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
            self.onInterrupted?()
        }
    }

    static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
}

/// Converts a movie to an animated GIF.
enum GIFExporter {
    static func export(movie: URL, to url: URL, fps: Int, scale: Double) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecorderError.noFrames }
        let natural = try await track.load(.naturalSize)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: natural.width * scale, height: natural.height * scale)
        let count = max(1, Int(duration * Double(fps)))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw RecorderError.writerFailed(String(localized: "the GIF file couldn’t be created",
                                                    comment: "Reason a recording couldn’t be written"))
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frame)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw RecorderError.writerFailed(String(localized: "the GIF couldn’t be encoded", comment: "Reason a recording couldn’t be written"))
        }
    }
}

/// The small "● 00:12 ■" pill shown while recording; kept out of the video.
@MainActor
@Observable
final class RecordingIndicatorModel {
    var elapsed = "00:00"
}

struct RecordingIndicator: View {
    let model: RecordingIndicatorModel
    let stop: () -> Void

    var body: some View {
        GlassPanel(cornerRadius: 14) {
            HStack(spacing: 9) {
                Color.clear.frame(width: 9, height: 9)
                Text(verbatim: model.elapsed).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white)
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Stop recording (⌃⌥5)")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        }
        // Outside the glass, which would render the dot in its monochrome vibrancy.
        .overlay(alignment: .leading) {
            Circle().fill(Color.red).frame(width: 9, height: 9).padding(.leading, 12)
        }
    }
}
