import NovaKit
import NovaPorts

/// F-04b §6 tuning (T-013e). Starting values; they change only from the device measurements (rows 12–17).
public struct SpeakerTuning: Sendable, Hashable {
    /// Scoring runs once when the utterance has this much audio, or at its end if sooner.
    public var minVerifySpeech: NovaDuration
    /// Less audio than this at the end cannot be scored: unknown.
    public var minScoreSpeech: NovaDuration
    /// A held utterance with no result after this is unknown.
    public var holdCap: NovaDuration

    public init(minVerifySpeech: NovaDuration = .seconds(1), minScoreSpeech: NovaDuration = .milliseconds(500),
                holdCap: NovaDuration = .seconds(3)) {
        self.minVerifySpeech = minVerifySpeech
        self.minScoreSpeech = minScoreSpeech
        self.holdCap = holdCap
    }
}

public enum SpeakerCheckKind: String, Sendable, Hashable { case speech, wake, stop }
public enum SpeakerCheckResult: String, Sendable, Hashable { case accepted, rejected, unknown }

/// F-04b §7: one check, numbers only (no words, no audio; I-8).
public struct SpeakerCheckLine: Sendable, Hashable {
    public var utterance: Int
    public var kind: SpeakerCheckKind
    /// nil when there was nothing to score or scoring failed: no made-up confidence (§6 item 4).
    public var score: Double?
    public var threshold: Double
    public var result: SpeakerCheckResult
    public var speechMs: Int
    public var scoreMs: Int
    public var waitMs: Int

    public init(utterance: Int, kind: SpeakerCheckKind, score: Double?, threshold: Double, result: SpeakerCheckResult,
                speechMs: Int, scoreMs: Int, waitMs: Int) {
        self.utterance = utterance
        self.kind = kind
        self.score = score
        self.threshold = threshold
        self.result = result
        self.speechMs = speechMs
        self.scoreMs = scoreMs
        self.waitMs = waitMs
    }

    static func number(_ v: Double) -> String { String((v * 1000).rounded() / 1000) }

    /// `utterance=3 kind=speech score=0.712 threshold=0.55 result=accepted speechMs=1000 scoreMs=40 waitMs=1040`
    public var fields: String {
        "utterance=\(utterance) kind=\(kind.rawValue) score=\(score.map(Self.number) ?? "none") "
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
}

/// The background queue's answer to a request.
public enum SpeakerScoreOutcome: Sendable, Hashable {
    case score(Double, scoreMs: Int)
    case failed(scoreMs: Int)
}

/// F-04b §6 items 2–5, 10, 12 (T-013e): with the lock on, nothing of an utterance goes to Gemini until its voice is
/// accepted. Sits between the uplink gate and `PostStopHold`: the gate's outputs come in, what may go up comes out.
/// Each sent utterance is held from its `speechStarted` (pre-roll included); at `minVerifySpeech` of audio (or its end
/// if sooner) one score request is made. Accepted: the held outputs go out in order and the rest passes. Rejected or
/// unknown (too short, failure, past `holdCap`): it becomes a not-sent utterance with `muteReason=speaker` (start and
/// stop marks only). Off: outputs pass unchanged and no request is ever made. Utterances are numbered like the
/// recognizer's (one per `speechStarted`). Pure and synchronous; time moves 10 ms per frame.
public struct SpeakerHold: Sendable {
    /// The decision about one utterance, for whoever waits on it (`SpeakerActionHold`).
    public enum Verdict: Sendable, Hashable { case pending, accepted, rejected }

    public struct Step: Sendable, Hashable {
        public var outputs: [UplinkGateOutput] = []
        public var request: SpeakerScoreRequest?
        /// Utterances decided in this step, in order, and their numbers.
        public var decided: [Verdict] = []
        public var decidedUtterances: [Int] = []
        public init() {}
    }

    private enum State: Sendable {
        case idle
        /// `sent`: the gate sends it (held); else it is only scored for an interruption (passes as it is).
        /// `frames`: audio kept for the request (emptied once it is made); `speech`: audio frames seen.
        case holding(id: Int, sent: Bool, since: NovaDuration, buffer: [UplinkGateOutput], frames: [PCMFrame16k],
                     speech: Int, requested: Bool, closed: Bool)
        case passing(id: Int)
        /// Rejected: a sent one is swallowed to its end; a not-sent one passes as it is (`sent` false).
        case dropping(id: Int, sent: Bool)
    }

    private let tuning: SpeakerTuning
    private var state = State.idle
    private var now = NovaDuration.zero
    private var utterance = 0
    private var checks: [SpeakerCheckLine] = []
    /// Scoring failed on the last try while locked (§6 item 11: the chip).
    public private(set) var unavailable = false
    public private(set) var threshold: Double?
    public private(set) var generation = 0
    /// Also score not-sent utterances (可以打断她 on), so an interruption can wait on a verdict (§6 item 9).
    public var scoreUnsent = false

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

    /// The number of the sent utterance being held, if any: its words wait for the verdict too (no driver line,
    /// no driver turn before acceptance).
    public var heldUtterance: Int? {
        if case .holding(let id, true, _, _, _, _, _, _) = state { return id }
        return nil
    }

    /// True while a sent utterance is held (tests, diagnostics).
    public var holding: Bool {
        if case .holding(_, true, _, _, _, _, _, _) = state { return true }
        return false
    }

    public mutating func takeChecks() -> [SpeakerCheckLine] {
        defer { checks.removeAll(keepingCapacity: true) }
        return checks
    }

