import CSherpaOnnx
import Dispatch
import Foundation
import NovaKit
import NovaPorts

/// F-05a §14 item 2 (T-016l): the downloaded SenseVoice model as one sherpa-onnx `OfflineRecognizer`, loaded once.
/// It decodes a whole utterance (`language` empty = auto, `use_itn` 1). Nothing here logs the text (I-8).
public final class SherpaSenseVoice: @unchecked Sendable {
    /// `model.int8.onnx` and `tokens.txt` (`MultilingualModel.files`).
    public static let modelFile = "model.int8.onnx"
    public static let tokensFile = "tokens.txt"

    public let loadMs: Int
    private let recognizer: OpaquePointer
    /// Decodes run one at a time, off the streaming recognizer's queue.
    private let queue = DispatchQueue(label: "com.asapacsin.novadrive.sensevoice", qos: .userInitiated)

    /// Slow (seconds for a 239 MB model): call it off the main actor.
    public init(directory: URL) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        for name in [Self.modelFile, Self.tokensFile]
        where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw SherpaError.missingFile(name)
        }
        let strings = CStrings()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config = SherpaConfig.features
        config.model_config.sense_voice.model = strings.make(directory.appendingPathComponent(Self.modelFile).path)
        config.model_config.sense_voice.language = strings.make("")
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = strings.make(directory.appendingPathComponent(Self.tokensFile).path)
        config.model_config.num_threads = 2
        config.model_config.provider = strings.make("cpu")
        config.model_config.debug = 0
        config.decoding_method = strings.make("greedy_search")
        // The config points into `strings`; keep them alive until the recognizer has copied what it needs.
        let created = withExtendedLifetime(strings) { withUnsafePointer(to: &config) { SherpaOnnxCreateOfflineRecognizer($0) } }
        guard let recognizer = created else {
            throw SherpaError.loadFailed("sensevoice")
        }
        self.recognizer = recognizer
        loadMs = UtteranceBook.ms(DispatchTime.now().uptimeNanoseconds - started)
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    /// One utterance's 16 kHz samples → text without tags, its language and the decode time; on `queue`.
    func decode(_ samples: [Float], done: @escaping @Sendable (_ text: String, _ language: SpokenLanguage, _ ms: Int) -> Void) {
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return done("", .other, 0) }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            samples.withUnsafeBufferPointer {
                SherpaOnnxAcceptWaveformOffline(stream, Int32(PCMFrame16k.sampleRate), $0.baseAddress, Int32($0.count))
            }
            SherpaOnnxDecodeOfflineStream(recognizer, stream)
            var text = "", lang = ""
            if let result = SherpaOnnxGetOfflineStreamResult(stream) {
                text = result.pointee.text.map { String(cString: $0) } ?? ""
                lang = result.pointee.lang.map { String(cString: $0) } ?? ""
                SherpaOnnxDestroyOfflineRecognizerResult(result)
            }
            let ms = UtteranceBook.ms(DispatchTime.now().uptimeNanoseconds - started)
            done(SpokenLanguage.senseVoiceText(text), SpokenLanguage(senseVoice: lang), ms)
        }
    }
}
