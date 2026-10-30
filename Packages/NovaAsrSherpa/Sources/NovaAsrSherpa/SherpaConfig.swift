import CSherpaOnnx
import Foundation

/// C strings that stay alive while a sherpa-onnx config is in use (the Create calls copy what they need).
final class CStrings {
    private var owned: [UnsafeMutablePointer<CChar>] = []
    func make(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        owned.append(p)
        return UnsafePointer(p)
    }
    deinit { owned.forEach { free($0) } }
}

enum SherpaConfig {
    static func model(_ manifest: SherpaModelManifest, directory: URL, strings: CStrings) throws
        -> SherpaOnnxOnlineModelConfig {
        func path(_ name: String) -> UnsafePointer<CChar> { strings.make(directory.appendingPathComponent(name).path) }
        var config = SherpaOnnxOnlineModelConfig()
        switch try manifest.modelFiles() {
        case let .transducer(encoder, decoder, joiner, tokens):
            config.transducer.encoder = path(encoder)
            config.transducer.decoder = path(decoder)
            config.transducer.joiner = path(joiner)
            config.tokens = path(tokens)
        case let .ctc(model, tokens):
            config.zipformer2_ctc.model = path(model)
            config.tokens = path(tokens)
        }
        config.num_threads = 2
        config.provider = strings.make("cpu")
        config.debug = 0
        return config
    }

    static var features: SherpaOnnxFeatureConfig {
        SherpaOnnxFeatureConfig(sample_rate: 16_000, feature_dim: 80)
    }
}

extension UnsafePointer<CChar> {
    var string: String { String(cString: self) }
}
