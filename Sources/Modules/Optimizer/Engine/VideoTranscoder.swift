import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a video file is like, for planning its re-encode.
struct VideoSourceInfo: Sendable, Equatable {
    /// Pixel size before the track's rotation.
    var naturalSize: CGSize
    var frameRate: Double
    /// Bits per second (0 when unknown).
    var bitrate: Double
    var duration: Double
    var hasAudio: Bool
}

/// The encoder settings for one video, derived from the user's settings and the source.
struct VideoPlan: Sendable, Equatable {
    var codec: VideoCodec
    var fileType: AVFileType
    var outputSize: CGSize
    /// Frames per second written (frames above it are dropped).
    var frameRate: Double
    /// Average bitrate ceiling, bits per second.
    var bitrate: Int
    /// Encoder quality 0…1, used where the hardware encoder supports constant quality (Apple silicon).
    var quality: Double
    var includesAudio: Bool
    var audioBitrate: Int
    var speed: Double

    /// Bits per pixel per frame at each quality level (HEVC; H.264 needs about 1.5 times more).
    static func bitsPerPixel(_ q: VideoQuality, codec: VideoCodec) -> Double {
        let hevc: Double = switch q {
        case .smaller: 0.05
        case .balanced: 0.08
        case .higher: 0.13
        }
        return codec == .h264 ? hevc * 1.5 : hevc
    }

    static func encoderQuality(_ q: VideoQuality) -> Double {
        switch q {
        case .smaller: 0.42
        case .balanced: 0.55
        case .higher: 0.68
        }
    }

    /// - Parameters:
    ///   - factor: downscale relative to the source (result card "Downscale").
    ///   - aggressive: ⌥ held when dropping: about 40 % fewer bits.
    ///   - speed, removeAudio: per-request overrides of the settings.
    static func make(source: VideoSourceInfo, settings: VideoSettings, fileExtension: String, factor: Double = 1,
                     aggressive: Bool = false, speed: Double? = nil, removeAudio: Bool? = nil) -> VideoPlan {
        let speed = min(4, max(0.25, speed ?? settings.speed))
        let size = DownscaleMath.videoTarget(source.naturalSize, shortSide: settings.maxResolution.shortSide, factor: factor)
        let sourceRate = source.frameRate > 0 ? source.frameRate * speed : 30
        let frameRate = min(sourceRate, settings.maxFrameRate.fps ?? .infinity)
        var bpp = bitsPerPixel(settings.quality, codec: settings.codec)
        var quality = encoderQuality(settings.quality)
        if aggressive {
            bpp *= 0.6
            quality -= 0.12
        }
        var bitrate = Double(size.width * size.height) * frameRate * bpp
        if source.bitrate > 0 { bitrate = min(bitrate, source.bitrate * speed * 0.9) }
        bitrate = max(150_000, bitrate)
        return VideoPlan(codec: settings.codec, fileType: fileType(forExtension: fileExtension), outputSize: size,
                         frameRate: frameRate, bitrate: Int((bitrate / 1000).rounded()) * 1000, quality: quality,
                         includesAudio: source.hasAudio && !(removeAudio ?? settings.removeAudio),
                         audioBitrate: aggressive ? 96_000 : 128_000, speed: speed)
    }

    /// The container for an output extension: QuickTime for .mov, MPEG-4 otherwise.
    static func fileType(forExtension ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mov", "qt": .mov
        case "m4v": .m4v
        default: .mp4
        }
    }

    /// The extension a video is written with: QuickTime and MPEG-4 keep theirs, everything else
    /// (GIF, AVI…) becomes .mp4.
    static func outputExtension(forSource ext: String) -> String {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v": ext.lowercased()
        default: "mp4"
        }
    }

    func videoSettings(includingQuality: Bool) -> [String: Any] {
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                          AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                                          AVVideoMaxKeyFrameIntervalKey: max(1, Int((frameRate * 2).rounded())),
                                          AVVideoAllowFrameReorderingKey: true]
        if includingQuality { compression[AVVideoQualityKey] = quality }
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: compression]
    }

    func audioSettings(channels: Int, sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVNumberOfChannelsKey: channels,
         AVSampleRateKey: sampleRate,
         AVEncoderBitRateKey: channels == 1 ? audioBitrate / 2 : audioBitrate]
    }
}

