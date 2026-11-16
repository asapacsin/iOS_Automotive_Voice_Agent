import NovaKit
import NovaPorts

/// F-04b §6 item 9 (T-013e): with the lock on, a live interruption acts only on an accepted utterance. `BargeInLive`'s
/// steps for the open utterance are held while its verdict is pending; accepted releases them in order, rejected drops
/// the actions and turns what it would have sent into a not-sent utterance. Lock off (verdict nil): steps pass
/// unchanged. Pure.
///
/// §17 items 1, 3 (T-013k): a dip acts at once (only a stop and the adopted utterance wait). The early verdict
/// decides the stop: accepted releases the queued stop (the outputs and adopt still wait for the whole verdict);
/// rejected or unknown drops it, restores her volume, and every later live step of that utterance is dropped.
public struct SpeakerActionHold: Sendable {
    private var queue: [BargeInLive.Step] = []
    /// The open utterance was rejected: what the live interruption sends for it is not sent.
    private var rejected = false
    /// §17: the utterance whose early verdict is known, and that verdict.
    private var early: (utterance: Int, accepted: Bool)?
    private var logs: [String] = []

    public init() {}

    /// §17 item 7: `bargeInEarly <utterance> early=<accepted|rejected|unknown> stop=<released|dropped|none>`.
    public mutating func takeLogs() -> [String] {
        defer { logs.removeAll(keepingCapacity: true) }
        return logs
    }

    /// True while steps wait for a verdict (tests).
    public var holding: Bool { !queue.isEmpty }

    /// One live step and the speaker verdict of the open utterance at that moment. `utterance`: the open one's
    /// number (`SpeakerHold.heldUtterance`), for the early verdict.
    public mutating func step(_ step: BargeInLive.Step, verdict: SpeakerHold.Verdict?, utterance: Int? = nil)
        -> BargeInLive.Step {
        switch verdict {
        case nil, .accepted?:
            rejected = false
            early = nil
            return flush() + step
        case .rejected?:
            rejected = true
            early = nil
            return Self.unsent(flush() + step)
        case .pending?:
            rejected = false
            if let e = early, e.utterance != utterance { early = nil }
            if let e = early, !e.accepted {
                // §17 item 3: rejected early: nothing of the live interruption for this utterance acts.
                return Self.unsent(step)
            }
            let accepted = early?.accepted == true
            // §17 item 1: a dip never waits; after an accepted early check neither does a stop.
            var now = BargeInLive.Step()
            now.actions = step.actions.filter { accepted || Self.isDip($0) }
            var later = step
            later.actions = step.actions.filter { !(accepted || Self.isDip($0)) }
            if queue.isEmpty, later.actions.isEmpty, !later.adopt { now.outputs = step.outputs; return now }
            queue.append(later)
            return now
        }
    }

    /// §17 item 3: the early verdict for `utterance`.
    public mutating func early(_ result: SpeakerCheckResult?, utterance: Int?) -> BargeInLive.Step {
        guard let result, let utterance else { return BargeInLive.Step() }
        var out = BargeInLive.Step()
        let stops = queue.contains { $0.actions.contains(.stop) }
        logs.append("bargeInEarly \(utterance) early=\(result.rawValue) stop="
                    + (stops ? (result == .accepted ? "released" : "dropped") : "none"))
        if result == .accepted {
            early = (utterance, true)
            // The queued stop acts now; outputs and adopt wait for the whole verdict.
            out.actions = queue.flatMap(\.actions)
            queue = queue.map { var s = $0; s.actions = []; return s }
        } else {
            early = (utterance, false)
            // No stop; her volume comes back. Outputs of the dropped steps go up as not sent.
            var dropped = flush()
            dropped.adopt = false
            out = Self.unsent(dropped)
            if !out.actions.contains(.dip(false)) { out.actions.append(.dip(false)) }
        }
        return out
    }

    static func isDip(_ a: BargeInAction) -> Bool { if case .dip = a { true } else { false } }

    /// The verdicts `SpeakerHold` reached in a step, in order.
    public mutating func decided(_ verdicts: [SpeakerHold.Verdict]) -> BargeInLive.Step {
        var out = BargeInLive.Step()
        for v in verdicts {
            switch v {
            case .accepted: rejected = false; out = out + flush()
            case .rejected: rejected = true; out = out + Self.unsent(flush())
            case .pending: break
            }
        }
        return out
    }

    private mutating func flush() -> BargeInLive.Step {
        defer { queue = [] }
        return queue.reduce(BargeInLive.Step(), +)
    }

    /// Nothing of it goes up: no actions, no adopt, a sent start becomes not sent, audio and stream end are dropped.
    static func unsent(_ step: BargeInLive.Step) -> BargeInLive.Step {
        var out = BargeInLive.Step()
        // Restoring her volume is never held back: only a dip, a stop and an adopt need an accepted voice.
        out.actions = step.actions.filter { $0 == .dip(false) }
        // §17 item 1: the dip acted at once, so a dropped stop must give her volume back.
        if step.actions.contains(.stop), !out.actions.contains(.dip(false)) { out.actions.append(.dip(false)) }
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
        let score: Double?, ms: Int, raw: Double?, cohort: Int?
        switch outcome {
        // §16 item 5 (T-013j): the same AS-norm score and cohort threshold as speech.
        case .score(let s, let m, let r, let c):
            score = speech >= minScore ? s : nil; ms = m; raw = score == nil ? nil : r; cohort = c
        case .failed(let m): score = nil; ms = m; raw = nil; cohort = nil
        }
        let result: SpeakerCheckResult = score.map { $0 >= threshold ? .accepted : .rejected } ?? .unknown
        let line = SpeakerCheckLine(utterance: id, kind: kind, score: score, threshold: threshold, result: result,
                                    speechMs: p.frames * 10, scoreMs: ms, waitMs: waitMs, raw: raw, cohort: cohort)
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
