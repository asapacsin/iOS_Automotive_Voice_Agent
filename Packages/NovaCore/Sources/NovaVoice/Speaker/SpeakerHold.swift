import NovaKit
import NovaPorts

/// F-04b §6 tuning (T-013e). Starting values; they change only from the device measurements (rows 12–17).
/// §16 item 4 (T-013j): the whole utterance is scored once at its end, so `minVerifySpeech` and the 3 s held-buffer
/// limit are gone.
public struct SpeakerTuning: Sendable, Hashable {
    /// Less audio than this at the end cannot be scored: unknown.
    public var minScoreSpeech: NovaDuration
    /// F-04b §17 item 2 (T-013k): a live candidate's early check scores its first this-much of speech.
    public var earlyScoreSpeech: NovaDuration
    /// The gate's pre-roll (`UplinkGateTuning.preRoll`): at most this many frames of an utterance's opening burst are
    /// pre-roll, not counted as speech for the early check (§17 item 2).
    public var preRoll: NovaDuration

    public init(minScoreSpeech: NovaDuration = .milliseconds(500), earlyScoreSpeech: NovaDuration = .seconds(1),
                preRoll: NovaDuration = UplinkGateTuning().preRoll) {
        self.minScoreSpeech = minScoreSpeech
        self.earlyScoreSpeech = earlyScoreSpeech
        self.preRoll = preRoll
    }
}

/// `early` (§17 item 2): the first second of a live candidate, deciding only whether she stops.
public enum SpeakerCheckKind: String, Sendable, Hashable { case speech, wake, stop, early }
public enum SpeakerCheckResult: String, Sendable, Hashable { case accepted, rejected, unknown }

/// F-04b §7: one check, numbers only (no words, no audio; I-8).
public struct SpeakerCheckLine: Sendable, Hashable {
    public var utterance: Int
    public var kind: SpeakerCheckKind
    /// nil when there was nothing to score or scoring failed: no made-up confidence (§6 item 4).
    /// §16 item 2: the AS-norm score (also written as `norm=`).
    public var score: Double?
    /// §16 item 8: the raw cosine s and the cohort size behind `score`.
    public var raw: Double?
    public var cohort: Int?
    public var threshold: Double
    public var result: SpeakerCheckResult
    public var speechMs: Int
    public var scoreMs: Int
    public var waitMs: Int

    public init(utterance: Int, kind: SpeakerCheckKind, score: Double?, threshold: Double, result: SpeakerCheckResult,
                speechMs: Int, scoreMs: Int, waitMs: Int, raw: Double? = nil, cohort: Int? = nil) {
        self.utterance = utterance
        self.kind = kind
        self.score = score
        self.raw = raw
        self.cohort = cohort
        self.threshold = threshold
        self.result = result
        self.speechMs = speechMs
        self.scoreMs = scoreMs
        self.waitMs = waitMs
    }

    /// A non-finite threshold (the fail-closed lock with no cohort, §16 item 7) is written `none`.
    static func number(_ v: Double) -> String { v.isFinite ? String((v * 1000).rounded() / 1000) : "none" }

    /// `utterance=3 kind=speech score=2.1 raw=0.712 norm=2.1 cohort=797 threshold=1.5 result=accepted speechMs=2400
    /// scoreMs=40 waitMs=60`. Numbers only (I-8).
    public var fields: String {
        let norm = score.map(Self.number) ?? "none"
        return "utterance=\(utterance) kind=\(kind.rawValue) score=\(norm) raw=\(raw.map(Self.number) ?? "none") "
            + "norm=\(norm) cohort=\(cohort.map(String.init) ?? "none") "
            + "threshold=\(Self.number(threshold)) result=\(result.rawValue) speechMs=\(speechMs) scoreMs=\(scoreMs) "
            + "waitMs=\(waitMs)"
    }

    public var logLine: String { "speaker-check \(fields)" }
}

