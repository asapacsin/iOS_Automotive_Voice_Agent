import NovaKit
import NovaPorts
import NovaTools
import NovaVoice

/// Everything that enters AgentCore (ios-architecture §5.3). M1 subset: no wake, navigation or UI intents yet.
public enum AgentEvent: Sendable, Hashable {
    case start
    case stop
    /// A provider event from the socket opened as `connection`.
    case realtime(RealtimeEvent, connection: Generation)
    /// Local VAD (F-04). `recentSpeech` is `SpeechUplinkGate.hasRecentSpeech` at onset.
    case speechStarted(recentSpeech: Bool)
    case speechStopped
    /// `ToolRunner` finished `call` of `turn`.
    case toolFinished(TurnID, ToolCall, ToolResult)
    case playback(PlaybackEvent)
    case audioSession(AudioSessionEvent)
    case timer(AgentTimer)
    /// The navigation flow's phase changed; the guards read it (F-09, F-15).
    case navigation(NavigationFlags)
}

/// What the dispatch guards need to know about navigation (`navigatingNow`, `guidanceRunningNow`).
public struct NavigationFlags: Sendable, Hashable {
    public var navigating: Bool
    public var guidanceRunning: Bool
    public var listOpen: Bool

    public init(navigating: Bool = false, guidanceRunning: Bool = false, listOpen: Bool = false) {
        self.navigating = navigating
        self.guidanceRunning = guidanceRunning
        self.listOpen = listOpen
    }
}

public enum AgentTimer: Sendable, Hashable {
    case session(SessionTimer)
    case pipeline(PipelineTimer)
}

public enum ProviderCommand: Sendable, Hashable {
    /// Open socket `connection`; its events come back tagged with it.
    case connect(connection: Generation, resume: String?)
    case close
    case toolResponses([ToolResponse])
    case text([TextTurn], turnComplete: Bool)
}

/// What the UI shows (contracts/voice-agent.md §1). A snapshot, not product state.
public struct AgentViewState: Sendable, Hashable {
    public var chip: AssistantChip = .idle
    /// The judged reply text of the current turn (小诺's bubble).
    public var subtitle = ""
    /// Terminal error: the settings message for this code.
    public var configError: RealtimeErrorCode?
}

/// Effects in the order they must run (ios-architecture §5.3): flush before notify, and so on.
public enum AgentEffect: Sendable, Hashable {
    case provider(ProviderCommand)
    /// Stop the reply lane and raise the epoch. Always before `cancelRevoicing`.
    case flushPlayback(Epoch)
    case cancelRevoicing(Epoch)
    /// ResponseStarted: a failed previous reply no longer silences this one.
    case newReply
    /// One judged clause for the revoicer.
    case speak(String)
    case startTool(TurnID, ToolCall)
    case cancelTool(CallID)
    case schedule(AgentTimer, at: NovaInstant)
    case cancelTimer(AgentTimer)
    case publish(AgentViewState)
    case diagnostic(DiagnosticEvent)
}

/// The single serialisation point (Android's session mutex), as a pure value: `VoiceSession`,
/// `DriverTurnPipeline`, `SpeechArbiter` and `ToolDispatcher` composed. Synchronous; I/O happens in effects.
public struct AgentState: Sendable {
    public private(set) var session = VoiceSession()
    public private(set) var pipeline = DriverTurnPipeline()
    public private(set) var arbiter = SpeechArbiter()
    public private(set) var view = AgentViewState()
    private var dispatcher = ToolDispatcher()
    /// F-10 referents: what the driver really changed lately.
    public private(set) var context = DriverContext()
    private var navigation = NavigationFlags()
    private var segmenter = ClauseSegmenter()
    /// Turn state of the current socket. TurnIDs restart at 1 on every socket, so all of it is reset
    /// when a new socket is opened.
    private var openTurn: TurnID?
    /// Turns of an utterance the pipeline gave up on (W3): their late calls and words are dropped.
    private var abandoned: Set<TurnID> = []
    /// Set by the give-up; the next turn to open still belongs to that utterance.
    private var abandonNextTurn = false
    /// Turns the driver barged into, or that were voided (W2): nothing more of them is spoken, even
    /// before Gemini's `interrupted` arrives.
    private var silenced: Set<TurnID> = []
    /// Driver words of the current utterance, kept from speech onset until the next onset, so the
    /// guards still read them when the tool call arrives.
    private var transcript = ""
    private var speechOnsets = 0
    private var transcriptEpoch = 0
    /// Clauses waiting while the arbiter holds the reply (R1 guidance, R5 transient loss).
    private var heldClauses: [String] = []
    /// Session timers by kind, so `cancelTimer` can name the pending one.
    private var sessionTimers: [SessionTimer.Kind: SessionTimer] = [:]
    private var pipelineTimers: [PipelineTimer.Kind: PipelineTimer] = [:]

