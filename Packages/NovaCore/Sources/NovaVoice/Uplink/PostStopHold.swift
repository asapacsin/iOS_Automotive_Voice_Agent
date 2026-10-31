import NovaKit
import NovaPorts

/// F-08 §16 tuning.
public struct BargeInTuning: Sendable, Hashable {
    /// An utterance starting this soon after the stop utterance closed is sent only once words are heard.
    public var postStopWindow: NovaDuration
    /// Held audio past this with no words is dropped (`reason=cap`).
    public var postStopCap: NovaDuration
    /// After a held utterance closes, how long its final transcript is awaited; none by then counts as no words.
    public var postStopFinalWait: NovaDuration

    public init(postStopWindow: NovaDuration = .seconds(3), postStopCap: NovaDuration = .seconds(8),
                postStopFinalWait: NovaDuration = .seconds(2)) {
        self.postStopWindow = postStopWindow
        self.postStopCap = postStopCap
        self.postStopFinalWait = postStopFinalWait
    }
}

/// F-08 §16 item 2: after 别说了, nothing goes up until the phone heard real words. Sits between the uplink gate and
/// the provider: the gate's outputs come in (the recognizer is fed before this, so it still hears everything) and
/// what may go up comes out. A sent utterance starting within the window is buffered; the first partial with words
/// releases it (start mark, buffered audio in order, then live); a close with a final that has words sends it whole;
/// no words, a stop phrase or the cap drops it. Utterances are numbered like the recognizer's (one per
/// `speechStarted`). Pure and synchronous; time moves 10 ms per captured frame. Logs are numbers and enums (I-8).
public struct PostStopHold: Sendable {
    public enum DropReason: String, Sendable, Hashable { case noWords, stopPhrase, cap }

    private enum State: Sendable {
        case idle
        /// A stop happened; the window starts when the held stop utterance closes (or now when none was open).
        case awaitingStopClose
        case window(until: NovaDuration)
        /// A held utterance: its outputs so far, since when, whether the gate closed it already.
        case holding(id: Int, since: NovaDuration, buffer: [UplinkGateOutput], closedAt: NovaDuration?)
        /// Released or dropped: the rest of utterance `id` passes (or is swallowed) as decided.
        case passing(id: Int)
        case dropping(id: Int)
    }

    private let tuning: BargeInTuning
    private var state = State.idle
    private var now = NovaDuration.zero
    /// Number of the newest utterance the gate started.
    private var utterance = 0
    private var logs: [String] = []

    public init(tuning: BargeInTuning = BargeInTuning()) { self.tuning = tuning }

    /// True while utterances are being held or the window is open (tests, diagnostics).
    public var armed: Bool {
        if case .idle = state { return false }
        return true
    }

    /// The log lines since the last call.
    public mutating func takeLogs() -> [String] {
        defer { logs.removeAll(keepingCapacity: true) }
        return logs
    }

    /// A stop phrase ended her reply. `holdingStopUtterance`: the gate holds the open stop utterance to its pause,
    /// so the window starts at its close. With no local recognizer (`wordsAvailable` false) nothing is held.
    public mutating func stopped(holdingStopUtterance: Bool, wordsAvailable: Bool) {
        guard wordsAvailable else { return }
        switch state {
        case .holding, .passing, .dropping: return  // a stop inside a held utterance changes nothing
        default: break
        }
        state = holdingStopUtterance ? .awaitingStopClose : .window(until: now + tuning.postStopWindow)
    }

    /// One captured frame and what the gate made of it.
    public mutating func frame(_ outputs: [UplinkGateOutput]) -> [UplinkGateOutput] {
        now = now + .milliseconds(10)
        var out = pass(outputs)
        out += expire()
        return out
    }

    /// Outputs that come from no frame (the arbiter's force-close).
    public mutating func pass(_ outputs: [UplinkGateOutput]) -> [UplinkGateOutput] {
        var out: [UplinkGateOutput] = []
        for output in outputs { out += pass(output) }
        return out
    }