/// What to score, off the audio thread. The result names the same `utterance` and `generation`.
public struct SpeakerScoreRequest: Sendable, Hashable {
    public let utterance: Int
    public let generation: Int
    public let kind: SpeakerCheckKind
    public let frames: [PCMFrame16k]

    public init(utterance: Int, generation: Int, kind: SpeakerCheckKind, frames: [PCMFrame16k]) {
        self.utterance = utterance
        self.generation = generation
        self.kind = kind
        self.frames = frames
    }
}

/// The background queue's answer to a request.
public enum SpeakerScoreOutcome: Sendable, Hashable {
    /// §16 items 2, 8: the AS-norm score, the raw cosine and the cohort size (nil outside the cohort scorer).
    case score(Double, scoreMs: Int, raw: Double? = nil, cohort: Int? = nil)
    case failed(scoreMs: Int)
}

/// F-04b §6 items 2–5, 10, 12 (T-013e): with the lock on, nothing of an utterance goes to Gemini until its voice is
/// accepted. Sits between the uplink gate and `PostStopHold`: the gate's outputs come in, what may go up comes out.
/// Each sent utterance is held from its `speechStarted` (pre-roll included); at its end mark one score request is made
/// with all of its speech (§16 item 4, T-013j). Accepted: the held outputs go out in order and the rest passes.
/// Rejected or unknown (under `minScoreSpeech`, or a failure): it becomes a not-sent utterance with
/// `muteReason=speaker` (start and stop marks only). Off: outputs pass unchanged and no request is ever made.
/// Utterances are numbered like the recognizer's (one per `speechStarted`). Pure and synchronous; time moves 10 ms
/// per frame.
///
/// §17 (T-013k): a not-sent live candidate (`earlyCandidate`) also gets one `early` request on its first
/// `earlyScoreSpeech` of speech, scored against `earlyThreshold`; that verdict (`Step.early`) decides only whether
/// she stops. An utterance whose whole score was requested is kept (`awaiting`) when the next one starts, until its
/// result comes.
public struct SpeakerHold: Sendable {
    /// The decision about one utterance, for whoever waits on it (`SpeakerActionHold`).
    public enum Verdict: Sendable, Hashable { case pending, accepted, rejected }

    public struct Step: Sendable, Hashable {
        public var outputs: [UplinkGateOutput] = []
        /// The whole-utterance request (§16 item 4).
        public var request: SpeakerScoreRequest?
        /// §17 item 2: the early request.
        public var earlyRequest: SpeakerScoreRequest?
        /// §17 item 3: the early verdict reached in this step (accepted, rejected, or unknown).
        public var early: SpeakerCheckResult?
        public var earlyUtterance: Int?
        /// Requests asked again after a threshold change (their earlier results are stale).
        public var rescore: [SpeakerScoreRequest] = []
        /// Utterances decided in this step, in order, and their numbers.
        public var decided: [Verdict] = []
        public var decidedUtterances: [Int] = []
        public init() {}
    }

    /// §17: where the early check of the open utterance stands.
    public enum Early: String, Sendable, Hashable { case none, pending, accepted, rejected, unknown }

    /// One utterance being held or scored.
    private struct Held: Sendable {
        var id: Int
        /// The gate sends it (held); else it is only scored for an interruption (passes as it is).
        var sent: Bool
        var since: NovaDuration
        var buffer: [UplinkGateOutput] = []
        /// Audio kept for the whole request (emptied once it is made); `speech`: audio frames seen.
        var frames: [PCMFrame16k] = []
        var speech = 0
        var requested = false
        /// What the whole request scored, kept so a threshold change can ask again (§6 item 5 with §17 item 4).
        var scored: [PCMFrame16k] = []
        var closed = false
        /// §17 item 2: pre-roll frames at its start, then its first speech frames for the early request.
        var skip = 0
        var earlyFrames: [PCMFrame16k] = []
        var early = Early.none
    }

