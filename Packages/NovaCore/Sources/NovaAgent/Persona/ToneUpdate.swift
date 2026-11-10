import NovaKit
import NovaPorts

/// F-21 §16 (T-034c): what a session needs to send her new tone on the same connection.
public struct ToneUpdateSetup: Sendable, Hashable {
    /// The only model that takes `contextUpdate` (item 6).
    public static let supportedModel = "gemini-3.8-live"

    /// The base the session was set up with (comfort mode and web search already applied, item 1).
    public let base: String
    public let model: String
    /// The saved tone when the session starts.
    public let style: SpeakingStyle
    /// Item 5: for a give-up resume, the tone of the setup that began the kept handle's chain.
    public let resumeStyle: SpeakingStyle?
    /// Item 7: an earlier session in this app run had an update rejected.
    public let disabled: Bool

    public init(base: String, model: String, style: SpeakingStyle, resumeStyle: SpeakingStyle? = nil,
                disabled: Bool = false) {
        self.base = base
        self.model = model
        self.style = style
        self.resumeStyle = resumeStyle
        self.disabled = disabled
    }

    var supported: Bool {
        (model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model) == Self.supportedModel
    }
}

/// F-21 §16 item 8: `style-update …` record and log lines; codes and numbers only (I-8).
public enum StyleUpdateLine: Sendable, Hashable {
    public enum Reason: String, Sendable { case tool, settings, resume }
    public enum SkipReason: String, Sendable { case same, model, disabled }

    case sent(style: SpeakingStyle, chars: Int, reason: Reason)
    case skipped(SkipReason)
    case rejected(code: RealtimeErrorCode)

    public var fields: String {
        switch self {
        case .sent(let style, let chars, let reason): "sent style=\(style.rawValue) chars=\(chars) reason=\(reason.rawValue)"
        case .skipped(let reason): "skipped reason=\(reason.rawValue)"
        case .rejected(let code): "rejected code=\(code.rawValue)"
        }
    }

    public var logLine: String { "style-update \(fields)" }
}

/// F-21 §16 items 2-7, pure. `AgentState` feeds it the tool result, the 设置 change, turn ends and connects; it says
/// what to send. Tracks the instruction the server holds, so only a real change costs a slower reply.
struct ToneUpdater: Sendable {
    /// Item 7: how long after an update a non-retryable close counts as its rejection.
    static let rejectionWindow = NovaDuration.seconds(2)

    enum Output: Sendable, Hashable {
        case send(String)
        case line(StyleUpdateLine)
    }

    private let setup: ToneUpdateSetup
    /// The saved tone (the tool and 设置 save it before it reaches here).
    private(set) var current: SpeakingStyle
    /// What the server holds now: the last setup's tone, or the last update sent on this connection.
    private(set) var held: SpeakingStyle
    /// Item 5: the tone of the setup that began the resumption chain.
    private(set) var chainOriginal: SpeakingStyle
    private(set) var disabled: Bool
    /// An update waiting for the reply to end; `answer`: the tool path waits for her confirmation's words first.
    /// `turn`: the turn answering a tool result (open when the result went out, or the first opened after it); its
    /// `interrupted` ends the wait even before any words.
    private var pending: (reason: StyleUpdateLine.Reason, needsAnswer: Bool, answered: Bool, turn: TurnID?)?
    private var sentAt: NovaInstant?
    /// Item 5: an update queued right after a resumed setup; its line and its 2 s window start at setupComplete.
    private var resumeInFlight: String?

    init(_ setup: ToneUpdateSetup) {
        self.setup = setup
        current = setup.style
        held = setup.resumeStyle ?? setup.style
        chainOriginal = setup.resumeStyle ?? setup.style
        disabled = setup.disabled
    }

    func instruction(_ style: SpeakingStyle) -> String { PersonaInstruction.build(base: setup.base, style: style) }

