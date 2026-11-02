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
/// Pure; time moves 10 ms per frame. Logs are numbers and enums (I-8).
public struct BargeInLive: Sendable {
    public static let dipDb = 10.0
    public static let bufferCap = NovaDuration.seconds(8)

    private enum State: Sendable {
        case idle
        case keeping(id: Int, since: NovaDuration, audio: [PCMFrame16k], dipped: Bool, closed: Bool)
    }

    public var enabled = false
    private var state = State.idle
    private var now = NovaDuration.zero
    private var logs: [String] = []

    public init() {}

    public mutating func takeLogs() -> [String] {
        defer { logs.removeAll(keepingCapacity: true) }
        return logs
    }

    /// True while a candidate's audio is kept (tests, diagnostics).
    public var keeping: Bool {
        if case .keeping = state { return true }
        return false
    }

    /// The result of one step: what the shell does (in order) and the outputs to forward after it.
    public struct Step: Sendable, Hashable {
        public var actions: [BargeInAction] = []
        public var outputs: [UplinkGateOutput] = []
        /// The gate must send the rest of the open utterance (`SpeechUplinkGate.adoptOpenUtterance`).
        public var adopt = false
        public init() {}
    }

    /// One frame: the gate's raw outputs for it and the shadow's events after it.
    public mutating func frame(_ outputs: [UplinkGateOutput], events: [BargeInShadow.Event],
                               guidancePlaying: Bool) -> Step {
        now = now + .milliseconds(10)
        return pass(outputs, events: events, guidancePlaying: guidancePlaying)
    }

    /// Outputs that come from no frame (the force-close), or none with the recognizer's words.
    public mutating func pass(_ outputs: [UplinkGateOutput], events: [BargeInShadow.Event],
                              guidancePlaying: Bool) -> Step {
        var step = Step()
        // Each `started` is handled at its own `speechStarted`, so the pre-roll after it is kept.
        var starts = events.filter { if case .started = $0 { true } else { false } }[...]
        for output in outputs {
            if case .speechStarted = output, let start = starts.popFirst() {
                handle([start], guidancePlaying: guidancePlaying, into: &step)
                continue
            }
            keep(output)
        }
        handle(Array(starts) + events.filter { if case .started = $0 { false } else { true } },
               guidancePlaying: guidancePlaying, into: &step)
        if case .keeping(let id, let since, _, _, _) = state, now - since > Self.bufferCap {
            cancel(id, reason: "cap", into: &step)
        }
        return step
    }

    private mutating func keep(_ output: UplinkGateOutput) {
        guard case .keeping(let id, let since, var audio, let dipped, let closed) = state else { return }
        switch output {
        case .audio(let frame) where !closed: audio.append(frame)
        case .utterance: state = .keeping(id: id, since: since, audio: audio, dipped: dipped, closed: true); return
        default: return
        }
        state = .keeping(id: id, since: since, audio: audio, dipped: dipped, closed: closed)
    }

    private mutating func handle(_ events: [BargeInShadow.Event], guidancePlaying: Bool, into step: inout Step) {
        for event in events {
            switch event {
            case .started(let id, let candidate):
                if case .keeping(let old, _, _, _, _) = state { cancel(old, reason: "superseded", into: &step) }
                // Item 10: guidance is never interruptible; off is exactly today's behaviour.
                if candidate, enabled, !guidancePlaying {
                    state = .keeping(id: id, since: now, audio: [], dipped: false, closed: false)
                }
            case .early(let id):
                guard case .keeping(id, let since, let audio, false, let closed) = state else { continue }
                state = .keeping(id: id, since: since, audio: audio, dipped: true, closed: closed)
                step.actions.append(.dip(true))
            case .wouldStop(let id):
                guard case .keeping(id, let since, let audio, let dipped, let closed) = state else { continue }
                state = .idle
                if dipped { step.actions.append(.dip(false)) }
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
                guard case .keeping(id, _, _, _, _) = state else { continue }
                cancel(id, reason: reason.rawValue, into: &step)
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