    private enum State: Sendable {
        case idle
        case holding(Held)
        case passing(id: Int)
        /// Rejected: a sent one is swallowed to its end; a not-sent one passes as it is (`sent` false).
        /// `closed`: its record went out; only the closing silence and stream end remain (swallowed).
        case dropping(id: Int, sent: Bool, closed: Bool)
    }

    private let tuning: SpeakerTuning
    private var state = State.idle
    /// §17 item 4: closed utterances whose whole score was requested, kept past the next start until it comes.
    private var awaiting: [Held] = []
    private var now = NovaDuration.zero
    private var utterance = 0
    private var checks: [SpeakerCheckLine] = []
    /// Pre-roll frames of a start seen in this frame's burst (§17 item 2).
    private var burstSkip = 0
    /// Scoring failed on the last try while locked (§6 item 11: the chip).
    public private(set) var unavailable = false
    public private(set) var threshold: Double?
    /// §17 items 3, 6: the cohort's `threshold1s`; nil makes every early check unknown.
    public private(set) var earlyThreshold: Double?
    public private(set) var generation = 0
    /// Also score not-sent utterances (可以打断她 on), so an interruption can wait on a verdict (§6 item 9).
    public var scoreUnsent = false
    /// §17 item 2: `BargeInLive` is keeping the open not-sent utterance as a candidate (her reply playing).
    public var earlyCandidate = false

    public init(tuning: SpeakerTuning = SpeakerTuning()) { self.tuning = tuning }

    /// On only with a threshold: there is no built-in one (§5 item 1).
    public var locked: Bool { threshold != nil }

    /// The open utterance's verdict; nil when the lock is off or nothing is open.
    public var verdict: Verdict? {
        guard locked else { return nil }
        switch state {
        case .holding: return .pending
        case .passing: return .accepted
        case .dropping: return .rejected
        case .idle: return nil
        }
    }

    /// §17: the open utterance's early check; `.none` when there is none (yet).
    public var early: Early {
        if case .holding(let h) = state { return h.early }
        return .none
    }

    /// The number of the utterance being held or scored, if any: its words wait for the verdict too (no driver line,
    /// no driver turn before acceptance).
    /// Not-sent ones too: their words could still stop her as a transcript stop phrase (§6 item 8).
    public var heldUtterance: Int? {
        if case .holding(let h) = state { return h.id }
        return nil
    }

    /// §17 item 4: the open utterance or one still waiting for its score; its words wait for its verdict.
    public func isHeld(_ id: Int) -> Bool { heldUtterance == id || awaiting.contains { $0.id == id } }

    /// True while a sent utterance is held (tests, diagnostics).
    public var holding: Bool {
        if case .holding(let h) = state { return h.sent }
        return false
    }

    public mutating func takeChecks() -> [SpeakerCheckLine] {
        defer { checks.removeAll(keepingCapacity: true) }
        return checks
    }

    /// §6 item 10: off releases a held utterance in order and stops scoring; on applies from the next utterance
    /// (an open one keeps passing). A new threshold while locked keeps what is pending.
    public mutating func setLock(threshold: Double?, early: Double? = nil) -> Step {
        let wasLocked = locked
        let changed = self.threshold != threshold
        self.threshold = threshold
        earlyThreshold = threshold == nil ? nil : early
        var step = Step()
        // §6 item 5: a threshold change makes pending results stale. §17 item 4: what already waits for its score is
        // asked again under the new generation, so it is decided, not lost. Only the 1 s threshold changing keeps them.
        if wasLocked, locked, changed {
            generation += 1
            for k in awaiting.indices {
                step.rescore.append(SpeakerScoreRequest(utterance: awaiting[k].id, generation: generation, kind: .speech,
                                                        frames: awaiting[k].scored))
                if awaiting[k].early == .pending { awaiting[k].early = .unknown }
            }
            if case .holding(var h) = state {
                if h.requested {
                    step.rescore.append(SpeakerScoreRequest(utterance: h.id, generation: generation, kind: .speech,
                                                            frames: h.scored))
                }
                if h.early == .pending {
                    // Its early result is stale: unknown, so she is not stopped (§17 item 3).
                    h.early = .unknown
                    step.early = .unknown
                    step.earlyUtterance = h.id
                }
                state = .holding(h)
            }
        }
        guard wasLocked, !locked else { return step }
        unavailable = false
        generation += 1  // a pending result can no longer apply
        for held in awaiting {
            if held.sent { step.outputs += held.buffer }
            step.decided.append(.accepted)
            step.decidedUtterances.append(held.id)
        }
        awaiting = []
        switch state {
        case .holding(let h):
            if h.sent { step.outputs += h.buffer }
            state = h.closed ? .idle : .passing(id: h.id)
            step.decided.append(.accepted)
            step.decidedUtterances.append(h.id)
        case .dropping:
            break  // a rejected utterance stays rejected to its end
        case .idle, .passing:
            break
        }
        return step
    }

