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
    /// Amap gave a guidance sentence (F-14, `playNaviSoundString:`).
    case guidancePrompt(String, GuidanceID)
    /// `nova_guidance_relay/assistant_speaks_guidance` changed.
    case guidanceRelay(enabled: Bool)
    /// Distance to the next manoeuvre while navigating (R6a); nil when unknown.
    case manoeuvreDistance(meters: Int?)
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
    /// Relay deadline or bracket of a guidance sentence (F-14).
    case guidance(GuidanceID)
    /// The arbiter asked to be re-evaluated (R6a hold end, uplink tail, R0, 20 s cap).
    case arbiter(NovaInstant)
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

    public init() {}
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
    /// Speak a guidance sentence with the fallback voice on the guidance lane (F-14). The sink always
    /// answers with `playback(.guidanceStarted)` / `.guidanceEnded` for `id`, or `.guidanceEnded` alone
    /// when the sentence could not be rendered, so the relay moves on.
    case speakGuidance(String, GuidanceID)
    /// The uplink may send (F-08 uplink rules). The gate force-closes while false.
    case uplink(open: Bool)
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
    /// F-14 relay and the model turn that reads its PENDING sentence.
    public private(set) var relay = GuidanceRelay()
    private var relayEnabled = true
    /// Sent to the model, its reading turn not opened yet.
    private var relayAwaiting: GuidanceID?
    /// The open turn reads guidance `id`; it bypasses the claim pipeline (nothing is claimed or asked).
    private var relayTurn: (turn: TurnID, id: GuidanceID)?
    /// The relay gave the awaited sentence to the fallback voice: its late reading turn is silenced.
    private var silenceNextRelayTurn = false
    private var runningTools = 0
    private var driverSpeaking = false
    private var uplinkOpen = true
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
            driverSpeaking = true
            arbiter.driverSpeech(true)
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
            return effects + session(.speechStarted, at: now) + arbiterChanged(at: now)
        case .speechStopped:
            driverSpeaking = false
            arbiter.driverSpeech(false)
            // R6: she may answer this utterance while navigating.
            arbiter.driverSpoke(at: now)
            // The no-answer clock (W3) starts when the driver stops, with what we heard so far.
            return session(.speechStopped, at: now) + pipeline(.driverUtterance(transcript), at: now)
                + arbiterChanged(at: now)
        case .toolFinished(let turn, let call, let result):
            runningTools = max(runningTools - 1, 0)
            guard session.state != .disconnected, session.state != .error else { return [] }
            // R6: the answer to a tool the driver asked for may be spoken (PROPOSED: a navigation start
            // can take longer than the 10 s window after the utterance).
            arbiter.driverSpoke(at: now)
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
            case .guidanceStarted:
                arbiter.guidance(true, at: now)
            case .guidanceEnded(let id):
                arbiter.guidance(false, at: now)
                return relayOutputs(relay.fallbackFinished(id, at: now, conditions: relayConditions), at: now)
                    + arbiterChanged(at: now)
            }
            return arbiterChanged(at: now)
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
            return stops + arbiterChanged(at: now)
        case .timer(.session(let timer)):
            sessionTimers[timer.kind] = nil
            return session(.timerFired(timer), at: now)
        case .timer(.pipeline(let timer)):
            pipelineTimers[timer.kind] = nil
            return pipeline(.timerFired(timer), at: now)
        case .timer(.guidance(let id)):
            return relayOutputs(relay.timerFired(id, at: now, conditions: relayConditions), at: now)
                + arbiterChanged(at: now)
        case .timer(.arbiter):
            return arbiterChanged(at: now)
        case .navigation(let flags):
            let tripEnded = navigation.navigating && !flags.navigating
            navigation = flags
            arbiter.setNavigating(flags.navigating)
            let ended = tripEnded ? relayOutputs(relay.tripEnded(), at: now) : []
            return ended + arbiterChanged(at: now)
        case .guidancePrompt(let text, let id):
            return relayOutputs(relay.enqueue(text, id: id, at: now, conditions: relayConditions), at: now)
        case .guidanceRelay(let enabled):
            relayEnabled = enabled
            return []
        case .manoeuvreDistance(let meters):
            arbiter.setManoeuvreDistance(meters)
            return arbiterChanged(at: now)
        }
    }

    // MARK: Guidance relay (F-14) and arbiter re-evaluation (F-08)

    private var relayConditions: GuidanceConditions {
        let connected: Bool = switch session.state {
        case .listening, .userSpeaking, .thinking, .speaking: true
        default: false
        }
        return GuidanceConditions(enabled: relayEnabled, connected: connected, capable: true,
                                  driverSpeaking: driverSpeaking, responseOpen: openTurn != nil,
                                  workPending: runningTools > 0, focusHeld: arbiter.focus == .held)
    }

    private mutating func relayOutputs(_ outputs: [GuidanceRelayOutput], at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for output in outputs {
            switch output {
            case .sendToModel(let id, let prompt):
                relayAwaiting = id
                silenceNextRelayTurn = false
                effects.append(.provider(.text([TextTurn(role: .user, text: prompt)], turnComplete: true)))
            case .speakFallback(let id, let text, _):
                // Guidance never overlaps her reply (F-14 §10): a reply still sounding is cut (PROPOSED,
                // guidance is the safety-relevant voice), and what is left of it is held by R1.
                if arbiter.replyPlaying, let turn = openTurn, !silenced.contains(turn) { effects += stopReply(turn) }
                effects.append(.speakGuidance(text, id))
            case .silenceAssistant(let id):
                if let reading = relayTurn, reading.id == id {
                    relayTurn = nil
                    if !silenced.contains(reading.turn) { effects += stopReply(reading.turn) }
                } else if relayAwaiting == id {
                    silenceNextRelayTurn = true
                }
            case .schedule(let id, let at):
                effects.append(.schedule(.guidance(id), at: at))
            case .fidelityStrike:
                break
            }
        }
        return effects
    }

    /// Re-evaluates what depends on time or on the arbiter's inputs: held clauses and the uplink.
    private mutating func arbiterChanged(at now: NovaInstant) -> [AgentEffect] {
        var effects = releaseHeld(at: now)
        let (open, wake) = arbiter.uplink(at: now)
        if open != uplinkOpen {
            uplinkOpen = open
            effects.append(.uplink(open: open))
        }
        if let wake { effects.append(.schedule(.arbiter(wake), at: wake)) }
        return effects
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
            // Her own guidance reading heard back through the microphone is not the driver (F-14 §8).
            if isFinal, relay.isEcho(text, at: now) { return [] }
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
            arbiter.newReply()
            if let id = relayAwaiting {
                relayAwaiting = nil
                if silenceNextRelayTurn {
                    // The deadline passed: the fallback voice has this sentence. Nothing of it is heard.
                    silenceNextRelayTurn = false
                    silenced.insert(turn)
                    relayTurn = (turn, id)
                    return []
                }
                relayTurn = (turn, id)
                view.subtitle = ""
                return [.newReply] + relayOutputs(relay.assistantStarted(at: now), at: now)
            }
            view.subtitle = ""
            return [.newReply] + pipeline(.turnOpened(turn), at: now)
        case .replyText(let turn, let text):
            guard !silenced.contains(turn) else { return [] }
            if relayTurn?.turn == turn {
                // A guidance reading: spoken as given, judged afterwards for fidelity, never a claim.
                relay.assistantText(text)
                view.subtitle += text
                return [.publish(view)] + speak(segmenter.append(text), at: now)
            }
            return pipeline(.replyText(turn, text), at: now)
        case .replyAudio(let turn, let pcm):
            guard !silenced.contains(turn), relayTurn?.turn != turn else { return [] }
            return pipeline(.replyAudio(turn, pcm), at: now)
        case .toolCalls(let turn, let calls) where relayTurn?.turn == turn:
            // A guidance reading never acts: every call of it is refused and nothing runs.
            return [.provider(.toolResponses(calls.map {
                ToolResponse(id: $0.id, name: $0.name, result: .failure(.actionNotAllowed))
            }))]
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
                    runningTools += 1
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
            if relayTurn?.turn == turn { return [] }
            return pipeline(.audioDone(turn), at: now)
        case .interrupted(let turn, _) where relayTurn?.turn == turn,
             .responseDone(let turn, _) where relayTurn?.turn == turn:
            relayTurn = nil
            if openTurn == turn { openTurn = nil }
            var effects: [AgentEffect] = []
            if case .responseDone(_, .completed) = event, !silenced.contains(turn), let rest = segmenter.flush() {
                effects += speak([rest], at: now)
            }
            return effects + relayOutputs(relay.assistantFinished(at: now, conditions: relayConditions), at: now)
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
                effects += speak([rest], at: now)
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
                effects += speak(segmenter.append(text), at: now)
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
    private mutating func speak(_ clauses: [String], at now: NovaInstant) -> [AgentEffect] {
        guard !clauses.isEmpty else { return [] }
        heldClauses += clauses
        return releaseHeld(at: now)
    }

    private mutating func releaseHeld(at now: NovaInstant) -> [AgentEffect] {
        guard !heldClauses.isEmpty else { return [] }
        let (decision, wake) = arbiter.decide(at: now, exempt: relayTurn != nil && relayTurn?.turn == openTurn)
        switch decision {
        case .play:
            let clauses = heldClauses
            heldClauses = []
            arbiter.markReplyStarted()
            return clauses.map { .speak($0) }
        case .hold:
            return wake.map { [.schedule(.arbiter($0), at: $0)] } ?? []
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
