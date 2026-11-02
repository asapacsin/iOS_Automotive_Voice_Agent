import NovaKit
import NovaPorts

/// F-08 §17 item 11 (T-022e): what the shell does for a live interruption.
public enum BargeInAction: Sendable, Hashable {
    /// Lower (true) or restore (false) her reply by `dipDb`; the reply keeps playing and Gemini is not told.
    case dip(Bool)
    /// New words confirmed: flush her reply and end it for Gemini (the core's `.bargeInStop`). Sent before the
    /// released utterance's `speechStarted`, so the flush comes first.
    case stop
}

/// F-08 §17 items 10–11: with 「可以打断她（实验）」 on, a candidate's audio (pre-roll first) is kept while
/// `BargeInShadow` judges it. The gate's marks pass unchanged (the core and stop phrases see what they see today);
/// only the audio, which the uplink drops for a not-sent utterance anyway, is kept. `wouldStop` releases it as a
/// sent utterance: `speechStarted(sentToModel: true)`, the kept audio in order, then live audio (the shell makes the
/// gate send the rest of it). Any other outcome drops it and restores her volume. Off: nothing is kept or emitted.
///
/// Her reply ending before a decision (the gate's `cutAtUnmute`): the cut's sent utterance is held, like
/// `PostStopHold` does, until the candidate is judged. `wouldStop` sends the kept audio ahead of it (the cut's
/// pre-roll is the end of what was kept, so it is not sent twice); anything else sends the cut's utterance as today.
///
/// Events pair with the gate's raw outputs (`raw`); what goes out replaces the hold's outputs (`held`). Pure; time
/// moves 10 ms per frame. Logs are numbers and enums (I-8).
public struct BargeInLive: Sendable {
    public static let dipDb = 10.0
    public static let bufferCap = NovaDuration.seconds(8)

    private enum State: Sendable {
        case idle
        case keeping(id: Int, since: NovaDuration, audio: [PCMFrame16k], dipped: Bool, closed: Bool)
        /// The cut at unmute came before a decision: candidate `id`'s kept audio, and the held outputs of the cut's
        /// sent utterance (`skip`: its pre-roll frames right after its start).
        case carrying(id: Int, since: NovaDuration, kept: [PCMFrame16k], held: [UplinkGateOutput], skip: Int)
    }

    /// The candidate's close was the cut at unmute.
    private var cutAtUnmute = false
    /// Set by the raw cut start; the hold's matching `speechStarted(true)` begins the carried part.
    private var carryArmed = false
    /// The cut's pre-roll frames, counted on the raw outputs (a post-stop hold may release more frames at once).
    private var carrySkip = 0

    public var enabled = false
    private var state = State.idle
    private var now = NovaDuration.zero
    private var logs: [String] = []

    public init() {}

    public mutating func takeLogs() -> [String] {
        defer { logs.removeAll(keepingCapacity: true) }
        return logs
    }

    /// True while a candidate's audio is kept or a cut utterance is held for it (tests, diagnostics).
    public var keeping: Bool {
        if case .idle = state { return false }
        return true
    }

    /// The result of one step: what the shell does (in order), then the outputs to forward in place of `held`.
    public struct Step: Sendable, Hashable {
        public var actions: [BargeInAction] = []
        public var outputs: [UplinkGateOutput] = []
        /// The gate must send the rest of the open utterance (`SpeechUplinkGate.adoptOpenUtterance`).
        public var adopt = false
        public init() {}
    }

    /// One frame: the gate's raw outputs, the hold's outputs for them, and the shadow's events after it.
    public mutating func frame(raw: [UplinkGateOutput], held: [UplinkGateOutput], events: [BargeInShadow.Event],
                               guidancePlaying: Bool) -> Step {
        now = now + .milliseconds(10)
        return pass(raw: raw, held: held, events: events, guidancePlaying: guidancePlaying)
    }

