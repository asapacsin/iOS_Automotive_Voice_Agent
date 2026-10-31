import NovaKit
import NovaPorts

/// The driver's words as AgentCore takes them (F-05a). Texts are the whole utterance so far, not deltas.
public enum DriverWords: Sendable, Hashable {
    /// Words still coming (subtitle, stop phrase).
    case partial(String)
    /// The utterance's words; the guards may read them.
    case final(String)
    /// S4: what came back is not Chinese. The subtitle shows 「（没听清）」 and nothing counts as the driver's words.
    case unclear
}

/// F-05a §5 (T-016a): picks the one transcript AgentCore sees. The phone's on-device `zh-CN` recognizer wins and
/// Gemini's input transcript is dropped (S1); Gemini is the fallback only when the phone has no text for the
/// utterance, and only Chinese text passes (S3, S4). Pure: time comes in as `now`, waits go out as `.schedule`.
public struct TranscriptSelector: Sendable {
    public struct Tuning: Sendable, Hashable {
        /// S2: how long after the utterance ends the local final may take.
        public var localFinalWait = NovaDuration.milliseconds(800)
        public init() {}
    }

    public enum Output: Sendable, Hashable {
        case words(DriverWords)
        /// Call `deadline(_:at:)` at `at`.
        case schedule(UtteranceID, at: NovaInstant)
    }

    private struct Utterance {
        let id: UtteranceID
        /// The local recognizer was ready at the start and has not given up on this utterance without text.
        var local: Bool
        var ended = false
        var done = false
        var localFailed = false
        var lastPartial = ""
        /// Gemini's text for this utterance, kept while local runs in case it is needed (S3).
        var gemini = ""
        var geminiFinal: String?
    }

    public let tuning: Tuning
    private var current: Utterance?

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// The uplink gate opened a new utterance. An older one still waiting is superseded: its events are dropped.
    public mutating func begin(_ id: UtteranceID, localReady: Bool) -> [Output] {
        current = Utterance(id: id, local: localReady)
        return []
    }

    public mutating func local(_ event: LocalTranscript, at now: NovaInstant) -> [Output] {
        guard var u = current, u.id == event.utterance, !u.done, u.local else { return [] }
        defer { current = u }
        switch event {
        case .partial(_, let text):
            u.lastPartial = text
            return text.isEmpty ? [] : [.words(.partial(text))]
        case .final(_, let text):
            u.done = true
            // S5: silence or noise passed the gate; nothing was said.
            return text.isEmpty ? [] : [.words(.final(text))]
        case .failed:
            u.localFailed = true
            return u.ended ? resolve(&u) : []
        }
    }

    /// Gemini's `userTranscript`: partials are deltas, the final is the whole text.
    public mutating func gemini(_ text: String, isFinal: Bool, at now: NovaInstant) -> [Output] {
        guard var u = current, !u.done else { return [] }
        defer { current = u }
        if isFinal { u.geminiFinal = text } else { u.gemini += text }
        // S1: while the phone has this utterance, Gemini's guess is not used.
        guard !u.local else { return [] }
        if isFinal {
            u.done = true
            return Self.checked(text)
        }
        return TranscriptLanguage.isChinese(u.gemini) ? [.words(.partial(u.gemini))] : []
    }

    /// The utterance closed (`activityEnd`).
    public mutating func end(_ id: UtteranceID, at now: NovaInstant) -> [Output] {
        guard var u = current, u.id == id, !u.done, !u.ended else { return [] }
        defer { current = u }
        u.ended = true
        guard u.local else { return [] }
        if u.localFailed { return resolve(&u) }
        return [.schedule(id, at: now + tuning.localFinalWait)]
    }

    /// S2: the local final did not come within `localFinalWait`.
    public mutating func deadline(_ id: UtteranceID, at now: NovaInstant) -> [Output] {
        guard var u = current, u.id == id, !u.done, u.local else { return [] }
        defer { current = u }
        return resolve(&u)
    }

    /// No local final: the last local partial is the final; with no local text at all, Gemini's (S3).
    private func resolve(_ u: inout Utterance) -> [Output] {
        if !u.lastPartial.isEmpty {
            u.done = true
            return [.words(.final(u.lastPartial))]
        }
        u.local = false
        if let text = u.geminiFinal {
            u.done = true
            return Self.checked(text)
        }
        return TranscriptLanguage.isChinese(u.gemini) ? [.words(.partial(u.gemini))] : []
    }

    /// S3 / S4 / S5 for a Gemini final.
    private static func checked(_ text: String) -> [Output] {
        if text.allSatisfy(\.isWhitespace) { return [] }
        return [.words(TranscriptLanguage.isChinese(text) ? .final(text) : .unclear)]
    }
}
