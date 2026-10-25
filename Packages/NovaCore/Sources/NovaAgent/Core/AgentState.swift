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
}

public enum AgentTimer: Sendable, Hashable {
    case session(SessionTimer)
    case pipeline(PipelineTimer)
}

public enum ProviderCommand: Sendable, Hashable {
    case connect(resume: String?)
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
    private var segmenter = ClauseSegmenter()
    /// Turns of an utterance the pipeline gave up on (W3): their late calls and words are dropped.
    private var abandoned: Set<TurnID> = []
    /// Set by the give-up; the next turn to open still belongs to that utterance.
    private var abandonNextTurn = false
    private var openTurn: TurnID?
    /// Partial driver transcript of the current utterance, and the speech-onset count (guard epochs).
    private var transcript = ""
    private var speechOnsets = 0
    private var transcriptEpoch = 0
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
            guard connection == session.connection else { return [] }
            return session(.realtime(realtime, connection: connection), at: now) + reply(realtime, at: now)
        case .speechStarted(let recentSpeech):
            speechOnsets += 1
            var effects: [AgentEffect] = []
            for effect in arbiter.handle(.speechStarted(recentSpeech: recentSpeech)) {
                switch effect {
                case .flushPlayback(let epoch): effects.append(.flushPlayback(epoch))
                case .cancelRevoicing(let epoch):
                    segmenter.reset()
                    effects.append(.cancelRevoicing(epoch))
                case .bargeIn(let qualified): effects += session(.bargeIn(qualified: qualified), at: now)
                }
            }
            return effects + session(.speechStarted, at: now)
        case .speechStopped:
            // The no-answer clock (W3) starts when the driver stops, with what we heard so far.
            let heard = transcript
            transcript = ""
            abandonNextTurn = false
            return session(.speechStopped, at: now) + pipeline(.driverUtterance(heard), at: now)
        case .toolFinished(let turn, let call, let result):
            let finished = dispatcher.finish(call, result)
            let response = ToolResponse(id: call.id, name: call.name, result: finished)
            // The model gets the result even for an abandoned turn; the reply pipeline ignores it there.
            return [.provider(.toolResponses([response]))] + pipeline(.toolResult(turn, response), at: now)
        case .playback(let playback):
            switch playback {
            case .replyStarted: _ = arbiter.handle(.replyPlaying(true))
            case .replyFinished: _ = arbiter.handle(.replyPlaying(false))
            case .guidanceStarted: _ = arbiter.handle(.guidanceSpeaking(true))
            case .guidanceEnded: _ = arbiter.handle(.guidanceSpeaking(false))
            }
            return []
        case .audioSession(let audio):
            return arbiter.handle(.audioSession(audio)).compactMap { effect in
                switch effect {
                case .flushPlayback(let epoch): return .flushPlayback(epoch)
                case .cancelRevoicing(let epoch): return .cancelRevoicing(epoch)
                case .bargeIn: return nil
                }
            }
        case .timer(.session(let timer)):
            sessionTimers[timer.kind] = nil
            return session(.timerFired(timer), at: now)
        case .timer(.pipeline(let timer)):
            pipelineTimers[timer.kind] = nil
            return pipeline(.timerFired(timer), at: now)
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
            case .connect(_, let resume): effects.append(.provider(.connect(resume: resume)))
            case .close:
                effects.append(.provider(.close))
                effects += closeTurn(at: now)
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

    /// A closed socket ends the turn in progress: nothing of it plays later (contracts §5, R4 on Error/Closed).
    private mutating func closeTurn(at now: NovaInstant) -> [AgentEffect] {
        guard let turn = openTurn else { return [] }
        openTurn = nil
        return pipeline(.turnClosed(turn, .cancelled), at: now)
    }

    // MARK: Reply

    private mutating func reply(_ event: RealtimeEvent, at now: NovaInstant) -> [AgentEffect] {
        if let turn = event.turn, abandoned.contains(turn) {
            // W3: the utterance was given up on; a late call is dropped and never executed, nothing is said.
            if case .toolCalls = event { return [.diagnostic(.lateToolResultDropped(turn: turn))] }
            return []
        }
        switch event {
        case .userTranscript(let text, let isFinal):
            transcriptEpoch = speechOnsets
            if isFinal {
                transcript = ""
                abandonNextTurn = false
                return pipeline(.driverUtterance(text), at: now)
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
            return pipeline(.replyText(turn, text), at: now)
        case .replyAudio(let turn, let pcm):
            return pipeline(.replyAudio(turn, pcm), at: now)
        case .toolCalls(let turn, let calls):
            var effects = pipeline(.toolCalls(turn, calls), at: now)
            for call in calls {
                let context = GuardContext(requestText: transcript, currentEpoch: transcriptEpoch,
                                           capabilityEpoch: speechOnsets)
                switch dispatcher.decide(call, context: context) {
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
            openTurn = nil
            return pipeline(.turnClosed(turn, .cancelled), at: now)
        case .responseDone(let turn, let outcome):
            openTurn = nil
            return pipeline(.turnClosed(turn, outcome), at: now)
        case .setupComplete, .resumptionHandle, .goAway, .failed, .closed:
            return []
        }
    }

    private mutating func pipeline(_ input: PipelineInput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for output in pipeline.handle(input, at: now) {
            switch output {
            case .speechText(_, let text):
                view.subtitle += text
                effects.append(.publish(view))
                effects += segmenter.append(text).map { .speak($0) }
            case .speechAudio:
                // Revoicing is on (ADR-016): the provider's own audio is never played.
                break
            case .voided:
                segmenter.reset()
                view.subtitle = ""
                effects += arbiter.void().compactMap { effect in
                    switch effect {
                    case .flushPlayback(let epoch): return .flushPlayback(epoch)
                    case .cancelRevoicing(let epoch): return .cancelRevoicing(epoch)
                    case .bargeIn: return nil
                    }
                }
                effects.append(.publish(view))
            case .sendCorrection(let reason):
                effects.append(.diagnostic(.correctionSent))
                effects.append(.provider(.text([TextTurn(role: .user, text: reason.instruction)], turnComplete: true)))
            case .reask(let text):
                effects.append(.provider(.text([TextTurn(role: .user, text: text)], turnComplete: true)))
            case .gaveUp:
                if let turn = openTurn { abandoned.insert(turn) } else { abandonNextTurn = true }
            case .schedule(let timer, let at):
                pipelineTimers[timer.kind] = timer
                effects.append(.schedule(.pipeline(timer), at: at))
            case .cancelTimer(let kind):
                if let timer = pipelineTimers.removeValue(forKey: kind) { effects.append(.cancelTimer(.pipeline(timer))) }
            case .diagnostic(let event):
                effects.append(.diagnostic(event))
            }
        }
        if case .turnClosed = input, let rest = segmenter.flush() { effects.append(.speak(rest)) }
        return effects
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
}