    /// Items 2-4: a new tone was saved. `replying`: her reply is open now (only the 设置 path sends at once).
    mutating func changed(to style: SpeakingStyle, reason: StyleUpdateLine.Reason, replying: Bool,
                          openTurn: TurnID? = nil, at now: NovaInstant) -> [Output] {
        current = style
        if !setup.supported { pending = nil; return [.line(.skipped(.model))] }
        if disabled { pending = nil; return [.line(.skipped(.disabled))] }
        if style == held {
            pending = nil
            return [.line(.skipped(.same))]
        }
        if reason == .settings, !replying, pending == nil { return send(reason, at: now) }
        // A tool change waits for the turn that says the confirmation; a 设置 change for the reply that is open.
        let tool = reason == .tool || pending?.needsAnswer == true
        pending = (pending?.reason ?? reason, tool, false, pending?.turn ?? (reason == .tool ? openTurn : nil))
        return []
    }

    /// A turn opened: the first one after a tool result answers it.
    mutating func turnStarted(_ turn: TurnID) {
        if pending?.needsAnswer == true, pending?.turn == nil { pending?.turn = turn }
    }

    /// Her confirmation's words or audio arrived.
    mutating func replyOutput() {
        if pending?.needsAnswer == true { pending?.answered = true }
    }

    /// Item 2: a turn ended (`turnComplete`, or `interrupted` = true). The answering turn's interruption ends the wait
    /// even before her words; a completed turn needs them (a call turn may close before the result).
    mutating func turnEnded(_ turn: TurnID, interrupted: Bool, at now: NovaInstant) -> [Output] {
        guard let p = pending,
              !p.needsAnswer || p.answered || (interrupted && p.turn == turn) else { return [] }
        pending = nil
        guard current != held else { return [] }
        return send(p.reason, at: now)
    }

    /// Item 2: the connection closed first; nothing is sent, the next setup reads the saved tone.
    mutating func socketClosed() { pending = nil }

    /// Item 5's line and window start here; a tone changed while connecting (设置) goes now (item 4).
    mutating func setupComplete(at now: NovaInstant) -> [Output] {
        if let text = resumeInFlight {
            resumeInFlight = nil
            sentAt = now
            return [.line(.sent(style: held, chars: text.count, reason: .resume))]
        }
        guard current != held, setup.supported, !disabled else { return [] }
        return send(.settings, at: now)
    }

    /// Items 1, 5: a connect. Without a handle the setup carries the current tone (the chain starts again); with one,
    /// the server keeps the chain's original, so a different current tone goes right after the setup.
    mutating func connect(resume: Bool, at now: NovaInstant) -> (instruction: String?, update: String?, lines: [Output]) {
        pending = nil
        resumeInFlight = nil
        guard resume else {
            held = current
            chainOriginal = current
            return (instruction(current), nil, [])
        }
        held = chainOriginal
        guard current != chainOriginal else { return (nil, nil, []) }
        if !setup.supported { return (nil, nil, [.line(.skipped(.model))]) }
        if disabled { return (nil, nil, [.line(.skipped(.disabled))]) }
        held = current
        let text = instruction(current)
        resumeInFlight = text
        return (nil, text, [])
    }

    /// Item 7: a non-retryable close within 2 s of an update stops updates for the app run. `GeminiLiveProvider` reports
    /// a 1007 after setupComplete, and a 1008 not about the key, quota, model or a resumption, as `CONNECTION_CLOSED`.
    mutating func failed(_ code: RealtimeErrorCode, at now: NovaInstant) -> [Output] {
        // A close before setupComplete of a resumed setup that carried an update counts as well.
        let inWindow = resumeInFlight != nil || sentAt.map { now < $0 + Self.rejectionWindow } == true
        guard inWindow, !disabled, code == .malformed || code == .connectionClosed else { return [] }
        disabled = true
        sentAt = nil
        resumeInFlight = nil
        return [.line(.rejected(code: code))]
    }

    /// The chain's original tone, kept with a give-up handle (item 5).
    var keptStyle: SpeakingStyle { chainOriginal }

    private mutating func send(_ reason: StyleUpdateLine.Reason, at now: NovaInstant) -> [Output] {
        let text = instruction(current)
        held = current
        sentAt = now
        return [.send(text), .line(.sent(style: current, chars: text.count, reason: reason))]
    }
}
