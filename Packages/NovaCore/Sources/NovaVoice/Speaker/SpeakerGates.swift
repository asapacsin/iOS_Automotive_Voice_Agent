import NovaKit
import NovaPorts

/// F-04b §6 item 9 (T-013e): with the lock on, a live interruption acts only on an accepted utterance. `BargeInLive`'s
/// steps for the open utterance are held while its verdict is pending (no dip, no stop before acceptance); accepted
/// releases them in order, rejected drops the actions and turns what it would have sent into a not-sent utterance.
/// Lock off (verdict nil): steps pass unchanged. Pure.
public struct SpeakerActionHold: Sendable {
    private var queue: [BargeInLive.Step] = []
    /// The open utterance was rejected: what the live interruption sends for it is not sent.
    private var rejected = false

    public init() {}

    /// True while steps wait for a verdict (tests).
    public var holding: Bool { !queue.isEmpty }

    /// One live step and the speaker verdict of the open utterance at that moment.
    public mutating func step(_ step: BargeInLive.Step, verdict: SpeakerHold.Verdict?) -> BargeInLive.Step {
        switch verdict {
        case nil:
            rejected = false
            return flush() + step
        case .accepted?:
            rejected = false
            return flush() + step
        case .rejected?:
            rejected = true
            return Self.unsent(flushDropped() + step)
        case .pending?:
            rejected = false
            if queue.isEmpty, step.actions.isEmpty, !step.adopt { return step }
            queue.append(step)
            return BargeInLive.Step()
        }
    }

    /// The verdicts `SpeakerHold` reached in a step, in order.
    public mutating func decided(_ verdicts: [SpeakerHold.Verdict]) -> BargeInLive.Step {
        var out = BargeInLive.Step()
        for v in verdicts {
            switch v {
            case .accepted: rejected = false; out = out + flush()
            case .rejected: rejected = true; out = out + Self.unsent(flushDropped())
            case .pending: break
            }
        }
        return out
    }

    private mutating func flush() -> BargeInLive.Step {
        defer { queue = [] }
        return queue.reduce(BargeInLive.Step(), +)
    }

    private mutating func flushDropped() -> BargeInLive.Step {
        let all = flush()
        var kept = BargeInLive.Step()
        kept.outputs = all.outputs
        kept.actions = all.actions.filter { $0 == .dip(false) }
        return kept
    }

    /// Nothing of it goes up: no actions, no adopt, a sent start becomes not sent, audio and stream end are dropped.
    static func unsent(_ step: BargeInLive.Step) -> BargeInLive.Step {
        var out = BargeInLive.Step()
        // Restoring her volume is never held back: only a dip, a stop and an adopt need an accepted voice.
        out.actions = step.actions.filter { $0 == .dip(false) }
        for output in step.outputs {
            switch output {
            case .speechStarted: out.outputs.append(.speechStarted(sentToModel: false))
            case .audio, .streamEnd: break
            case .speechStopped: out.outputs.append(output)
            case .utterance(var record):
                record.sentToModel = false
                record.muteReason = .speaker
                out.outputs.append(.utterance(record))
            }
        }
        return out
    }
}

extension BargeInLive.Step {
    /// Both steps in order (actions, outputs; adopt if either adopts).
    public static func + (a: Self, b: Self) -> Self {
        var s = a
        s.actions += b.actions
        s.outputs += b.outputs
        s.adopt = a.adopt || b.adopt
        return s
    }
}

/// The last `capacity` frames heard (the wake listener keeps 2 s, §6 item 7). Pure ring.
public struct RecentFrames: Sendable {
    public let capacity: Int
    private var ring: [PCMFrame16k] = []
    private var head = 0

    public init(duration: NovaDuration = .seconds(2)) { capacity = max(1, Int(duration.milliseconds / 10)) }

    public mutating func append(_ frame: PCMFrame16k) {
        if ring.count < capacity { ring.append(frame); return }
        ring[head] = frame
        head = (head + 1) % capacity
    }

    /// Oldest first.
    public var frames: [PCMFrame16k] { Array(ring[head...] + ring[..<head]) }
    public mutating func clear() { ring = []; head = 0 }
}

