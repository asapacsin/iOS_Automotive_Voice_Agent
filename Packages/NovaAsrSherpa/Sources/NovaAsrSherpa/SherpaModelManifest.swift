import Foundation

/// The manifest that scripts/fetch_sherpa_models.sh writes next to each model: `<dir>/asr.json` or `<dir>/kws.json`.
/// File names are relative to that directory.
public struct SherpaModelManifest: Decodable, Sendable, Hashable {
    public let name: String
    /// "transducer" (encoder, decoder, joiner) or "ctc" (model; streaming Zipformer2 CTC).
    public let type: String
    public let encoder: String?
    public let decoder: String?
    public let joiner: String?
    public let model: String?
    public let tokens: String

    public static let asrFile = "asr.json"
    public static let kwsFile = "kws.json"

    /// Reads `<directory>/<file>` and checks that the files its type needs are named and present.
    public static func load(from directory: URL, file: String) throws -> SherpaModelManifest {
        let url = directory.appendingPathComponent(file)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SherpaError.missingFile(file) }
        let manifest: SherpaModelManifest
        do { manifest = try JSONDecoder().decode(SherpaModelManifest.self, from: data) } catch {
            throw SherpaError.badManifest(file)
        }
        let files = try manifest.modelFiles()
        for name in files.all where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw SherpaError.missingFile(name)
        }
        return manifest
    }

    public enum Files: Sendable, Hashable {
        case transducer(encoder: String, decoder: String, joiner: String, tokens: String)
        case ctc(model: String, tokens: String)

        var all: [String] {
            switch self {
            case let .transducer(e, d, j, t): [e, d, j, t]
            case let .ctc(m, t): [m, t]
            }
        }
    }

    /// The files by role; throws when the type is unknown or a file it needs is not named.
    public func modelFiles() throws -> Files {
        switch type {
        case "transducer":
            guard let encoder, let decoder, let joiner else { throw SherpaError.badManifest("\(name): transducer files") }
            return .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        case "ctc":
            guard let model else { throw SherpaError.badManifest("\(name): ctc model") }
            return .ctc(model: model, tokens: tokens)
        default:
            throw SherpaError.badManifest("\(name): type \(type)")
        }
    }
}

public enum SherpaError: Error, Sendable, Hashable {
    case missingFile(String)
    case badManifest(String)
    /// sherpa-onnx returned no recognizer / spotter (bad model files or config).
    case loadFailed(String)
}