/// Re-encodes videos with AVFoundation (VideoToolbox hardware encoders) and turns GIFs into MP4.
/// Cancel with `cancel()` or by cancelling the calling task; partial output is deleted.
final class VideoTranscoder: @unchecked Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        case noVideo
        case protected
        case unreadable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "The file has no video track")
            case .protected: String(localized: "The video is copy-protected")
            case .unreadable: String(localized: "This video format can’t be read on macOS")
            case .failed(let reason): String(localized: "Encoding failed: \(reason)", comment: "Optimizer: the value is the system's error message")
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let r: AVAssetReader? = lock.withLock {
            cancelled = true
            return reader
        }
        r?.cancelReading()
    }

    // MARK: Inspecting

    static func isGIF(_ url: URL) -> Bool {
        MediaKind.contentType(of: url)?.conforms(to: .gif) ?? false
    }

    static func info(of url: URL) async throws -> VideoSourceInfo {
        if isGIF(url) { return try gifInfo(url).info }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else { throw Failure.unreadable }
        if try await asset.load(.hasProtectedContent) { throw Failure.protected }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (size, fps, rate) = try await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        var bitrate = Double(rate)
        if bitrate <= 0, duration > 0 { bitrate = Double(FileSize.of(url)) * 8 / duration }
        return VideoSourceInfo(naturalSize: CGSize(width: abs(size.width), height: abs(size.height)), frameRate: Double(fps),
                               bitrate: bitrate, duration: duration.isFinite ? duration : 0, hasAudio: hasAudio)
    }

    struct GIFInfo {
        var info: VideoSourceInfo
        var delays: [Double]
    }

    /// Frame delays the way browsers play them: under 20 ms means 100 ms.
    static func gifInfo(_ url: URL) throws -> GIFInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { throw Failure.unreadable }
        let count = CGImageSourceGetCount(src)
        let delays: [Double] = (0..<count).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
            let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
            return d < 0.02 ? 0.1 : d
        }
        let w = (first[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let h = (first[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        let duration = delays.reduce(0, +)
        return GIFInfo(info: VideoSourceInfo(naturalSize: CGSize(width: w, height: h),
                                             frameRate: duration > 0 ? Double(count) / duration : 10,
                                             bitrate: 0, duration: duration, hasAudio: false),
                       delays: delays)
    }

    // MARK: Encoding

    /// Re-encodes `source` into `output` following `plan`. `progress` gets 0…1.
    func run(source: URL, output: URL, plan: VideoPlan, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        do {
            try await withTaskCancellationHandler {
                if Self.isGIF(source) {
                    try await encodeGIF(source, to: output, plan: plan, progress: progress)
                } else {
                    try await transcode(source, to: output, plan: plan, progress: progress)
                }
            } onCancel: {
                cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw isCancelled ? CancellationError() : error
        }
        if isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
    }

    private func makeWriter(_ output: URL, plan: VideoPlan) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: output, fileType: plan.fileType)
        writer.shouldOptimizeForNetworkUse = true
        // Constant quality where the encoder supports it; otherwise (or for codecs this Mac can't
        // encode) fall back to bitrate only, then to H.264.
        var settings = plan.videoSettings(includingQuality: true)
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = plan.videoSettings(includingQuality: false)
        }
        if !writer.canApply(outputSettings: settings, forMediaType: .video), plan.codec == .hevc {
            var h264 = plan
            h264.codec = .h264
            settings = h264.videoSettings(includingQuality: false)
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.failed(String(localized: "this Mac can’t encode the video", comment: "Optimizer: reason in 'Encoding failed: …'"))
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return (writer, input)
    }

    private func transcode(_ source: URL, to output: URL, plan: VideoPlan,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audio = plan.includesAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        let duration = try await asset.load(.duration)
        let (transform, nominalRate) = try await video.load(.preferredTransform, .nominalFrameRate)

        // Speed changes go through a composition whose time range is scaled.
        var readAsset: AVAsset = asset
        var readVideo: AVAssetTrack = video
        var readAudio: AVAssetTrack? = audio
        if abs(plan.speed - 1) > 0.001 {
            let composition = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.noVideo
            }
            try v.insertTimeRange(range, of: video, at: .zero)
            v.preferredTransform = transform
            if let audio, let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try a.insertTimeRange(range, of: audio, at: .zero)
                readAudio = a
            }
            composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / plan.speed))
            readAsset = composition
            readVideo = v
        }
        let total = max(0.001, duration.seconds / plan.speed)

        let reader = try AVAssetReader(asset: readAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: readVideo, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let (writer, videoInput) = try makeWriter(output, plan: plan)
        videoInput.transform = transform

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if let readAudio {
            let (channels, rate) = try await Self.audioFormat(readAudio)
            let out = AVAssetReaderAudioMixOutput(audioTracks: [readAudio], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            ])
            out.audioTimePitchAlgorithm = .spectral
            let settings = plan.audioSettings(channels: channels, sampleRate: rate)
            if reader.canAdd(out), writer.canApply(outputSettings: settings, forMediaType: .audio) {
                reader.add(out)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioOutput = out
                audioInput = input
            }
        }

        lock.withLock { self.reader = reader }
        defer { lock.withLock { self.reader = nil } }
        guard reader.startReading() else { throw Failure.failed(reader.error?.localizedDescription ?? "") }
        guard writer.startWriting() else { throw Failure.failed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let sourceRate = nominalRate > 0 ? Double(nominalRate) * plan.speed : 0
        let limiter = FrameLimiter(fps: sourceRate > plan.frameRate + 0.5 ? plan.frameRate : nil)
        pump(videoInput, from: videoOutput, group: group, label: "video") { sample in
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            progress(min(1, t / total))
            return limiter.keeps(t)
        }
        if let audioInput, let audioOutput {
            pump(audioInput, from: audioOutput, group: group, label: "audio") { _ in true }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        if isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.failed(reader.error?.localizedDescription ?? "")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.failed(writer.error?.localizedDescription ?? "") }
        progress(1)
    }

    /// Copies samples from a reader output to a writer input on a queue of its own.
    private func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput, group: DispatchGroup, label: String,
                      filter: @escaping (CMSampleBuffer) -> Bool) {
        group.enter()
        var finished = false
        let queue = DispatchQueue(label: "com.w33d.mactoys.optimizer.\(label)")
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !finished else { return }
            while input.isReadyForMoreMediaData {
                if isCancelled {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                guard filter(sample) else { continue }
                if !input.append(sample) {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    private static func audioFormat(_ track: AVAssetTrack) async throws -> (channels: Int, rate: Double) {
        let formats = try await track.load(.formatDescriptions)
        let asbd = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = min(2, max(1, Int(asbd?.mChannelsPerFrame ?? 2)))
        let rate = asbd?.mSampleRate ?? 48_000
        return (channels, rate > 48_000 || rate < 8_000 ? 48_000 : rate)
    }

    // MARK: GIF

    private func encodeGIF(_ source: URL, to output: URL, plan: VideoPlan,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let gif = try Self.gifInfo(source)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Failure.unreadable }
        let (writer, input) = try makeWriter(output, plan: plan)
        let width = Int(plan.outputSize.width), height = Int(plan.outputSize.height)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.startWriting() else { throw Failure.failed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var time = 0.0
        let timescale: CMTimeScale = 600
        for (i, delay) in gif.delays.enumerated() {
            if isCancelled || Task.isCancelled { break }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                if isCancelled { break }
            }
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))   // transparent GIF pixels sit on white
                ctx.fill(rect)
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: rect)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(seconds: time / plan.speed, preferredTimescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: pts) { break }
            time += delay
            progress(Double(i + 1) / Double(max(1, gif.delays.count)))
        }
        input.markAsFinished()
        if isCancelled || Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        writer.endSession(atSourceTime: CMTime(seconds: time / plan.speed, preferredTimescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.failed(writer.error?.localizedDescription ?? "") }
        progress(1)
    }
}

/// Drops frames so that at most `fps` frames per second are kept; nil keeps every frame.
final class FrameLimiter: @unchecked Sendable {
    private let interval: Double?
    private var next = -Double.infinity

    init(fps: Double?) {
        interval = fps.flatMap { $0 > 0 ? 1 / $0 : nil }
    }

    func keeps(_ t: Double) -> Bool {
        guard let interval else { return true }
        let tolerance = interval / 4
        guard t >= next - tolerance else { return false }
        // After a gap, restart the grid at this frame instead of keeping a burst of frames.
        next = t - next > interval ? t + interval : next + interval
        return true
    }
}