    /// §6 item 5: a session start or stop; nothing pending survives it.
    public mutating func reset() {
        generation += 1
        state = .idle
        awaiting = []
        utterance = 0
        now = .zero
        unavailable = false
    }

    /// One captured frame and what the gate made of it.
    public mutating func frame(_ outputs: [UplinkGateOutput]) -> Step {
        now = now + .milliseconds(10)
        // §17 item 2: the audio of a start's burst before this frame's own is its pre-roll (at most `preRoll`).
        if let start = outputs.lastIndex(where: { if case .speechStarted = $0 { true } else { false } }) {
            let burst = outputs[(start + 1)...].filter { if case .audio = $0 { true } else { false } }.count
            burstSkip = min(Int(tuning.preRoll.milliseconds / 10), max(0, burst - 1))
        } else {
            burstSkip = 0
        }
        return pass(outputs)
    }

    /// Outputs that come from no frame (the force-close).
    public mutating func pass(_ outputs: [UplinkGateOutput]) -> Step {
        var step = Step()
        for output in outputs { pass(output, into: &step) }
        burstSkip = 0
        return step
    }

    private mutating func pass(_ output: UplinkGateOutput, into step: inout Step) {
        if case .speechStarted(let sent) = output {
            utterance += 1
            if case .holding(let h) = state {
                if h.requested {
                    // §17 item 4: its score was asked for: keep it until the result comes.
                    awaiting.append(h)
                    state = .idle
                } else {
                    // A new utterance while the last one waits with nothing asked: the late one is unknown.
                    drop(score: nil, scoreMs: 0, into: &step)
                }
            }
            if case .dropping(_, true, false) = state {
                // The swallowed one never closed (should not happen): close it for the core.
                step.outputs.append(.speechStopped(.flagged))
            }
            guard locked, sent || scoreUnsent else {
                state = .idle
                step.outputs.append(output)
                return
            }
            state = .holding(Held(id: utterance, sent: sent, since: now, buffer: sent ? [output] : [], skip: burstSkip))
            if !sent { step.outputs.append(output) }
            return
        }
        switch state {
        case .idle, .passing, .dropping(_, false, _):
            if case .utterance = output { state = .idle }
            step.outputs.append(output)
        case .dropping(let id, true, let closed):
            switch output {
            case .audio, .speechStarted: break
            case .streamEnd: state = .idle
            case .speechStopped: if !closed { step.outputs.append(output) }
            case .utterance(var record):
                record.sentToModel = false
                record.muteReason = .speaker
                state = .dropping(id: id, sent: true, closed: true)
                step.outputs.append(.utterance(record))
            }
        case .holding(var h):
            if h.sent { h.buffer.append(output) } else { step.outputs.append(output) }
            // speechMs counts the utterance's own audio, not the closing silence after it.
            if case .audio(let frame) = output, !h.closed {
                h.speech += 1
                if !h.requested { h.frames.append(frame) }
                if h.speech > h.skip, h.early == .none, h.earlyFrames.count < earlyFrameCount { h.earlyFrames.append(frame) }
            }
            if case .utterance = output { h.closed = true }
            // §17 item 2: a live candidate's first second, once, before it ends.
            if h.early == .none, !h.closed, !h.sent, earlyCandidate, h.earlyFrames.count >= earlyFrameCount {
                if earlyThreshold == nil {
                    // §17 item 6: no 1 s threshold: unknown, she is never stopped early.
                    h.early = .unknown
                    step.early = .unknown
                    step.earlyUtterance = h.id
                    checks.append(earlyLine(h, score: nil, raw: nil, cohort: nil, result: .unknown, scoreMs: 0))
                } else {
                    h.early = .pending
                    step.earlyRequest = SpeakerScoreRequest(utterance: h.id, generation: generation, kind: .early,
                                                            frames: h.earlyFrames)
                }
                h.earlyFrames = []
            }
            let audio = NovaDuration.milliseconds(Int64(h.speech) * 10)
            // §16 item 4: once, at the end, on all of its speech.
            if !h.requested, h.closed, audio >= tuning.minScoreSpeech {
                h.requested = true
                step.request = SpeakerScoreRequest(utterance: h.id, generation: generation, kind: .speech, frames: h.frames)
                h.scored = h.frames
                h.frames = []
            }
            state = .holding(h)
            // Closed with too little audio to score: unknown.
            if h.closed, !h.requested { drop(score: nil, scoreMs: 0, into: &step) }
        }
    }

