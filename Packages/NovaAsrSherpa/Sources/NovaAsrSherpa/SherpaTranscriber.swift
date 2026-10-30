import CSherpaOnnx
import Dispatch
import Foundation
import NovaKit
import NovaPorts

/// F-05a §12 (T-016f): the bundled Mandarin recognizer. One sherpa-onnx `OnlineRecognizer`, loaded once in `init`;
/// one stream per utterance (`begin` creates it, `append` feeds it, `end` finishes it and emits the final).
/// sherpa-onnx endpointing is off: the uplink gate decides where an utterance starts and ends (item 5). All decoding
/// runs on one serial queue, so the capture thread only converts samples and enqueues. Nothing here logs the text (I-8).
public final class SherpaTranscriber: LocalTranscriber, @unchecked Sendable {
    public let modelName: String
    /// How long `init` took to load the model, for `asrLoaded model=<name> ms=<loadMs>`.
    public let loadMs: Int
    public let events: AsyncStream<LocalTranscript>

    private let continuation: AsyncStream<LocalTranscript>.Continuation
    private let recognizer: OpaquePointer
    private let queue = DispatchQueue(label: "com.asapacsin.novadrive.sherpa-asr", qos: .userInitiated)
    // Queue-confined.
    private var stream: OpaquePointer?
    private var book = UtteranceBook()

    private let lock = NSLock()
    private var timingHandler: (@Sendable (SherpaUtteranceTiming) -> Void)?

    /// Called on the decode queue once per finished utterance with its numbers (never the text).
    public var onTiming: (@Sendable (SherpaUtteranceTiming) -> Void)? {
        get { lock.withLock { timingHandler } }
        set { lock.withLock { timingHandler = newValue } }
    }

    /// Loads `<directory>/asr.json` and the model files it names. Slow (hundreds of ms): call it off the main actor.
    public init(directory: URL) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let manifest = try SherpaModelManifest.load(from: directory, file: SherpaModelManifest.asrFile)
        let strings = CStrings()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config = SherpaConfig.features
        config.model_config = try SherpaConfig.model(manifest, directory: directory, strings: strings)
        config.decoding_method = strings.make("greedy_search")
        config.max_active_paths = 4
        config.enable_endpoint = 0
        guard let recognizer = withUnsafePointer(to: &config, { SherpaOnnxCreateOnlineRecognizer($0) }) else {
            throw SherpaError.loadFailed(manifest.name)
        }
        self.recognizer = recognizer
        modelName = manifest.name
        loadMs = UtteranceBook.ms(DispatchTime.now().uptimeNanoseconds - started)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
        continuation.finish()
    }

    /// Loaded in `init`, so always ready; a failed load throws there instead (§12 items 7, 9 are the App's).
    public var availability: TranscriberAvailability { get async { .ready } }

    public func begin(utterance id: UtteranceID) async {
        queue.async { [self] in
            // A superseded utterance is dropped without a final (§9).
            if let stream { SherpaOnnxDestroyOnlineStream(stream) }
            stream = SherpaOnnxCreateOnlineStream(recognizer)
            _ = book.begin(id, now: Self.now)
            if stream == nil {
                book = UtteranceBook()
                continuation.yield(.failed(id, reason: "识别出错"))
            }
        }
    }

    public func append(_ frame: PCMFrame16k) async {
        let samples = SampleConversion.floats(frame.samples)
        queue.async { [self] in
            guard let stream, book.isOpen else { return }
            samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(PCMFrame16k.sampleRate), $0.baseAddress, Int32($0.count))
            }
            book.fed(samples: samples.count)
            decodeReady(stream)
            if let partial = book.partial(text(stream), now: Self.now) { continuation.yield(partial) }
        }
    }

    public func end(utterance id: UtteranceID) async {
        queue.async { [self] in
            guard let stream, book.end(id, now: Self.now) else { return }
            SherpaOnnxOnlineStreamInputFinished(stream)
            decodeReady(stream)
            let finalText = text(stream)
            SherpaOnnxDestroyOnlineStream(stream)
            self.stream = nil
            guard let (final, metrics) = book.finish(finalText, now: Self.now) else { return }
            continuation.yield(final)
            onTiming?(metrics)
        }
    }

    // MARK: decode queue only

    private func decodeReady(_ stream: OpaquePointer) {
        let started = Self.now
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        book.decoded(ns: Self.now - started)
    }

    private func text(_ stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}
