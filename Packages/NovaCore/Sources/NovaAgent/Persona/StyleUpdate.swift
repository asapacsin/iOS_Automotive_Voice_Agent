import NovaKit
import NovaPorts

/// F-21 §16 item 8 (T-034c): the record and log lines of the instruction update. Codes and numbers only (I-8).
public enum StyleUpdateLine: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable, CaseIterable { case tool, settings, resume }
    public enum Skip: String, Sendable, Hashable, CaseIterable { case same, model, disabled }

    /// `style-update sent style=<raw> chars=<n> reason=tool|settings|resume`
    case sent(style: SpeakingStyle, chars: Int, reason: Reason)
    /// `style-update skipped reason=same|model|disabled`
    case skipped(Skip)
    /// `style-update rejected code=<code>`
    case rejected(code: RealtimeErrorCode)

    public static let kind = "style-update"

    public var fields: String {
        switch self {
        case .sent(let style, let chars, let reason): "sent style=\(style.rawValue) chars=\(chars) reason=\(reason.rawValue)"
        case .skipped(let skip): "skipped reason=\(skip.rawValue)"
        case .rejected(let code): "rejected code=\(code.rawValue)"
        }
    }

    /// The same line for `RuntimeLog`.
    public var logLine: String { "\(Self.kind) \(fields)" }
}

/// F-21 §16 (T-034c): when her new tone reaches Gemini on the open connection. Pure: `AgentState` feeds it the
/// session's moments and sends what it returns. It tracks the instruction the server holds (the setup's, then each
/// update sent) and the instruction of the setup that began the resumption chain (memory only, like the handle, I-7).
public struct StyleUpdates: Sendable {
    /// Item 7: a non-retryable close this soon after an update stops updates for the rest of the app run.
    public static let rejectionWindow = NovaDuration.seconds(2)

    /// What to do at a moment: the instruction to send now (nil: nothing) and the line to write (nil: none).
    public struct Step: Sendable, Hashable {
        public var send: String?
        public var line: StyleUpdateLine?
        static let none = Step(send: nil, line: nil)
    }

    /// The base the session was set up with (comfort mode and web search already applied); only the style differs.
    public let base: String
    public let model: String
    public private(set) var style: SpeakingStyle
    /// Items 3, 5: what the open connection holds; nil while none is set up.
    public private(set) var held: String?
    /// Item 5: the instruction of the setup that began the resumption chain; nil when unknown (a kept handle with no
    /// instruction), which counts as different.
    public private(set) var original: String?
    /// Item 7: a rejection stopped updates.
    public private(set) var disabled = false
    /// Item 2: an ok `set_speaking_style` result went to the model; the turn that answers it has not ended yet.
    private var afterTool = false
    /// The turn answering that result: the first to open, or to speak, after it was sent. The call's own turn may
    /// close after the result went out (Gemini closes it before the answer turn opens), and that close is no answer.
    private var answering: TurnID?
    /// Item 4: a 设置 change waits for her reply to end.
    private var afterReply = false
    /// The connection being set up: with a handle, and the update it sends first at `setupComplete` (if any).
    private var connecting: (resumed: Bool, setup: String, update: String?)?
    /// Item 7: when the last update went out on the open connection.
    private var sentAt: NovaInstant?

    /// `disabled`: item 7, an earlier session of this app run had an update rejected.
    public init(base: String, style: SpeakingStyle, model: String = SessionConfig.contextUpdateModel,
                disabled: Bool = false) {
        self.base = base
        self.style = style
        self.model = model
        self.disabled = disabled
    }

    /// Item 5, F-24 §15: this session's first connect resumes a give-up handle whose chain began with `original`
    /// (nil: not known, so the current instruction is sent).
    public mutating func resumeChain(original: String?) { self.original = original }

    /// Item 1: the whole instruction for the current tone.
    public var instruction: String { PersonaInstruction.build(base: base, style: style) }

    var supported: Bool { SessionConfig.supportsContextUpdate(model: model) }

    // MARK: Moments

    /// A socket opens. Returns what its setup carries and the update it sends first at `setupComplete` (item 5).
    /// Whatever waited for a turn end on the old socket is dropped (item 2: the next setup reads the tone).
    public mutating func connect(resume handle: String?) -> (instruction: String, updateAtSetup: String?) {
        afterTool = false
        afterReply = false
        held = nil
        sentAt = nil
        let current = instruction
        guard handle != nil else {
            // A setup without a handle begins a new chain and already holds the current tone.
            original = current
            connecting = (false, current, nil)
            return (current, nil)
        }
        let update = original != current && supported && !disabled ? current : nil
        connecting = (true, current, update)
        return (current, update)
    }