    public init() {}

    public mutating func handle(_ event: AgentEvent, at now: NovaInstant) -> [AgentEffect] {
        switch event {
        case .start:
            return session(.start, at: now)
        case .stop:
            return session(.stop, at: now)
        case .realtime(let realtime, let connection):
            guard connection == session.connection, session.state != .disconnected, session.state != .error else {
                return []
            }
            // Session first (a terminal event closes the socket and the turn), then the reply side,
            // unless that event ended the session.
            let effects = session(.realtime(realtime, connection: connection), at: now)
            guard session.state != .disconnected, session.state != .error else { return effects }
            return effects + reply(realtime, at: now)
        case .speechStarted(let recentSpeech):
            speechOnsets += 1
            transcript = ""
            abandonNextTurn = false
            // The driver speaks to her: a reply may claim focus again after a permanent loss (R4).
            if recentSpeech { arbiter.regainFocus() }
            var effects: [AgentEffect] = []
            for effect in arbiter.handle(.speechStarted(recentSpeech: recentSpeech)) {
                switch effect {
                case .flushPlayback(let epoch):
                    if let turn = openTurn { silenced.insert(turn) }
                    heldClauses = []
                    effects.append(.flushPlayback(epoch))
                case .cancelRevoicing(let epoch):
                    segmenter.reset()
                    effects.append(.cancelRevoicing(epoch))
                case .bargeIn(let qualified):
                    effects += session(.bargeIn(qualified: qualified), at: now)
                }
            }
            return effects + session(.speechStarted, at: now)
        case .speechStopped:
            // The no-answer clock (W3) starts when the driver stops, with what we heard so far.
            return session(.speechStopped, at: now) + pipeline(.driverUtterance(transcript), at: now)
        case .toolFinished(let turn, let call, let result):
            guard session.state != .disconnected, session.state != .error else { return [] }
            context.record(call, ok: result.ok, at: now)
            let finished = dispatcher.finish(call, result)
            let response = ToolResponse(id: call.id, name: call.name, result: finished)
            // The model gets the result even for an abandoned turn; the reply pipeline ignores it there.
            return [.provider(.toolResponses([response]))] + pipeline(.toolResult(turn, response), at: now)
        case .playback(let playback):
            switch playback {
            // Only the current reply epoch counts: a late event of a flushed reply changes nothing.
            case .replyStarted(let epoch) where epoch == arbiter.epoch: _ = arbiter.handle(.replyPlaying(true))
            case .replyFinished(let epoch) where epoch == arbiter.epoch: _ = arbiter.handle(.replyPlaying(false))
            case .replyStarted, .replyFinished: break
            case .guidanceStarted: _ = arbiter.handle(.guidanceSpeaking(true))
            case .guidanceEnded: _ = arbiter.handle(.guidanceSpeaking(false))
            }
            return releaseHeld()
        case .audioSession(let audio):
            let stops: [AgentEffect] = arbiter.handle(.audioSession(audio)).compactMap { effect in
                switch effect {
                case .flushPlayback(let epoch): return .flushPlayback(epoch)
                case .cancelRevoicing(let epoch): return .cancelRevoicing(epoch)
                case .bargeIn: return nil
                }
            }
            if !stops.isEmpty {
                if let turn = openTurn { silenced.insert(turn) }
                segmenter.reset()
            }
            return stops + releaseHeld()
        case .timer(.session(let timer)):
            sessionTimers[timer.kind] = nil
            return session(.timerFired(timer), at: now)
        case .timer(.pipeline(let timer)):
            pipelineTimers[timer.kind] = nil
            return pipeline(.timerFired(timer), at: now)
        case .navigation(let flags):
            navigation = flags
            return []
        }
    }

