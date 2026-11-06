import CSherpaOnnx
import Foundation
import NovaPorts
import NovaVoice

/// F-01 §14 item 1 (T-060a): 你好小诺 with no account or key. Implements the `WakeEngine` port with its own sherpa-onnx
/// `KeywordSpotter` on the bundled `SherpaModels/kws` model (the one the stop phrases use, F-08 §14), over the two
/// `WakePhrase` token lines with the wake threshold and boost from `Tuning`. The spotter is loaded at the first
/// `start` and kept for the app run; each start opens a fresh stream. Everything that touches the spotter runs on the
/// engine's own serial queue, so the capture thread only enqueues a frame. A model that does not load throws from
/// `start`, and `RetryingWakeDetector` applies F-01 §8 (bounded retries, then unavailable; the talk button stays).
public final class SherpaWakeEngine: WakeEngine, @unchecked Sendable {
    private let directory: URL?
    private let queue = DispatchQueue(label: "com.asapacsin.novadrive.wake", qos: .userInitiated)
    // Touched only on `queue`.
    private var spotter: OpaquePointer?
    private var stream: OpaquePointer?
    private var onEvent: (@Sendable (WakeEngineEvent) -> Void)?
    private var filter = WakeHitFilter()

    /// `directory` is `SherpaModels/kws` in the app bundle (nil when the bundle has no models).
    public init(directory: URL?) { self.directory = directory }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
    }

    /// §14 item 4: the engine counts as available when the KWS model is there (manifest and files). Loading itself
    /// happens in `start`; a load failure goes through the bounded retry.
    public static func modelPresent(in directory: URL?) -> Bool {
        guard let directory else { return false }
        return (try? SherpaModelManifest.load(from: directory, file: SherpaModelManifest.kwsFile)) != nil
    }

    public func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.open(onEvent)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    public func write(_ frame: PCMFrame16k) {
        queue.async { self.decode(frame) }
    }

    public func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if let stream = self.stream { SherpaOnnxDestroyOnlineStream(stream) }
                self.stream = nil
                self.onEvent = nil
                done.resume()
            }
        }
    }

    // MARK: On `queue`

    private func open(_ onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) throws {
        let spotter: OpaquePointer
        if let loaded = self.spotter {
            spotter = loaded
        } else {
            guard let directory else { throw SherpaError.missingFile(SherpaModelManifest.kwsFile) }
            spotter = try Self.load(directory)
            self.spotter = spotter
        }
        guard let fresh = SherpaOnnxCreateKeywordStream(spotter) else { throw SherpaError.loadFailed("kws stream") }
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        stream = fresh
        filter = WakeHitFilter()
        self.onEvent = onEvent
    }

    private func decode(_ frame: PCMFrame16k) {
        guard let spotter, let stream, let onEvent else { return }
        filter.frame()
        let samples = SampleConversion.floats(frame.samples)
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(PCMFrame16k.sampleRate), $0.baseAddress, Int32($0.count))
        }
        var woke = false
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let keyword = result.pointee.keyword.map { String(cString: $0) } ?? ""
            SherpaOnnxDestroyKeywordResult(result)
            guard !keyword.isEmpty else { continue }
            // §14 item 2: either form is a wake; the other form on the same words is not a second one.
            if filter.hit(keyword) { woke = true }
            SherpaOnnxResetKeywordStream(spotter, stream)
        }
        if woke { onEvent(.detected) }
    }

    /// Like `SherpaStopPhraseSpotter.init`, with the wake keywords and the wake tuning.
    private static func load(_ directory: URL) throws -> OpaquePointer {
        let manifest = try SherpaModelManifest.load(from: directory, file: SherpaModelManifest.kwsFile)
        let strings = CStrings()
        let keywords = WakePhrase.keywordsFile(boost: Tuning.wakeBoost, threshold: Tuning.wakeThreshold)
        return try withExtendedLifetime(strings) {
            var config = SherpaOnnxKeywordSpotterConfig()
            config.feat_config = SherpaConfig.features
            config.model_config = try SherpaConfig.model(manifest, directory: directory, strings: strings)
            config.model_config.num_threads = Tuning.numThreads
            config.max_active_paths = Tuning.maxActivePaths
            config.num_trailing_blanks = Tuning.numTrailingBlanks
            config.keywords_score = Tuning.wakeBoost
            config.keywords_threshold = Tuning.wakeThreshold
            config.keywords_buf = strings.make(keywords)
            config.keywords_buf_size = Int32(keywords.utf8.count)
            guard let spotter = withUnsafePointer(to: &config, { SherpaOnnxCreateKeywordSpotter($0) }) else {
                throw SherpaError.loadFailed(manifest.name)
            }
            return spotter
        }
    }
}