/// F-04b §6 items 7–8 (T-013e): 你好小诺 and the stop phrases act only on the enrolled voice when locked. A hit asks
/// for its recent audio to be scored; only an accepted result acts. Lock off: every hit acts at once, as today.
/// One check at a time: a result for another check or generation is dropped. Pure.
public struct SpeakerPhraseCheck: Sendable {
    public enum Decision: Sendable, Hashable {
        /// Act now (lock off).
        case act
        /// Score this; act only on `result` returning `act == true`.
        case verify(SpeakerScoreRequest)
        /// A check of this kind is already pending.
        case ignore
    }

    public let kind: SpeakerCheckKind
    public private(set) var threshold: Double?
    private var pending: (id: Int, frames: Int)?
    private var counter = 0
    public private(set) var generation = 0
    private let minScore: NovaDuration

    public init(kind: SpeakerCheckKind, minScoreSpeech: NovaDuration = SpeakerTuning().minScoreSpeech) {
        self.kind = kind
        minScore = minScoreSpeech
    }

    public var locked: Bool { threshold != nil }

    /// A lock change drops any pending check.
    public mutating func setLock(threshold: Double?) {
        if self.threshold != threshold { generation += 1; pending = nil }
        self.threshold = threshold
    }

    public mutating func hit(recent: [PCMFrame16k]) -> Decision {
        guard locked else { return .act }
        guard pending == nil else { return .ignore }
        counter += 1
        pending = (counter, recent.count)
        return .verify(SpeakerScoreRequest(utterance: counter, generation: generation, kind: kind, frames: recent))
    }

    /// Whether to act, and the record line; nil for a stale result.
    public mutating func result(_ outcome: SpeakerScoreOutcome, check id: Int, generation g: Int, waitMs: Int)
        -> (act: Bool, line: SpeakerCheckLine)? {
        guard g == generation, let p = pending, p.id == id, let threshold else { return nil }
        pending = nil
        let speech = NovaDuration.milliseconds(Int64(p.frames) * 10)
        let score: Double?, ms: Int
        switch outcome {
        case .score(let s, let m): score = speech >= minScore ? s : nil; ms = m
        case .failed(let m): score = nil; ms = m
        }
        let result: SpeakerCheckResult = score.map { $0 >= threshold ? .accepted : .rejected } ?? .unknown
        let line = SpeakerCheckLine(utterance: id, kind: kind, score: score, threshold: threshold, result: result,
                                    speechMs: p.frames * 10, scoreMs: ms, waitMs: waitMs)
        return (result == .accepted, line)
    }
}

/// F-04b §6 item 4 (T-013e): the phone's words for a held utterance wait for its verdict, so a rejected one gives no
/// driver line, no driver turn and no tool call; accepted releases them in order after the utterance's start. Words
/// of an utterance the lock never held pass at once. Pure.
public struct SpeakerWordsHold: Sendable {
    public struct Released: Sendable, Hashable {
        public let words: DriverWords
        public let utterance: Int
    }

    private var held: [Int: [DriverWords]] = [:]
    private var rejected: Set<Int> = []

    public init() {}

    /// True: deliver now. `heldUtterance`: the one `SpeakerHold` is holding.
    public mutating func words(_ words: DriverWords, utterance id: Int, heldUtterance: Int?) -> Bool {
        if rejected.contains(id) { return false }
        if held[id] != nil || heldUtterance == id {
            held[id, default: []].append(words)
            return false
        }
        return true
    }

    /// The verdicts of a `SpeakerHold.Step`; returns the words to deliver now, in order.
    public mutating func decided(_ verdicts: [SpeakerHold.Verdict], utterances: [Int]) -> [Released] {
        var out: [Released] = []
        for (verdict, id) in zip(verdicts, utterances) {
            let words = held.removeValue(forKey: id) ?? []
            switch verdict {
            case .accepted: out += words.map { Released(words: $0, utterance: id) }
            case .rejected: rejected.insert(id)
            case .pending: break
            }
        }
        // Only recent numbers matter; keep the set small.
        if let newest = (utterances + Array(rejected)).max() { rejected = rejected.filter { $0 > newest - 8 } }
        return out
    }

    /// Session start or stop.
    public mutating func reset() {
        held = [:]
        rejected = []
    }
}