    // MARK: Session

    private mutating func session(_ input: SessionInput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for effect in session.handle(input, at: now) {
            switch effect {
            case .stateChanged(let state):
                view.chip = state.chip
                if state == .connecting || state == .listening { view.configError = nil }
                effects.append(.publish(view))
            case .connect(let connection, let resume):
                newSocket()
                effects.append(.provider(.connect(connection: connection, resume: resume)))
            case .close:
                // The turn in progress dies with its socket (contracts §5: Error/Closed drop the reply).
                effects += endTurn(at: now)
                effects.append(.provider(.close))
            case .schedule(let timer, let at):
                sessionTimers[timer.kind] = timer
                effects.append(.schedule(.session(timer), at: at))
            case .cancelTimer(let kind):
                if let timer = sessionTimers.removeValue(forKey: kind) { effects.append(.cancelTimer(.session(timer))) }
            case .showConfigError(let code):
                view.configError = code
                effects.append(.publish(view))
            case .diagnostic(let event): effects.append(.diagnostic(event))
            }
        }
        return effects
    }

    private mutating func newSocket() {
        openTurn = nil
        abandoned = []
        silenced = []
        abandonNextTurn = false
    }

    /// Stops what is still playing or being voiced of the open turn and closes it as cancelled.
    private mutating func endTurn(at now: NovaInstant) -> [AgentEffect] {
        guard let turn = openTurn else { return [] }
        openTurn = nil
        let stops = silenced.contains(turn) ? [] : stopReply(turn)
        return stops + pipeline(.turnClosed(turn, .cancelled), at: now)
    }

    /// Raises the epoch: playback flushed, revoicing cancelled, held clauses dropped.
    private mutating func stopReply(_ turn: TurnID) -> [AgentEffect] {
        silenced.insert(turn)
        segmenter.reset()
        heldClauses = []
        return arbiter.void().compactMap { effect in
            switch effect {
            case .flushPlayback(let epoch): return .flushPlayback(epoch)
            case .cancelRevoicing(let epoch): return .cancelRevoicing(epoch)
            case .bargeIn: return nil
            }
        }
    }

    // MARK: Reply

    private mutating func reply(_ event: RealtimeEvent, at now: NovaInstant) -> [AgentEffect] {
        if let turn = event.turn, abandoned.contains(turn) {
            // W3: the utterance was given up on; a late call is dropped and never executed, nothing is said.
            if case .toolCalls = event { return [.diagnostic(.lateToolResultDropped(turn: turn))] }
            if openTurn == turn, event.closesTurn { openTurn = nil }
            return []
        }
        switch event {
        case .userTranscript(let text, let isFinal):
            transcriptEpoch = speechOnsets
            if isFinal {
                transcript = text
                // The flushed transcript of an utterance already given up on does not revive it.
                return abandonNextTurn ? [] : pipeline(.driverUtterance(text), at: now)
            }
            transcript += text
            return []
        case .responseStarted(let turn):
            if abandonNextTurn {
                abandonNextTurn = false
                abandoned.insert(turn)
                return []
            }
            openTurn = turn
            segmenter.reset()
            view.subtitle = ""
            return [.newReply] + pipeline(.turnOpened(turn), at: now)
        case .replyText(let turn, let text):
            guard !silenced.contains(turn) else { return [] }
            return pipeline(.replyText(turn, text), at: now)
        case .replyAudio(let turn, let pcm):
            guard !silenced.contains(turn) else { return [] }
            return pipeline(.replyAudio(turn, pcm), at: now)
        case .toolCalls(let turn, let calls):
            var effects = pipeline(.toolCalls(turn, calls), at: now)
            for call in calls {
                let guardContext = GuardContext(requestText: transcript, currentEpoch: transcriptEpoch,
                                                capabilityEpoch: speechOnsets, navigating: navigation.navigating,
                                                guidanceRunning: navigation.guidanceRunning,
                                                listOpen: navigation.listOpen)
                let referents = context
                switch dispatcher.decide(call, context: guardContext,
                                         clarify: { referents.clarify($0, at: now) }) {
                case .execute(let running):
                    effects.append(.startTool(turn, running))
                case .refuse(let result):
                    let response = ToolResponse(id: call.id, name: call.name, result: result)
                    effects.append(.diagnostic(.toolRefused(code: result.code ?? .invalidValue)))
                    effects.append(.provider(.toolResponses([response])))
                    effects += pipeline(.toolResult(turn, response), at: now)
                }
            }
            return effects
        case .toolCallCancellation(let ids):
            return ids.map { .cancelTool($0) }
        case .audioDone(let turn):
            return pipeline(.audioDone(turn), at: now)
        case .interrupted(let turn, _):
            // Server-side interruption: whatever of this reply is still queued must not play.
            let stops = openTurn == turn && !silenced.contains(turn) ? stopReply(turn) : []
            if openTurn == turn { openTurn = nil }
            return stops + pipeline(.turnClosed(turn, .cancelled), at: now)
        case .responseDone(let turn, let outcome):
            if openTurn == turn { openTurn = nil }
            var effects = pipeline(.turnClosed(turn, outcome), at: now)
            // The last half clause is spoken only for a reply that completed and still may be heard.
            if outcome == .completed, !silenced.contains(turn), let rest = segmenter.flush() {
                effects += speak([rest])
            }
            return effects
        case .setupComplete, .resumptionHandle, .goAway, .failed, .closed:
            return []
        }
    }

