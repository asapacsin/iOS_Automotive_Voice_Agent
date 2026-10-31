import Foundation
import NovaPorts

/// F-05a §12 item 10: the `asrUtterance` log line's numbers. Never the text (I-8).
public struct SherpaUtteranceTiming: Sendable, Hashable {
    public let id: UtteranceID
    /// `begin` to the first non-empty partial; nil when there was none.
    public let firstPartialMs: Int?
    /// `end` to the final.
    public let finalMs: Int
    /// Audio fed, from the sample count.
    public let audioMs: Int
    /// Time spent inside sherpa-onnx decode calls.
    public let decodeMs: Int

    /// `asrUtterance id=… firstPartialMs=… finalMs=… audioMs=… decodeMs=…` (numbers only).
    public var logLine: String {
        "asrUtterance id=\(id.value) firstPartialMs=\(firstPartialMs.map(String.init) ?? "-") finalMs=\(finalMs) "
            + "audioMs=\(audioMs) decodeMs=\(decodeMs)"
    }
}

enum SampleConversion {
    /// Int16 PCM to the float samples sherpa-onnx takes, `sample / 32768`.
    static func floats(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32_768 }
    }
}

/// The open utterance's bookkeeping (§9: events of closed or superseded utterances are dropped). Not thread-safe:
/// `SherpaTranscriber` touches it only on its serial decode queue. Times are monotonic nanoseconds.
struct UtteranceBook {
    private(set) var current: UtteranceID?
    private var lastText = ""
    private var beganNs: UInt64 = 0
    private var firstPartialNs: UInt64?
    private var endedNs: UInt64?
    private var sampleCount = 0
    private var decodeNs: UInt64 = 0

    /// Opens `id`; returns the utterance it supersedes, if one was still open.
    mutating func begin(_ id: UtteranceID, now: UInt64) -> UtteranceID? {
        let superseded = current
        self = UtteranceBook()
        current = id
        beganNs = now
        return superseded
    }

    var isOpen: Bool { current != nil && endedNs == nil }

    mutating func fed(samples: Int) { if isOpen { sampleCount += samples } }
    mutating func decoded(ns: UInt64) { if current != nil { decodeNs += ns } }

    /// The partial to emit for the decoded `text`: only when it changed and is not empty.
    mutating func partial(_ text: String, now: UInt64) -> LocalTranscript? {
        guard let id = current, endedNs == nil, !text.isEmpty, text != lastText else { return nil }
        lastText = text
        if firstPartialNs == nil { firstPartialNs = now }
        return .partial(id, text)
    }

    /// `end(id)`: true when `id` is the open utterance (the caller then decodes the rest and calls `finish`).
    mutating func end(_ id: UtteranceID, now: UInt64) -> Bool {
        guard current == id, endedNs == nil else { return false }
        endedNs = now
        return true
    }

    /// The final and the utterance's numbers; closes it.
    mutating func finish(_ text: String, now: UInt64) -> (LocalTranscript, SherpaUtteranceTiming)? {
        guard let id = current, let endedNs else { return nil }
        let metrics = SherpaUtteranceTiming(
            id: id,
            firstPartialMs: firstPartialNs.map { Self.ms($0 &- beganNs) },
            finalMs: Self.ms(now &- endedNs),
            audioMs: sampleCount * 1000 / PCMFrame16k.sampleRate,
            decodeMs: Self.ms(decodeNs))
        current = nil
        return (.final(id, text), metrics)
    }

    static func ms(_ ns: UInt64) -> Int { Int(ns / 1_000_000) }
}