    private var earlyFrameCount: Int { max(1, Int(tuning.earlyScoreSpeech.milliseconds / 10)) }

    private func earlyLine(_ h: Held, score: Double?, raw: Double?, cohort: Int?, result: SpeakerCheckResult,
                           scoreMs: Int) -> SpeakerCheckLine {
        SpeakerCheckLine(utterance: h.id, kind: .early, score: score, threshold: earlyThreshold ?? .nan, result: result,
                         speechMs: earlyFrameCount * 10, scoreMs: scoreMs, waitMs: Int((now - h.since).milliseconds),
                         raw: raw, cohort: cohort)
    }

    /// The background queue's answer. A result for another utterance, kind or generation is dropped (§6 item 5).
    public mutating func result(_ outcome: SpeakerScoreOutcome, utterance id: Int, generation g: Int,
                                kind: SpeakerCheckKind = .speech) -> Step {
        var step = Step()
        guard g == generation, let threshold else { return step }
        if kind == .early { return earlyResult(outcome, utterance: id) }
        guard kind == .speech else { return step }
        if let k = awaiting.firstIndex(where: { $0.id == id }) {
            // §17 item 4: a kept utterance's verdict applies to it alone.
            let h = awaiting.remove(at: k)
            switch outcome {
            case .score(let score, let ms, let raw, let cohort) where score >= threshold:
                unavailable = false
                checks.append(line(h, score: score, raw: raw, cohort: cohort, result: .accepted, scoreMs: ms))
                if h.sent { step.outputs = h.buffer }
                step.decided.append(.accepted)
                step.decidedUtterances.append(h.id)
            case .score(let score, let ms, let raw, let cohort):
                unavailable = false
                step.outputs = reject(h, score: score, scoreMs: ms, raw: raw, cohort: cohort, into: &step)
            case .failed(let ms):
                unavailable = true
                step.outputs = reject(h, score: nil, scoreMs: ms, raw: nil, cohort: nil, into: &step)
            }
            return step
        }
        guard case .holding(let h) = state, h.requested, h.id == id else { return step }
        // Keep the order of what goes up: an older kept one cannot be released after this one.
        for old in awaiting {
            step.outputs += reject(old, score: nil, scoreMs: 0, raw: nil, cohort: nil, into: &step)
        }
        awaiting = []
        switch outcome {
        case .failed(let ms):
            unavailable = true
            drop(score: nil, scoreMs: ms, into: &step)
        case .score(let score, let ms, let raw, let cohort) where score >= threshold:
            unavailable = false
            checks.append(line(h, score: score, raw: raw, cohort: cohort, result: .accepted, scoreMs: ms))
            if h.sent { step.outputs += h.buffer }
            state = h.closed ? .idle : .passing(id: h.id)
            step.decided.append(.accepted)
            step.decidedUtterances.append(h.id)
        case .score(let score, let ms, let raw, let cohort):
            unavailable = false
            drop(score: score, scoreMs: ms, raw: raw, cohort: cohort, into: &step)
        }
        return step
    }