    /// The same for one list (no hold in between; tests).
    public mutating func frame(_ outputs: [UplinkGateOutput], events: [BargeInShadow.Event], guidancePlaying: Bool) -> Step {
        frame(raw: outputs, held: outputs, events: events, guidancePlaying: guidancePlaying)
    }

    public mutating func pass(_ outputs: [UplinkGateOutput], events: [BargeInShadow.Event], guidancePlaying: Bool) -> Step {
        pass(raw: outputs, held: outputs, events: events, guidancePlaying: guidancePlaying)
    }

    /// Outputs that come from no frame (the force-close, the recognizer's words).
    public mutating func pass(raw: [UplinkGateOutput], held: [UplinkGateOutput], events: [BargeInShadow.Event],
                              guidancePlaying: Bool) -> Step {
        var step = Step()
        // 1. Raw outputs: each `started` at its own `speechStarted` (the pre-roll after it is kept).
        var starts = events.filter { if case .started = $0 { true } else { false } }[...]
        for (i, output) in raw.enumerated() {
            if case .speechStarted = output, let start = starts.popFirst() {
                if case .started(_, false) = start, cutAtUnmute,
                   case .keeping(let id, let since, let audio, true, true) = state {
                    // Her reply ended first and the early stages passed: hold the cut's utterance for the decision.
                    cutAtUnmute = false
                    carryArmed = true
                    let after = raw[(i + 1)...].prefix { if case .audio = $0 { true } else { false } }.count
                    carrySkip = max(0, after - 1)
                    state = .carrying(id: id, since: since, kept: audio, held: [], skip: 0)
                } else {
                    handle([start], guidancePlaying: guidancePlaying, into: &step)
                }
                continue
            }
            keep(output)
        }
        // 2. The hold's outputs, in place: passed, or held while carrying.
        var out: [UplinkGateOutput] = []
        for (i, output) in held.enumerated() {
            if carryArmed, case .speechStarted(true) = output, case .carrying(let id, let since, let kept, _, _) = state {
                carryArmed = false
                _ = i
                state = .carrying(id: id, since: since, kept: kept, held: [output], skip: carrySkip)
                continue
            }
            if case .carrying(let id, let since, let kept, var buffer, let skip) = state, buffer.first != nil {
                if case .speechStarted = output {
                    // A newer utterance: the cut's goes out as today, then this one.
                    out += buffer
                    state = .idle
                    if kept.count > 0 { step.actions.append(.dip(false)) }
                    logs.append("bargeInDipCancelled \(id) reason=superseded")
                    out.append(output)
                    continue
                }
                buffer.append(output)
                state = .carrying(id: id, since: since, kept: kept, held: buffer, skip: skip)
                continue
            }
            out.append(output)
        }
        // 3. Decisions.
        handle(Array(starts) + events.filter { if case .started = $0 { false } else { true } },
               guidancePlaying: guidancePlaying, into: &step, out: &out)
        switch state {
        case .keeping(let id, let since, _, _, _) where now - since > Self.bufferCap:
            cancel(id, reason: "cap", into: &step)
        case .carrying(let id, let since, _, let buffer, _) where now - since > Self.bufferCap:
            out += buffer
            state = .idle
            step.actions.append(.dip(false))
            logs.append("bargeInDipCancelled \(id) reason=cap")
        default: break
        }
        step.outputs = out + step.outputs
        return step
    }

    /// Item 10: the setting changed; turned off, a candidate being checked is dropped at once.
    public mutating func setEnabled(_ on: Bool) -> Step {
        enabled = on
        var step = Step()
        if !on { release(reason: "settingOff", into: &step) }
        return step
    }

    /// Item 12: a stop phrase stopped her; the candidate is §14–§16's, never released here.
    public mutating func stopPhrase() -> Step {
        var step = Step()
        release(reason: "stopPhrase", into: &step)
        return step
    }

