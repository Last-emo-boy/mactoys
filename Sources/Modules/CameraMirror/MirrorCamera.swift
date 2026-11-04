import AppKit
@preconcurrency import AVFoundation
import MacToysCore
import Observation

/// One camera the mirror can show.
struct MirrorDevice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case builtIn, external, continuity, deskView }

    let id: String
    let name: String
    let kind: Kind

    var symbol: String {
        switch kind {
        case .builtIn: "web.camera"
        case .external: "video"
        case .continuity: "iphone"
        case .deskView: "rectangle.and.hand.point.up.left"
        }
    }
}

/// The capture session behind the mirror. It runs only while a mirror is on screen: `start()`
/// when the panel or window opens, `stop()` the moment it closes (the camera light goes off).
@MainActor
@Observable
final class MirrorCamera {
    enum Status: Equatable {
        case idle
        case starting
        case running
        /// No camera is connected (or none MacToys may use).
        case noCamera
        /// Camera access not granted yet; `denied` means the user said no (System Settings needed).
        case needsPermission(denied: Bool)
        case failed(String)
    }

    private(set) var devices: [MirrorDevice] = []
    private(set) var status: Status = .idle
    private(set) var activeDevice: MirrorDevice?
    /// Pixel size of the active camera format (the preview's aspect ratio).
    private(set) var sourceSize = CGSize(width: 1920, height: 1080)
    private(set) var hint: LightHint = .good

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.w33d.mactoys.mirror.session", qos: .userInitiated)
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let analyzer = FrameAnalyzer()
    @ObservationIgnored private var pendingPhotos: [PhotoCapture] = []
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Log.for("mirror")