    private mutating func pass(_ output: UplinkGateOutput) -> [UplinkGateOutput] {
        if case .speechStarted(let sent) = output {
            utterance += 1
            switch state {
            case .holding(let id, _, _, _):
                // A new utterance while the last one waits for its final: the late one counts as no words.
                state = .idle
                var out = drop(id, reason: .noWords, buffer: [])
                out += startInWindow(sent: sent, output)
                return out
            case .window(let until) where now <= until:
                return startInWindow(sent: sent, output)
            case .window, .passing, .dropping:
                state = .idle
            case .idle, .awaitingStopClose:
                break
            }
            return [output]
        }
        switch state {
        case .holding(let id, let since, var buffer, let closedAt):
            buffer.append(output)
            if case .utterance = output {
                state = .holding(id: id, since: since, buffer: buffer, closedAt: closedAt ?? now)
            } else {
                state = .holding(id: id, since: since, buffer: buffer, closedAt: closedAt)
            }
            if closedAt == nil, now - since > tuning.postStopCap { return drop(id, reason: .cap, buffer: buffer) }
            return []
        case .dropping:
            if case .utterance(var record) = output {
                record.sentToModel = false
                state = .idle
                return [.utterance(record)]
            }
            return []
        case .passing:
            if case .utterance = output { state = .idle }
            return [output]
        case .awaitingStopClose:
            if case .utterance(let record) = output, record.endReason == .stopPhrase {
                state = .window(until: now + tuning.postStopWindow)
            }
            return [output]
        default:
            return [output]
        }
    }

    private mutating func startInWindow(sent: Bool, _ output: UplinkGateOutput) -> [UplinkGateOutput] {
        guard sent else { return [output] }
        state = .holding(id: utterance, since: now, buffer: [output], closedAt: nil)
        return []
    }

    /// The local recognizer's partial for utterance `id`: words release a held utterance.
    public mutating func partial(_ text: String, utterance id: Int) -> [UplinkGateOutput] {
        guard case .holding(let held, let since, let buffer, _) = state, held == id, Self.hasWords(text, partial: true)
        else { return [] }
        return release(id, since: since, buffer: buffer)
    }

    /// The utterance's final words ("" when none or unclear).
    public mutating func final(_ text: String, utterance id: Int) -> [UplinkGateOutput] {
        guard case .holding(let held, let since, let buffer, let closedAt) = state, held == id else { return [] }
        if ListeningIntent.classify(text) == .shutUp { return drop(id, reason: .stopPhrase, buffer: buffer) }
        if Self.hasWords(text, partial: false) { return release(id, since: since, buffer: buffer) }
        // A final before the close (partial-like) only decides once the gate closed the utterance.
        guard closedAt != nil else { return [] }
        return drop(id, reason: .noWords, buffer: buffer)
    }

    private mutating func expire() -> [UplinkGateOutput] {
        switch state {
        case .window(let until) where now > until:
            state = .idle
        case .holding(let id, _, let buffer, let closedAt?) where now - closedAt >= tuning.postStopFinalWait:
            return drop(id, reason: .noWords, buffer: buffer)
        case .holding(let id, let since, let buffer, nil) where now - since > tuning.postStopCap:
            return drop(id, reason: .cap, buffer: buffer)
        default:
            break
        }
        return []
    }

    private mutating func release(_ id: Int, since: NovaDuration, buffer: [UplinkGateOutput]) -> [UplinkGateOutput] {
        logs.append("postStopReleased heldMs=\((now - since).milliseconds)")
        let closed = buffer.contains { if case .utterance = $0 { true } else { false } }
        state = closed ? .idle : .passing(id: id)
        return buffer
    }

    /// Nothing of the utterance goes up: the core hears a not-sent utterance (start and stop marks only).
    private mutating func drop(_ id: Int, reason: DropReason, buffer: [UplinkGateOutput]) -> [UplinkGateOutput] {
        logs.append("postStopDropped reason=\(reason.rawValue)")
        var out: [UplinkGateOutput] = [.speechStarted(sentToModel: false)]
        var closed = false
        for output in buffer {
            switch output {
            case .speechStopped: out.append(output)
            case .utterance(var record):
                record.sentToModel = false
                out.append(.utterance(record))
                closed = true
            default: break
            }
        }
        if closed {
            state = .idle
        } else {
            out.append(.speechStopped(.flagged))
            state = .dropping(id: id)
        }
        return out
    }

    /// At least one Han character that is not a filler, or two Latin letters; never a stop phrase. A partial that
    /// is still the start of a stop phrase (「别」「别说」) is not words yet.
    static func hasWords(_ text: String, partial: Bool) -> Bool {
        let phrase = ListeningIntent.normalise(text)
        guard !phrase.isEmpty, ListeningIntent.classify(text) != .shutUp else { return false }
        if partial, ListeningIntent.shutUpPhrases.contains(where: { $0.hasPrefix(phrase) }) { return false }
        let han = phrase.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) && !ListeningIntent.fillers.contains(Character($0)) }
        let latin = phrase.unicodeScalars.filter { ("a"..."z").contains(Character($0)) }
        return !han.isEmpty || latin.count >= 2
    }
}