    private mutating func pipeline(_ input: PipelineInput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for output in pipeline.handle(input, at: now) {
            switch output {
            case .speechText(let turn, let text):
                guard !silenced.contains(turn) else { continue }
                view.subtitle += text
                effects.append(.publish(view))
                effects += speak(segmenter.append(text))
            case .speechAudio:
                // Revoicing is on (ADR-016): the provider's own audio is never played.
                break
            case .voided(let turn):
                view.subtitle = ""
                effects += silenced.contains(turn) ? [] : stopReply(turn)
                effects.append(.publish(view))
            case .sendCorrection(let reason):
                effects.append(.provider(.text([TextTurn(role: .user, text: reason.instruction)], turnComplete: true)))
            case .reask(let text):
                effects.append(.provider(.text([TextTurn(role: .user, text: text)], turnComplete: true)))
            case .gaveUp:
                if let turn = openTurn {
                    abandoned.insert(turn)
                    effects += silenced.contains(turn) ? [] : stopReply(turn)
                    openTurn = nil
                } else {
                    abandonNextTurn = true
                }
            case .schedule(let timer, let at):
                pipelineTimers[timer.kind] = timer
                effects.append(.schedule(.pipeline(timer), at: at))
            case .cancelTimer(let kind):
                if let timer = pipelineTimers.removeValue(forKey: kind) { effects.append(.cancelTimer(.pipeline(timer))) }
            case .diagnostic(let event):
                effects.append(.diagnostic(event))
            }
        }
        return effects
    }

    /// Clauses go to the revoicer only while the arbiter says PLAY; HOLD keeps them, DROP discards them.
    private mutating func speak(_ clauses: [String]) -> [AgentEffect] {
        switch arbiter.reply {
        case .play: return clauses.map { .speak($0) }
        case .hold:
            heldClauses += clauses
            return []
        case .drop:
            return []
        }
    }

    private mutating func releaseHeld() -> [AgentEffect] {
        guard !heldClauses.isEmpty else { return [] }
        switch arbiter.reply {
        case .play:
            let clauses = heldClauses
            heldClauses = []
            return clauses.map { .speak($0) }
        case .hold: return []
        case .drop:
            heldClauses = []
            return []
        }
    }
}

extension RealtimeEvent {
    /// The provider turn an event belongs to, if any.
    var turn: TurnID? {
        switch self {
        case .responseStarted(let t), .replyText(let t, _), .replyAudio(let t, _), .toolCalls(let t, _),
             .audioDone(let t), .interrupted(let t, _), .responseDone(let t, _):
            t
        case .setupComplete, .userTranscript, .toolCallCancellation, .resumptionHandle, .goAway, .failed, .closed:
            nil
        }
    }

    var closesTurn: Bool {
        switch self {
        case .interrupted, .responseDone: true
        default: false
        }
    }
}