    /// Drop a kept candidate; a held cut utterance goes out as today.
    private mutating func release(reason: String, into step: inout Step) {
        switch state {
        case .keeping(let id, _, _, _, _): cancel(id, reason: reason, into: &step)
        case .carrying(let id, _, _, let buffer, _):
            state = .idle
            carryArmed = false
            step.outputs += buffer
            step.actions.append(.dip(false))
            logs.append("bargeInDipCancelled \(id) reason=\(reason)")
        case .idle: break
        }
    }

    private mutating func keep(_ output: UplinkGateOutput) {
        guard case .keeping(let id, let since, var audio, let dipped, let closed) = state else { return }
        switch output {
        case .audio(let frame) where !closed: audio.append(frame)
        case .utterance(let record):
            cutAtUnmute = record.endReason == .cutAtUnmute
            state = .keeping(id: id, since: since, audio: audio, dipped: dipped, closed: true)
            return
        default: return
        }
        state = .keeping(id: id, since: since, audio: audio, dipped: dipped, closed: closed)
    }

    private mutating func handle(_ events: [BargeInShadow.Event], guidancePlaying: Bool, into step: inout Step) {
        var out: [UplinkGateOutput] = []
        handle(events, guidancePlaying: guidancePlaying, into: &step, out: &out)
        step.outputs += out
    }

    private mutating func handle(_ events: [BargeInShadow.Event], guidancePlaying: Bool, into step: inout Step,
                                 out: inout [UplinkGateOutput]) {
        for event in events {
            switch event {
            case .started(let id, let candidate):
                if case .keeping(let old, _, _, _, _) = state { cancel(old, reason: "superseded", into: &step) }
                cutAtUnmute = false
                // Item 10: guidance is never interruptible; off is exactly today's behaviour.
                if candidate, enabled, !guidancePlaying, case .idle = state {
                    state = .keeping(id: id, since: now, audio: [], dipped: false, closed: false)
                }
            case .early(let id):
                guard case .keeping(id, let since, let audio, false, let closed) = state else { continue }
                state = .keeping(id: id, since: since, audio: audio, dipped: true, closed: closed)
                step.actions.append(.dip(true))
            case .wouldStop(let id):
                if case .carrying(id, let since, let kept, let buffer, let skip) = state {
                    // Her reply already ended: nothing to stop; the kept audio leads the cut's utterance.
                    state = .idle
                    carryArmed = false
                    step.actions.append(.dip(false))
                    if let start = buffer.first {
                        out += [start] + kept.map(UplinkGateOutput.audio) + buffer.dropFirst(1 + skip)
                    }
                    logs.append("bargeInCarried \(id) frames=\(kept.count) heldMs=\((now - since).milliseconds)")
                    continue
                }
                guard case .keeping(id, let since, let audio, _, let closed) = state else { continue }
                state = .idle
                // The flush restores her volume (`LiveAudio.flush`), so it never blips back first.
                step.actions.append(.stop)
                step.outputs.append(.speechStarted(sentToModel: true))
                step.outputs += audio.map(UplinkGateOutput.audio)
                if closed {
                    // Decided at the final, after the gate closed it: close what was sent.
                    step.outputs += [.speechStopped(.normal), .streamEnd]
                } else {
                    step.adopt = true
                }
                logs.append("bargeInStop \(id) heldMs=\((now - since).milliseconds)")
            case .rejected(let id, let reason):
                switch state {
                case .keeping(id, _, _, _, _): cancel(id, reason: reason.rawValue, into: &step)
                case .carrying(id, _, _, let buffer, _):
                    // The cut's utterance goes out as today, without the kept part.
                    state = .idle
                    carryArmed = false
                    out += buffer
                    step.actions.append(.dip(false))
                    logs.append("bargeInDipCancelled \(id) reason=\(reason.rawValue)")
                default: break
                }
            }
        }
    }

    private mutating func cancel(_ id: Int, reason: String, into step: inout Step) {
        guard case .keeping(id, _, _, let dipped, _) = state else { return }
        state = .idle
        if dipped {
            step.actions.append(.dip(false))
            logs.append("bargeInDipCancelled \(id) reason=\(reason)")
        }
    }
}