    /// `setupComplete`. A resumed connection holds the chain's original; its update (if any) already went out first.
    public mutating func setupComplete(at now: NovaInstant) -> [Step] {
        guard let setup = connecting else { return [] }
        connecting = nil
        var steps: [Step] = []
        if setup.resumed {
            // An unknown original never equals an instruction, so the current one is sent.
            held = original ?? ""
            if let update = setup.update {
                held = update
                sentAt = now
                steps.append(Step(send: nil, line: .sent(style: style, chars: update.count, reason: .resume)))
            }
        } else {
            held = setup.setup
        }
        guard held != instruction else { return steps }
        // Not sent at connect on this model or after a rejection (`skipped`), or the tone changed while connecting:
        // she is not replying yet, so it goes now.
        let resumeSkipped = setup.resumed && setup.update == nil && original != setup.setup
        steps.append(decide(resumeSkipped ? .resume : .settings, at: now))
        return steps
    }

    /// Item 2: an ok `set_speaking_style` result went to the model with `style`.
    public mutating func toolResult(_ newStyle: SpeakingStyle) {
        style = newStyle
        guard held != nil else { return }
        afterTool = true
        answering = nil
    }

    /// A turn opened (`opened`) or spoke: after a tone result, the first one is the answer to it.
    public mutating func turnActive(_ turn: TurnID) {
        if afterTool, answering == nil { answering = turn }
    }

    /// Item 4: a tone picked in 设置. `replying`: her reply (or the turn answering a tone change) is still open.
    /// The tool's own write of the same tone changes nothing.
    public mutating func settingsChanged(_ newStyle: SpeakingStyle, replying: Bool, at now: NovaInstant) -> Step {
        guard newStyle != style else { return .none }
        style = newStyle
        guard held != nil else { return .none }  // not set up: the setup or `setupComplete` takes it
        if replying || afterTool {
            afterReply = true
            return .none
        }
        return decide(.settings, at: now)
    }

    /// Items 2, 4: `turn` ended (`turnComplete` or `interrupted`). A tone result waits for its answering turn; a
    /// 设置 change waits for any reply to end.
    public mutating func turnEnded(_ turn: TurnID, at now: NovaInstant) -> Step {
        let answered = afterTool && answering == turn
        guard answered || afterReply && !afterTool else { return .none }
        let reason: StyleUpdateLine.Reason = answered ? .tool : .settings
        afterTool = false
        afterReply = false
        answering = nil
        return decide(reason, at: now)
    }

    /// Item 7: the socket ended with `code` (nil: a normal close). A non-retryable rejection (MALFORMED, or a 1007/1008
    /// close not about resumption, which the provider reports as CONNECTION_CLOSED) within 2 s of an update stops them.
    public mutating func socketEnded(_ code: RealtimeErrorCode?, at now: NovaInstant) -> Step {
        let last = sentAt
        held = nil
        sentAt = nil
        connecting = nil
        afterTool = false
        afterReply = false
        guard let code, let last, now - last <= Self.rejectionWindow,
              code == .malformed || code == .connectionClosed else { return .none }
        disabled = true
        return Step(send: nil, line: .rejected(code: code))
    }

    /// The socket was closed (a stop, a lost network, a failure): nothing waits and nothing is held.
    public mutating func closed() {
        held = nil
        sentAt = nil
        connecting = nil
        afterTool = false
        afterReply = false
    }

    // MARK: Decision

    /// Items 3, 6, 7: one update when the server's instruction differs, on the supported model, unless stopped.
    private mutating func decide(_ reason: StyleUpdateLine.Reason, at now: NovaInstant) -> Step {
        guard held != nil else { return .none }
        if disabled { return Step(send: nil, line: .skipped(.disabled)) }
        if !supported { return Step(send: nil, line: .skipped(.model)) }
        let current = instruction
        if current == held { return Step(send: nil, line: .skipped(.same)) }
        held = current
        sentAt = now
        return Step(send: current, line: .sent(style: style, chars: current.count, reason: reason))
    }
}
