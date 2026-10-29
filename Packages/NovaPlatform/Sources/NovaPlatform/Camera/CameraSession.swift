@preconcurrency import AVFoundation
import Foundation
import ImageIO
import NovaKit
import NovaPorts
import UniformTypeIdentifiers

/// F-20a camera adapter: the back (world-facing) wide camera feeding the floating preview and a photo
/// output for the still taken at a question. Runs only while the window is open (§13); `stop()` ends
/// the capture so the green camera indicator goes away. Image bytes are never logged (I-8).
/// F-20b: one session, one lens at a time; `select` swaps the input between the back lens (前方) and the
/// selfie lens (后方). The preview may mirror the selfie lens; the still is never mirrored.
public final class CameraSession: NSObject, CameraFrameSource, @unchecked Sendable {
    /// Longest side and JPEG quality of the still sent to the vision backend (F-20a §4).
    public static let maxPixelSize = 1024
    public static let jpegQuality = 0.7
    /// Longest a lens switch may take (F-20b §9).
    public static let switchDeadline: TimeInterval = 1

    /// Attach to an `AVCaptureVideoPreviewLayer` in the app; the session object never changes.
    public let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "nova.camera")
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var pending: [Int64: CheckedContinuation<JPEGImage, any Error>] = [:]

    override public init() { super.init() }

    public var isRunning: Bool { session.isRunning }

    /// False where there is no selfie lens (the simulator): the switch button is disabled (F-20b §3).
    public var hasRearLens: Bool { Self.device(for: .rearView) != nil }

    /// A preview layer for the floating window; the app hosts it without importing AVFoundation.
    @MainActor
    public func makePreviewLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// Asks for permission when needed and starts the preview. Throws `CameraError`.
    public func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.permissionDenied }
        default:
            throw CameraError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                    if !session.isRunning { session.startRunning() }
                    if session.isRunning {
                        done.resume()
                    } else {
                        done.resume(throwing: CameraError.unavailable)
                    }
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the capture; a still in flight fails with `CameraError.unavailable`.
    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            let waiting = pending
            pending = [:]
            waiting.values.forEach { $0.resume(throwing: CameraError.unavailable) }
        }
    }

    // MARK: CameraFrameSource

    public func captureStill() async throws -> JPEGImage {
        // Only the runtime starts the camera (F-20a §13): a closed window never captures.
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { throw CameraError.permissionDenied }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { continuation.resume(throwing: CameraError.unavailable); return }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                pending[settings.uniqueID] = continuation
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Swaps the input to `lens` inside one configuration; on failure or after `switchDeadline` the old
    /// lens stays. Stills queue behind it on the session queue.
    public func select(_ lens: CameraLens) async throws {
        let outcome = SwitchOutcome()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            outcome.set(done)
            queue.async { [self] in
                guard (try? configureIfNeeded()) != nil else { outcome.finish(CameraError.unavailable); return }
                let previous = input
                let ok = (try? swapInput(to: lens)) != nil
                // Too late: the caller already gave up, so put the old lens back.
                if ok, !outcome.finish(nil), let previous { try? swap(to: previous) }
                if !ok { outcome.finish(CameraError.unavailable) }
            }
            // Not on `queue`: the swap blocks it.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.switchDeadline) {
                outcome.finish(CameraError.unavailable)
            }
        }
    }

    private static func device(for lens: CameraLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens == .rearView ? .front : .back)
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = Self.device(for: .frontView),
              let input = try? AVCaptureDeviceInput(device: device) else { throw CameraError.unavailable }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw CameraError.unavailable }
        session.addInput(input)
        session.addOutput(photoOutput)
        self.input = input
        configured = true
        unmirrorStill()
    }

    /// On the session queue.
    private func swapInput(to lens: CameraLens) throws {
        if input?.device.position == (lens == .rearView ? .front : .back) { return }
        guard let device = Self.device(for: lens), let next = try? AVCaptureDeviceInput(device: device) else {
            throw CameraError.unavailable
        }
        try swap(to: next)
    }

    private func swap(to next: AVCaptureDeviceInput) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(next) else {
            if let input { session.addInput(input) }
            throw CameraError.unavailable
        }
        session.addInput(next)
        input = next
        unmirrorStill()
    }

    /// F-20b §4: the still is sent as the lens sees it, so left and right in the answer are true.
    private func unmirrorStill() {
        guard let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    /// Downscales to `maxPixelSize` on the longest side and re-encodes at `jpegQuality`.
    static func shrink(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// The first of "switched", "failed" and "deadline" resumes the caller.
private final class SwitchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// True when this call decided the outcome.
    @discardableResult
    func finish(_ error: (any Error)?) -> Bool {
        let won: CheckedContinuation<Void, any Error>?? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return .some(continuation)
        }
        guard let won else { return false }
        if let error { won?.resume(throwing: error) } else { won?.resume() }
        return true
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: (any Error)?) {
        let id = photo.resolvedSettings.uniqueID
        let jpeg = error == nil ? photo.fileDataRepresentation().flatMap(Self.shrink) : nil
        queue.async { [self] in
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let jpeg {
                continuation.resume(returning: JPEGImage(data: [UInt8](jpeg)))
            } else {
                continuation.resume(throwing: CameraError.unavailable)
            }
        }
    }
}
