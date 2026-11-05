import CSherpaOnnx
import Foundation
import NovaPorts

/// F-04b §6 item 1 (T-013e): the speaker-lock manifest, `SherpaModels/speaker/speaker.json`.
extension SherpaModelManifest {
    public static let speakerFile = "speaker.json"
}

/// F-04b §6 item 1 (T-013e): what `speaker.json` names. The speaker model has no tokens or type, so it is not a
/// `SherpaModelManifest`. `dim`, when present, is the embedding length the model must report.
public struct SherpaSpeakerManifest: Decodable, Sendable, Hashable {
    public let name: String
    public let model: String
    public let dim: Int?

    /// Reads `<directory>/speaker.json` and checks that the model file it names is present.
    public static func load(from directory: URL) throws -> SherpaSpeakerManifest {
        let file = SherpaModelManifest.speakerFile
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent(file)) } catch {
            throw SherpaError.missingFile(file)
        }
        let manifest: SherpaSpeakerManifest
        do { manifest = try JSONDecoder().decode(SherpaSpeakerManifest.self, from: data) } catch {
            throw SherpaError.badManifest(file)
        }
        guard !manifest.name.isEmpty, !manifest.model.isEmpty else { throw SherpaError.badManifest(file) }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest.model).path) else {
            throw SherpaError.missingFile(manifest.model)
        }
        return manifest
    }
}

/// F-04b §6 item 1 (T-013e): why an embedding could not be computed (beyond `SherpaError`'s missing or bad model).
public enum SherpaSpeakerError: Error, Sendable, Hashable {
    /// The stream did not have enough feature frames: too little audio to embed.
    case notReady
    /// The model's embedding length is not the one expected (the manifest's `dim`, or the length seen at load).
    case dimensionMismatch(expected: Int, got: Int)
}

/// F-04b §6 item 1 (T-013e): the `SpeakerVerifier` adapter. One sherpa-onnx `SpeakerEmbeddingExtractor` on the bundled
/// `SherpaModels/speaker` model (CPU, one thread), loaded at the first `embedding` call and kept for the app run; each
/// call opens its own stream, feeds the frames as `sample / 32768` floats at 16 kHz, finishes it and copies the vector.
/// A load failure is remembered and rethrown without reloading (the bundle does not change during a run), so a broken
/// model fails closed every time (§6 item 11) without paying the load again. Callers use one background serial queue;
/// a lock makes concurrent calls safe anyway. Nothing here logs audio or words, and nothing leaves the phone (§4 item 7).
public final class SherpaSpeakerVerifier: SpeakerVerifier, @unchecked Sendable {
    /// The manifest's `name` (read in `init`, without loading the model); "" when there is no usable manifest.
    public let modelName: String

    private let directory: URL?
    private let manifest: SherpaSpeakerManifest?
    private let lock = NSLock()
    // Guarded by `lock`.
    private var extractor: OpaquePointer?
    private var loadedDimension = 0
    private var loadError: (any Error)?

    /// `directory` is `SherpaModels/speaker` in the app bundle (nil when the bundle has no models).
    public init(directory: URL?) {
        self.directory = directory
        manifest = directory.flatMap { try? SherpaSpeakerManifest.load(from: $0) }
        modelName = manifest?.name ?? ""
    }

    deinit {
        if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
    }

    /// Like `SherpaWakeEngine.modelPresent`: the manifest is there and the model file it names exists.
    public static func modelPresent(in directory: URL?) -> Bool {
        guard let directory else { return false }
        return (try? SherpaSpeakerManifest.load(from: directory)) != nil
    }

    /// The embedding length; 0 until the model has loaded (or when it failed to).
    public var dimension: Int { lock.withLock { loadedDimension } }

    public func embedding(of frames: [PCMFrame16k]) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(frames.count * PCMFrame16k.samplesPerFrame)
        for frame in frames { samples.append(contentsOf: SampleConversion.floats(frame.samples)) }
        return try lock.withLock { try compute(samples) }
    }

    // MARK: Under `lock`

    private func compute(_ samples: [Float]) throws -> [Float] {
        let extractor = try loaded()
        guard !samples.isEmpty, samples.count <= Int(Int32.max) else { throw SherpaSpeakerError.notReady }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else {
            throw SherpaError.loadFailed("speaker stream")
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(PCMFrame16k.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0 else {
            throw SherpaSpeakerError.notReady
        }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        guard dim == loadedDimension else {
            throw SherpaSpeakerError.dimensionMismatch(expected: loadedDimension, got: dim)
        }
        guard let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else {
            throw SherpaError.loadFailed("speaker embedding")
        }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: dim))
    }

    private func loaded() throws -> OpaquePointer {
        if let extractor { return extractor }
        if let loadError { throw loadError }
        do {
            let (created, dim) = try load()
            extractor = created
            loadedDimension = dim
            return created
        } catch {
            loadError = error
            throw error
        }
    }

    /// Creates the extractor; the config's C strings stay alive until the Create call has copied them.
    private func load() throws -> (OpaquePointer, Int) {
        guard let directory else { throw SherpaError.missingFile(SherpaModelManifest.speakerFile) }
        let manifest = try self.manifest ?? SherpaSpeakerManifest.load(from: directory)
        let strings = CStrings()
        let created: OpaquePointer? = withExtendedLifetime(strings) {
            var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
            config.model = strings.make(directory.appendingPathComponent(manifest.model).path)
            config.num_threads = 1
            config.debug = 0
            config.provider = strings.make("cpu")
            return withUnsafePointer(to: &config) { SherpaOnnxCreateSpeakerEmbeddingExtractor($0) }
        }
        guard let created else { throw SherpaError.loadFailed(manifest.name) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(created))
        let expected = manifest.dim ?? dim
        guard dim > 0, dim == expected else {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(created)
            throw SherpaSpeakerError.dimensionMismatch(expected: expected, got: dim)
        }
        return (created, dim)
    }
}
