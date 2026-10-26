@preconcurrency import AVFoundation
import Foundation
import ImageIO
import NovaKit
import NovaPorts
import UniformTypeIdentifiers

/// F-20a camera adapter: the back (world-facing) wide camera feeding the floating preview and a photo
/// output for the still taken at a question. Runs only while the window is open (§13); `stop()` ends
/// the capture so the green camera indicator goes away. Image bytes are never logged (I-8).
public final class CameraSession: NSObject, CameraFrameSource, @unchecked Sendable {
    /// Longest side and JPEG quality of the still sent to the vision backend (F-20a §4).
    public static let maxPixelSize = 1024
    public static let jpegQuality = 0.7

    /// Attach to an `AVCaptureVideoPreviewLayer` in the app; the session object never changes.
    public let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "nova.camera")
    private var configured = false
    private var pending: [Int64: CheckedContinuation<JPEGImage, any Error>] = [:]

    override public init() { super.init() }

    public var isRunning: Bool { session.isRunning }

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
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { throw CameraError.permissionDenied }
        if !session.isRunning { try await start() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { continuation.resume(throwing: CameraError.unavailable); return }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                pending[settings.uniqueID] = continuation
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { throw CameraError.unavailable }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw CameraError.unavailable }
        session.addInput(input)
        session.addOutput(photoOutput)
        configured = true
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
