import CSherpaOnnx
import Foundation
import NovaPorts
import NovaVoice

/// F-08 §14 item 2: the on-phone stop-phrase spotter, a sherpa-onnx `KeywordSpotter` over `StopPhrases` (pinyin
/// tokens, `@<index>` labels) with per-phrase boost and threshold from `Tuning`. Fed only inside the gate's stop-phrase
/// window (`StopPhraseFeeder`). `accept` decodes inline: the KWS model is ~3 M parameters and a 10 ms frame decodes
/// in well under a frame. Not thread-safe; call it from one thread (the capture path).
public final class SherpaStopPhraseSpotter: StopPhraseSpotter {
    public let modelName: String
    public let loadMs: Int
    private let spotter: OpaquePointer
    private var stream: OpaquePointer

    /// Loads `<directory>/kws.json` and the files it names; `keywords` is a sherpa-onnx keywords file
    /// (`tokens @label` per line, the label being the `StopPhrases.all` index).
    public init(directory: URL, keywords: String = StopPhrases.keywordsFile) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let manifest = try SherpaModelManifest.load(from: directory, file: SherpaModelManifest.kwsFile)
        let strings = CStrings()
        let tuned = Tuning.tuned(keywords)
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config = SherpaConfig.features
        config.model_config = try SherpaConfig.model(manifest, directory: directory, strings: strings)
        config.model_config.num_threads = Tuning.numThreads
        config.max_active_paths = Tuning.maxActivePaths
        config.num_trailing_blanks = Tuning.numTrailingBlanks
        config.keywords_score = Tuning.defaultBoost
        config.keywords_threshold = Tuning.defaultThreshold
        config.keywords_buf = strings.make(tuned)
        config.keywords_buf_size = Int32(tuned.utf8.count)
        guard let spotter = withUnsafePointer(to: &config, { SherpaOnnxCreateKeywordSpotter($0) }) else {
            throw SherpaError.loadFailed(manifest.name)
        }
        guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            throw SherpaError.loadFailed(manifest.name)
        }
        self.spotter = spotter
        self.stream = stream
        modelName = manifest.name
        loadMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    public func accept(_ frame: PCMFrame16k) -> StopPhraseHit? {
        let samples = SampleConversion.floats(frame.samples)
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(PCMFrame16k.sampleRate), $0.baseAddress, Int32($0.count))
        }
        var hit: StopPhraseHit?
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let keyword = result.pointee.keyword.map { String(cString: $0) } ?? ""
            SherpaOnnxDestroyKeywordResult(result)
            guard !keyword.isEmpty else { continue }
            // The C API reports no score for a hit, so it is 0 (the log field stays).
            if hit == nil, let phrase = KeywordLabel.phrase(keyword) { hit = StopPhraseHit(phrase: phrase, score: 0) }
            SherpaOnnxResetKeywordStream(spotter, stream)
        }
        return hit
    }

    public func reset() {
        guard let fresh = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxResetKeywordStream(spotter, stream)
            return
        }
        SherpaOnnxDestroyOnlineStream(stream)
        stream = fresh
    }
}
