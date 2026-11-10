import NovaKit

/// F-05a: one driver utterance, from the uplink gate opening to `activityEnd`.
public struct UtteranceID: Sendable, Hashable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public enum TranscriberAvailability: Sendable, Hashable {
    case ready
    /// The phone cannot recognise on device; `reason` is the diagnostics text (「未授权」, 「本机不支持」).
    case unavailable(reason: String)
}

/// F-05a §14 item 2 (T-016l): the language of an utterance's final, from SenseVoice's `lang`.
public enum SpokenLanguage: String, Sendable, Hashable {
    case zh, en, ja, other

    /// `zh` and `yue` → zh, `en` → en, `ja` → ja, anything else (`ko`, empty) → other. SenseVoice may write the
    /// tag form (`<|en|>`); the brackets are removed first.
    public init(senseVoice lang: String) {
        let code = lang.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch code {
        case "zh", "yue": self = .zh
        case "en": self = .en
        case "ja": self = .ja
        default: self = .other
        }
    }

    /// SenseVoice's tags (`<|en|>`, emotion and event tags) never reach the text.
    public static func senseVoiceText(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<|") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "|>") else { rest = rest[open.lowerBound...]; break }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the phone's own recognizer heard. Partial and final texts are the whole utterance so far, not deltas.
/// A final's `language` is SenseVoice's (§14 item 2); nil is the streaming model's final.
public enum LocalTranscript: Sendable, Hashable {
    case partial(UtteranceID, String)
    case final(UtteranceID, String, language: SpokenLanguage? = nil)
    case failed(UtteranceID, reason: String)

    public var utterance: UtteranceID {
        switch self {
        case .partial(let id, _), .final(let id, _, _), .failed(let id, _): id
        }
    }
}

/// F-05a §4: the on-device `zh-CN` recognizer (adapter `SherpaTranscriber` in NovaAsrSherpa, F-05a §12). It gets the same
/// frames that go up to Gemini, one request per utterance.
public protocol LocalTranscriber: Sendable {
    var availability: TranscriberAvailability { get async }
    func begin(utterance: UtteranceID) async
    func append(_ frame: PCMFrame16k) async
    func end(utterance: UtteranceID) async
    var events: AsyncStream<LocalTranscript> { get }
}

/// F-05a §15 item 1 (T-016m): one hypothesis of a text's language. `language` is a BCP-47 code (`en`, `pt`, `zh-Hans`).
public struct LanguageHypothesis: Sendable, Hashable {
    public let language: String
    public let probability: Double

    public init(language: String, probability: Double) {
        self.language = language
        self.probability = probability
    }
}

/// F-05a §15 item 1: the language detector her reply is checked with. Production: `AppleLanguageIdentifier`
/// (NovaPlatform, `NLLanguageRecognizer`, no language constraints); tests use a fake.
public protocol LanguageIdentifier: Sendable {
    /// At most 3 hypotheses, most likely first.
    func hypotheses(_ text: String) -> [LanguageHypothesis]
}

/// No detector: no hypotheses, so Latin-only text is decided by the end-of-reply rule only.
public struct NoLanguageIdentifier: LanguageIdentifier {
    public init() {}
    public func hypotheses(_ text: String) -> [LanguageHypothesis] { [] }
}