    init() {
        analyzer.onHint = { [weak self] hint in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.status == .running, self.hint != hint else { return }
                    self.hint = hint
                }
            }
        }
    }

    var isRunning: Bool { status == .running }

    /// Puts the camera in a fixed state for preview scenes (no session runs).
    func preview(status: Status, devices: [MirrorDevice], active: MirrorDevice?, hint: LightHint = .good) {
        self.status = status
        self.devices = devices
        self.activeDevice = active
        self.hint = hint
    }

    // MARK: - Devices

    /// Whether Continuity Camera (an iPhone used as a webcam) may be listed: macOS only offers it
    /// to apps that declare `NSCameraUseContinuityCameraDeviceType` in their Info.plist.
    static var continuityAllowed: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool) == true
    }

    func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if Self.continuityAllowed { types += [.continuityCamera, .deskViewCamera] }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        devices = found.map { d in
            let kind: MirrorDevice.Kind = switch d.deviceType {
            case .builtInWideAngleCamera: .builtIn
            case .continuityCamera: .continuity
            case .deskViewCamera: .deskView
            default: .external
            }
            return MirrorDevice(id: d.uniqueID, name: d.localizedName, kind: kind)
        }
    }

    /// Watches cameras being plugged in or removed while a mirror is open.
    private func observeDevices(_ on: Bool) {
        for token in deviceObservers { NotificationCenter.default.removeObserver(token) }
        deviceObservers.removeAll()
        guard on else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.wanted else { return }
                    self.refreshDevices()
                    if let active = self.activeDevice, !self.devices.contains(active) { self.start(preferring: nil) }
                    else if self.status == .noCamera { self.start(preferring: nil) }
                }
            })
        }
    }

    private func device(for id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id), devices.contains(where: { $0.id == id }) { return d }
        if let preferred = AVCaptureDevice.systemPreferredCamera, devices.contains(where: { $0.id == preferred.uniqueID }) {
            return preferred
        }
        return devices.first.flatMap { AVCaptureDevice(uniqueID: $0.id) }
    }

    // MARK: - Running

    /// Starts (or switches) the camera. `preferring` is a device id; nil follows the system's choice.
    func start(preferring id: String?, lightCheck: Bool = true) {
        wanted = true
        analyzer.isEnabled = lightCheck
        observeDevices(true)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            status = .needsPermission(denied: false)
            return
        default:
            status = .needsPermission(denied: true)
            return
        }
        refreshDevices()
        guard let device = device(for: id) else {
            status = .noCamera
            activeDevice = nil
            return
        }
        let info = devices.first { $0.id == device.uniqueID }
        if activeDevice == info && (status == .running || status == .starting) { return }
        status = .starting
        activeDevice = info
        hint = .good
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dims.width > 0 && dims.height > 0 { sourceSize = CGSize(width: Int(dims.width), height: Int(dims.height)) }
        generation += 1
        let gen = generation
        let session = self.session, photo = photoOutput, video = videoOutput, analyzer = self.analyzer
        queue.async { [weak self] in
            let error = Self.configure(session, device: device, photo: photo, video: video, analyzer: analyzer)
            video.connection(with: .video)?.isEnabled = lightCheck
            if error == nil && !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, self.wanted else { return }
                    if let error {
                        self.log.error("Camera failed: \(error, privacy: .public)")
                        self.status = .failed(error)
                    } else {
                        self.status = .running
                    }
                }
            }
        }
    }

    /// Stops the session and releases the camera at once.
    func stop() {
        wanted = false
        generation += 1
        observeDevices(false)
        status = .idle
        hint = .good
        let session = self.session, analyzer = self.analyzer
        queue.async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
            analyzer.reset()
        }
    }

    /// Asks for camera access, then starts if it was granted.
    func requestAccess(then start: @escaping @MainActor () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PermissionCenter.shared.refresh()
                    if granted { start() } else { self.status = .needsPermission(denied: true) }
                }
            }
        }
    }

    func setLightCheck(_ on: Bool) {
        analyzer.isEnabled = on
        if !on { hint = .good }
        let video = videoOutput
        queue.async { video.connection(with: .video)?.isEnabled = on }
    }

    nonisolated private static func configure(_ session: AVCaptureSession, device: AVCaptureDevice, photo: AVCapturePhotoOutput,
                                              video: AVCaptureVideoDataOutput, analyzer: FrameAnalyzer) -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        for input in session.inputs { session.removeInput(input) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return String(localized: "The camera is in use by another app.") }
            session.addInput(input)
        } catch {
            return error.localizedDescription
        }
        if !session.outputs.contains(photo), session.canAddOutput(photo) { session.addOutput(photo) }
        if !session.outputs.contains(video) {
            // A tiny, late-frame-dropping copy for the light check: about 15 kB per frame.
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                   kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90]
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(analyzer, queue: analyzer.queue)
            if session.canAddOutput(video) { session.addOutput(video) }
        }
        return nil
    }

    // MARK: - Photos

    /// Captures a full-resolution still; `completion` gets nil on failure.
    func capturePhoto(completion: @escaping @MainActor (CGImage?) -> Void) {
        guard status == .running, session.outputs.contains(photoOutput) else { completion(nil); return }
        let capture = PhotoCapture()
        capture.completion = { [weak self, weak capture] image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let capture { self?.pendingPhotos.removeAll { $0 === capture } }
                    completion(image)
                }
            }
        }
        pendingPhotos.append(capture)
        let output = photoOutput
        queue.async {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            output.capturePhoto(with: settings, delegate: capture)
        }
    }
}

/// Measures frame brightness off the main thread, at most once every half second.
final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.w33d.mactoys.mirror.light", qos: .utility)
    /// Read on the capture queue; a plain flag is fine (a stale value only skips or adds one sample).
    var isEnabled = true
    var onHint: ((LightHint) -> Void)?
    private var meter = LightMeter()
    private var last: CFTimeInterval = 0
    private var shown: LightHint = .good

    func reset() {
        queue.async { self.meter.reset(); self.shown = .good; self.last = 0 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - last >= 0.5, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let sample = LightCheck.sample(bgra: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        let hint = meter.add(sample)
        if hint != shown {
            shown = hint
            onHint?(hint)
        }
    }
}

/// One photo request; holds its own completion until AVFoundation calls back.
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    var completion: ((CGImage?) -> Void)?

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { Log.for("mirror").error("Photo failed: \(error.localizedDescription, privacy: .public)") }
        let image = error == nil ? photo.cgImageRepresentation() : nil
        completion?(image)
        completion = nil
    }
}
