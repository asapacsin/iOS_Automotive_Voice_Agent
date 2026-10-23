import NovaKit

/// One 10 ms capture frame: 16 kHz mono PCM16, exactly 160 samples = 320 bytes (contracts/audio.md).
public struct PCMFrame16k: Sendable, Hashable {
    public static let sampleRate = 16_000
    public static let samplesPerFrame = 160
    public static let byteCount = samplesPerFrame * 2

    public let samples: [Int16]

    /// Returns nil unless `samples` holds exactly one 10 ms frame.
    public init?(samples: [Int16]) {
        guard samples.count == PCMFrame16k.samplesPerFrame else { return nil }
        self.samples = samples
    }

    public static let silence = PCMFrame16k(samples: Array(repeating: 0, count: samplesPerFrame))!
}

/// Mono PCM16 buffer at a stated rate (24 kHz for replies, any rate for guidance fallback).
public struct PCMBuffer: Sendable, Hashable {
    public static let replySampleRate = 24_000

    public let sampleRate: Int
    public let samples: [Int16]

    public init(sampleRate: Int, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var duration: NovaDuration {
        NovaDuration(milliseconds: Int64(samples.count) * 1_000 / Int64(max(sampleRate, 1)))
    }
}

/// Echo-cancelled capture (NovaAudio). Frames are delivered on the capture queue, in order.
public protocol CaptureSource: Sendable {
    func start(onFrame: @escaping @Sendable (PCMFrame16k) -> Void) throws
    func stop()
}

public enum PlaybackEvent: Sendable, Hashable {
    case replyStarted(Epoch)
    case replyFinished(Epoch)
    case guidanceStarted(GuidanceID)
    case guidanceEnded(GuidanceID)
}

/// Three lanes on one voice-processing engine (ios-architecture §6.4).
public protocol PlaybackPort: Sendable {
    /// Synchronous: stop the reply lane and raise the epoch. Audio of older epochs is discarded.
    func flush(to epoch: Epoch)
    func enqueueReply(_ pcm: PCMBuffer, epoch: Epoch, sequence: Int)
    func completeReply(epoch: Epoch)
    func playGuidance(_ pcm: PCMBuffer, id: GuidanceID)
    func playMedia(_ track: BundledTrack)
    func stopMedia()
    var events: AsyncStream<PlaybackEvent> { get }
    /// Lock-protected; read synchronously by the Amap `driveManagerIsNaviSoundPlaying:` delegate.
    var guidanceSounding: Bool { get }
}

public struct BundledTrack: Sendable, Hashable {
    public let resourceName: String
    public init(resourceName: String) { self.resourceName = resourceName }
}

/// iOS audio-session signals mapped to arbiter inputs (ios-architecture §6.6).
public enum AudioSessionEvent: Sendable, Hashable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeLost
    /// A usable output route exists again (route change with a new device): re-evaluate after `routeLost`.
    case routeAvailable
    case mediaServicesReset
}

public protocol AudioSessionEvents: Sendable {
    var events: AsyncStream<AudioSessionEvent> { get }
}

/// How 小诺 speaks (F-21, `A/SpeakingStyle.kt` wire names).
public enum SpeakingStyle: String, Sendable, Hashable, CaseIterable {
    case `default`, sweet, tsundere, gentle, lively
}

/// Why a clause was not synthesised. Codes only (I-8): `AZURE_TTS_AUTH`, `AZURE_TTS_TIMEOUT`, ...
public struct SpeechSynthesisError: Error, Sendable, Hashable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// Azure Speech REST: one clause to 24 kHz PCM. Throws `SpeechSynthesisError` or `CancellationError`.
public protocol SpeechSynthesizer: Sendable {
    func synthesize(_ text: String, style: SpeakingStyle, deadline: NovaDuration) async throws -> PCMBuffer
    /// One minimal request so the synthesis path is warm; at most once per 15 s. Never played.
    func warmUp() async
}

/// Speaks a guidance sentence when the relay falls back (OQ-IOS-10).
public protocol FallbackGuidanceVoice: Sendable {
    func render(_ text: String) async throws -> PCMBuffer
}

public enum WakeEvent: Sendable, Hashable {
    case ready
    case wake
    case failed(attempt: Int)
    case unavailable
}

/// Offline wake word fed from the shared capture (one capture only, ADR-006).
public protocol WakeWordDetector: Sendable {
    func arm() async
    func disarm() async
    func feed(_ frame: PCMFrame16k)
    var events: AsyncStream<WakeEvent> { get }
}