    /// §17 item 3: accepted lets the stop act; rejected or unknown (a failure) drops it. The words still wait.
    private mutating func earlyResult(_ outcome: SpeakerScoreOutcome, utterance id: Int) -> Step {
        var step = Step()
        var h: Held
        let kept = awaiting.firstIndex { $0.id == id }
        if let kept { h = awaiting[kept] } else if case .holding(let open) = state, open.id == id { h = open } else {
            return step
        }
        guard h.early == .pending else { return step }
        let result: SpeakerCheckResult
        switch outcome {
        case .score(let score, let ms, let raw, let cohort):
            result = earlyThreshold.map { score >= $0 ? .accepted : .rejected } ?? .unknown
            checks.append(earlyLine(h, score: score, raw: raw, cohort: cohort, result: result, scoreMs: ms))
        case .failed(let ms):
            result = .unknown
            checks.append(earlyLine(h, score: nil, raw: nil, cohort: nil, result: .unknown, scoreMs: ms))
        }
        h.early = switch result { case .accepted: .accepted; case .rejected: .rejected; case .unknown: .unknown }
        if let kept { awaiting[kept] = h } else { state = .holding(h) }
        step.early = result
        step.earlyUtterance = id
        return step
    }

    private func line(_ h: Held, score: Double?, raw: Double?, cohort: Int?, result: SpeakerCheckResult,
                      scoreMs: Int) -> SpeakerCheckLine {
        SpeakerCheckLine(utterance: h.id, kind: .speech, score: score, threshold: threshold ?? 0, result: result,
                         speechMs: h.speech * 10, scoreMs: scoreMs, waitMs: Int((now - h.since).milliseconds), raw: raw,
                         cohort: cohort)
    }

    /// A rejected or unknown utterance: its record line and verdict, and what of it goes up (marks only, not sent).
    private mutating func reject(_ h: Held, score: Double?, scoreMs: Int, raw: Double?, cohort: Int?,
                                 into step: inout Step) -> [UplinkGateOutput] {
        checks.append(line(h, score: score, raw: raw, cohort: cohort, result: score == nil ? .unknown : .rejected,
                           scoreMs: scoreMs))
        step.decided.append(.rejected)
        step.decidedUtterances.append(h.id)
        guard h.sent else { return [] }
        var out: [UplinkGateOutput] = [.speechStarted(sentToModel: false)]
        for output in h.buffer {
            switch output {
            case .speechStopped: out.append(output)
            case .utterance(var record):
                record.sentToModel = false
                record.muteReason = .speaker
                out.append(.utterance(record))
            default: break
            }
        }
        return out
    }

    /// Rejected (a score under the threshold) or unknown (no score): nothing of it goes up; the core hears a not-sent
    /// utterance (start and stop marks only, `muteReason=speaker`).
    private mutating func drop(score: Double?, scoreMs: Int, raw: Double? = nil, cohort: Int? = nil,
                               into step: inout Step) {
        guard case .holding(let h) = state else { return }
        step.outputs += reject(h, score: score, scoreMs: scoreMs, raw: raw, cohort: cohort, into: &step)
        // A sent one swallows its closing silence and stream end too: nothing of it goes up.
        let ended = h.buffer.contains(.streamEnd)
        state = ended ? .idle
            : h.sent ? .dropping(id: h.id, sent: true, closed: h.closed)
            : (h.closed ? .idle : .dropping(id: h.id, sent: false, closed: false))
    }
}