    /// §6 item 10: off releases a held utterance in order and stops scoring; on applies from the next utterance
    /// (an open one keeps passing). A new threshold while locked keeps what is pending.
    public mutating func setLock(threshold: Double?) -> Step {
        let wasLocked = locked
        self.threshold = threshold
        var step = Step()
        guard wasLocked, !locked else { return step }
        unavailable = false
        generation += 1  // a pending result can no longer apply
        switch state {
        case .holding(let id, let sent, _, let buffer, _, _, _, let closed):
            if sent { step.outputs = buffer }
            state = closed ? .idle : .passing(id: id)
            step.decided = [.accepted]
            step.decidedUtterances = [id]
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
        utterance = 0
        now = .zero
        unavailable = false
    }

    /// One captured frame and what the gate made of it.
    public mutating func frame(_ outputs: [UplinkGateOutput]) -> Step {
        now = now + .milliseconds(10)
        var step = pass(outputs)
        if case .holding(_, _, let since, _, _, _, _, _) = state, now - since > tuning.holdCap {
            drop(score: nil, scoreMs: 0, into: &step)
        }
        return step
    }

    /// Outputs that come from no frame (the force-close).
    public mutating func pass(_ outputs: [UplinkGateOutput]) -> Step {
        var step = Step()
        for output in outputs { pass(output, into: &step) }
        return step
    }

    private mutating func pass(_ output: UplinkGateOutput, into step: inout Step) {
        if case .speechStarted(let sent) = output {
            utterance += 1
            // A new utterance while the last one waits: the late one is unknown.
            if case .holding = state { drop(score: nil, scoreMs: 0, into: &step) }
            if case .dropping(_, true) = state {
                // The swallowed one never closed (should not happen): close it for the core.
                step.outputs.append(.speechStopped(.flagged))
            }
            guard locked, sent || scoreUnsent else {
                state = .idle
                step.outputs.append(output)
                return
            }
            state = .holding(id: utterance, sent: sent, since: now, buffer: sent ? [output] : [], frames: [], speech: 0,
                             requested: false, closed: false)
            if !sent { step.outputs.append(output) }
            return
        }
        switch state {
        case .idle, .passing, .dropping(_, false):
            if case .utterance = output { state = .idle }
            step.outputs.append(output)
        case .dropping(_, true):
            switch output {
            case .audio, .streamEnd, .speechStarted: break
            case .speechStopped: step.outputs.append(output)
            case .utterance(var record):
                record.sentToModel = false
                record.muteReason = .speaker
                state = .idle
                step.outputs.append(.utterance(record))
            }
        case .holding(let id, let sent, let since, var buffer, var frames, var speech, var requested, var closed):
            if sent { buffer.append(output) } else { step.outputs.append(output) }
            if case .audio(let frame) = output {
                speech += 1
                if !requested { frames.append(frame) }
            }
            if case .utterance = output { closed = true }
            let audio = NovaDuration.milliseconds(Int64(speech) * 10)
            var request: SpeakerScoreRequest?
            if !requested, audio >= tuning.minVerifySpeech || (closed && audio >= tuning.minScoreSpeech) {
                requested = true
                request = SpeakerScoreRequest(utterance: id, generation: generation, kind: .speech, frames: frames)
                frames = []
            }
            state = .holding(id: id, sent: sent, since: since, buffer: buffer, frames: frames, speech: speech,
                             requested: requested, closed: closed)
            if let request { step.request = request }
            // Closed with too little audio to score: unknown.
            if closed, !requested { drop(score: nil, scoreMs: 0, into: &step) }
        }
    }

    /// The background queue's answer. A result for another utterance or generation is dropped (§6 item 5).
    public mutating func result(_ outcome: SpeakerScoreOutcome, utterance id: Int, generation g: Int) -> Step {
        var step = Step()
        guard g == generation, let threshold,
              case .holding(let held, let sent, let since, let buffer, _, let speech, true, let closed) = state,
              held == id else { return step }
        switch outcome {
        case .failed(let ms):
            unavailable = true
            drop(score: nil, scoreMs: ms, into: &step)
        case .score(let score, let ms) where score >= threshold:
            unavailable = false
            checks.append(SpeakerCheckLine(utterance: id, kind: .speech, score: score, threshold: threshold,
                                           result: .accepted, speechMs: speech * 10, scoreMs: ms,
                                           waitMs: Int((now - since).milliseconds)))
            if sent { step.outputs = buffer }
            state = closed ? .idle : .passing(id: id)
            step.decided.append(.accepted)
            step.decidedUtterances.append(id)
        case .score(let score, let ms):
            unavailable = false
            drop(score: score, scoreMs: ms, into: &step)
        }
        return step
    }

    /// Rejected (a score under the threshold) or unknown (no score): nothing of it goes up; the core hears a not-sent
    /// utterance (start and stop marks only, `muteReason=speaker`).
    private mutating func drop(score: Double?, scoreMs: Int, into step: inout Step) {
        guard case .holding(let id, let sent, let since, let buffer, _, let speech, _, let closed) = state else { return }
        checks.append(SpeakerCheckLine(utterance: id, kind: .speech, score: score, threshold: threshold ?? 0,
                                       result: score == nil ? .unknown : .rejected, speechMs: speech * 10,
                                       scoreMs: scoreMs, waitMs: Int((now - since).milliseconds)))
        step.decided.append(.rejected)
        step.decidedUtterances.append(id)
        if sent {
            step.outputs.append(.speechStarted(sentToModel: false))
            for output in buffer {
                switch output {
                case .speechStopped: step.outputs.append(output)
                case .utterance(var record):
                    record.sentToModel = false
                    record.muteReason = .speaker
                    step.outputs.append(.utterance(record))
                default: break
                }
            }
        }
        state = closed ? .idle : .dropping(id: id, sent: sent)
    }
}
