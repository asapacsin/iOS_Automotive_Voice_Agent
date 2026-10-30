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

/// What the phone's own recognizer heard. Partial and final texts are the whole utterance so far, not deltas.
public enum LocalTranscript: Sendable, Hashable {
    case partial(UtteranceID, String)
    case final(UtteranceID, String)
    case failed(UtteranceID, reason: String)

    public var utterance: UtteranceID {
        switch self {
        case .partial(let id, _), .final(let id, _), .failed(let id, _): id
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
