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
    /// Local VAD (F-04). `recentSpeech` is `SpeechUplinkGate.hasRecentSpeech` at onset. `sentToModel` is the
    /// gate's one decision (F-04 §14): a not-sent utterance is no driver turn, owes no answer, starts no clock.
    case speechStarted(recentSpeech: Bool, sentToModel: Bool = true)
    case speechStopped
    /// F-05a: the driver's words chosen by `TranscriptSelector`. Once one arrives, Gemini's own
    /// `userTranscript` is ignored (the selector already had it).
    case driverWords(DriverWords)
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
    /// The media lane's verified now-playing transitions (music.md truthfulness contract).
    case musicPlaying(Bool)
    /// A tap on the screen (I-6): it enters the same dispatcher and executor as the voice call.
    case ui(UIIntent)
    /// F-08 §14 item 4 (T-022a): the on-phone keyword spotter heard a stop phrase while she talked.
    case stopPhraseSpotted(StopPhraseHit)
    /// F-08 §17 item 11 (T-022e): the live check confirmed new words while she talked (setting on). Her reply is
    /// flushed; the released utterance that follows (`speechStarted(sentToModel: true)`, whose activityStart cancels
    /// her turn at Gemini) is the new question. Unlike a stop phrase, nothing is abandoned.
    case bargeInStop
    /// F-24 §14 item 1: `NetworkPathWatcher` says the path went away (false) or came back (true).
    case network(available: Bool)
    /// F-18 §21 item 1 (T-046i): the current destination's cleaned name, or nil when there is none.
    case destination(String?)
    /// F-21 §16 item 4 (T-034c): a tone picked in 设置 while the session runs (the tool's own write is ignored).
    case speakingStyle(SpeakingStyle)
}

/// Screen actions (ios-architecture §11.1). Each becomes the tool call the voice path would make.
public enum UIIntent: Sendable, Hashable {
    /// Row `row` (0-based) of the choice list.
    case choose(row: Int)
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
    /// F-08 §15 item 1: 1 s after the stop's empty activity; no `interrupted` by then is logged.
    case stopSync(NovaInstant)
    /// F-09a §3 item 3 (T-017a): a comfort call or her reply waited this long for the utterance's area.
    case area(NovaInstant)
}

public enum ProviderCommand: Sendable, Hashable {
    /// Open socket `connection`; its events come back tagged with it.
    /// F-21 §16 (T-034c): `instruction` is the setup's system instruction (nil: the shell's session config);
    /// `updateAtSetup` goes out as `contextUpdate` at `setupComplete`, before any audio or text (item 5).
    case connect(connection: Generation, resume: String?, instruction: String? = nil, updateAtSetup: String? = nil)
    case close
    case toolResponses([ToolResponse])
    case text([TextTurn], turnComplete: Bool)
    /// F-08 §15 item 1: `activityStart` then `activityEnd` with no audio between, so Gemini cancels its reply.
    case interruptReply
    /// F-21 §16 item 1 (T-034c): her whole new system instruction on the open socket.
    case contextUpdate(String)
}

/// What the UI shows (contracts/voice-agent.md §1). A snapshot, not product state.
public struct AgentViewState: Sendable, Hashable {
    public var chip: AssistantChip = .idle
    /// The judged reply text of the current turn (小诺's bubble).
    public var subtitle = ""
    /// F-05a §16 item 1 (T-016n): the driver's line, from Gemini's input transcript only, checked by `ScreenLanguage`
    /// (「（没听清）」 when hidden, empty while waiting or with no Gemini text). The local text never reaches it.
    public var driverLine = ""
    /// Terminal error: the settings message for this code.
    public var configError: RealtimeErrorCode?
    /// F-24 §14 item 3: no network; the chip reads 等待网络… instead of PROCESSING.
    public var waitingForNetwork = false
    /// F-24 §14 item 4: the offline cap ended the session; the chip reads `SessionEndedChip` (F-24 §15 item 6) until a start.
    public var offlineEnded = false

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
    /// F-07 §15 item 3 (T-020b): judged Gemini audio of `turn` for the reply lane (only without revoicing).
    case playReplyAudio(TurnID, PCMBuffer)
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
    /// F-05a §13 item 5: text that failed the screen check (once per text). The sink logs only the kind.
    case screenHidden(ScreenTextKind, String)
    /// F-24 §15 item 4 (T-016j): the session gave up or hit the offline cap; the shell keeps this handle in
    /// memory for the next start. Never logged or persisted (I-7). F-21 §16 item 5 (T-034c): `instruction` is the
    /// one the handle's chain began with, kept beside it in memory.
    case keepResumption(String?, instruction: String? = nil)
    /// F-05a §15 item 7 (T-016m): the language check's record and log line; no words (I-8).
    case languageLine(ReplyLanguageLine)
    /// F-21 §16 item 8 (T-034c): `style-update …` record and log line; codes and numbers only (I-8).
    case styleUpdateLine(StyleUpdateLine)
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
    /// F-08 §16 item 3: since the last stop no utterance was sent; a turn Gemini opens now answers nothing of the
    /// driver's and is not spoken (a guidance reading the relay asked for still is).
    private var noUtteranceSinceStop = false
    /// Turns the driver barged into, or that were voided (W2): nothing more of them is spoken, even
    /// before Gemini's `interrupted` arrives.
    private var silenced: Set<TurnID> = []
    /// Driver words of the current utterance, kept from speech onset until the next onset, so the
    /// guards still read them when the tool call arrives.
    private var transcript = ""
    private var speechOnsets = 0
    private var transcriptEpoch = 0
    /// Utterances closed by the uplink gate (F-04a `activityEnd`): F-15a driver turns, counted from audio.
    private var closedTurns = 0
    /// F-16 §14 item 5 (T-042c): the same count, for the navigation flow's CONFIRM_FIRST (never a transcript).
    public var closedDriverTurns: Int { closedTurns }
    /// F-04 §14 (T-004i): the open utterance was sent to the model (the gate's decision, followed here).
    private var utteranceSent = true
    /// F-08 §14 items 4, 5, 7: every utterance the gate opened (sent or not), when the last one started and ended,
    /// whether one is open, and the last stop, so a second hit (either source) within 1 s or in the same
    /// utterance is ignored.
    private var utterances = 0
    private var utteranceOpen = false
    private var lastOnsetAt: NovaInstant?
    private var lastSpeechEndAt: NovaInstant?
    private var lastStopAt: NovaInstant?
    private var stopUtterance: Int?
    private var stopSource: StopPhraseSource?
    /// An utterance heard during her reply with no stop yet, and that reply's epoch; logged as a miss when that
    /// reply ends.
    private var missCandidate: (utterance: Int, epoch: Epoch)?
    /// F-05a: `TranscriptSelector` feeds the driver's words (`.driverWords`); Gemini's transcript is not used.
    private var selectorOwnsWords = false
    /// Clauses waiting while the arbiter holds the reply (R1 guidance, R5 transient loss).
    /// `.speak` clauses, or `.playReplyAudio` without revoicing, waiting for the arbiter's PLAY.
    private var heldClauses: [AgentEffect] = []
    /// F-07 §15 item 3: false for Gemini 原声 (her voice is Gemini's own audio, judged by the same claim gate).
    public private(set) var revoicing = true
    /// F-07 §15 item 8: Gemini audio of the open turn sent to the reply lane: when it started, and how long it is.
    private var turnAudio: (turn: TurnID, since: NovaInstant, ms: Int)?
    /// F-14 relay and the model turn that reads its PENDING sentence.
    public private(set) var relay = GuidanceRelay()
    private var relayEnabled = true
    /// Sent to the model on this socket, its reading turn not opened yet.
    private var relayAwaiting: GuidanceID?
    /// Every turn of this socket that answered a guidance prompt. They bypass the claim pipeline and never
    /// act (nothing is claimed or asked). TurnIDs restart per socket, so this is cleared with the socket.
    private var relayTurns: [TurnID: GuidanceID] = [:]
    /// The reading the relay is waiting on (its ASSISTANT phase).
    private var relayReading: TurnID?
    /// The relay gave the awaited sentence to the fallback voice: its late reading turn is silenced.
    private var silenceNextRelayTurn = false
    /// The model owes an answer (the driver stopped, or we sent a correction or re-ask): the next turn is
    /// that answer, so no guidance prompt may be sent until it opens (F-14 RESPONSE_OPEN).
    private var answerOwed = false
    /// A turn opened after a prompt while the driver had spoken since: Gemini may have dropped the reading
    /// (its server VAD interrupts a generation that has not opened a turn), so the turn is classified by its
    /// first words or call (`classify`).
    private var unclassified: (turn: TurnID, id: GuidanceID)?
    /// Words of the unclassified turn so far, replayed once it is classified.
    private var unclassifiedText = ""
    /// The sentence of the prompt in flight, kept after the relay let it go (deadline fallback), so a
    /// late reading is still recognised.
    private var awaitingText: String?
    /// A fallback sentence waiting for her reply audio to drain (never cut a sentence just sent to Azure).
    private var waitingFallback: (text: String, id: GuidanceID, since: NovaInstant)?
    /// How long a fallback waits for trailing reply audio before cutting it (PROPOSED).
    static let fallbackWaitMax = NovaDuration.milliseconds(4000)
    private(set) var runningTools = 0
    /// F-18 §16 item 7 (T-046d): running `web_search` calls and their turn; a barge-in or the turn's interruption
    /// cancels them, and a cancelled one sends no result.
    private var searchCalls: [CallID: TurnID] = [:]
    /// F-18 §27 (T-020c): running NON_BLOCKING calls and when each was sent to the tool.
    private var asyncCalls: [CallID: (tool: AsyncTool, at: NovaInstant)] = [:]
    /// Calls that came from a tap: their result goes to the model as a note to announce, not as a
    /// tool response (the model never issued them).
    private var uiCalls: Set<CallID> = []
    private var uiCount = 0
    private var driverSpeaking = false
    private var uplinkOpen = true
    /// Session timers by kind, so `cancelTimer` can name the pending one.
    private var sessionTimers: [SessionTimer.Kind: SessionTimer] = [:]
    /// F-08 §15: when the stop's empty activity went out; cleared by the stopped reply's `interrupted` or after 1 s.
    private var stopSyncAt: NovaInstant?
    /// The turn the stop cut; only its `interrupted` closes the stop sync.
    private var stopSyncTurn: TurnID?
    private var pipelineTimers: [PipelineTimer.Kind: PipelineTimer] = [:]
    /// F-05a §15 item 5: fallback lines said; their guidance ids count down from the top, clear of Amap's.
    private var fallbackLines: UInt64 = 0
    /// F-05a §15 item 1 and §16 item 2: the detector, also for a Latin-only driver line.
    private var detector: any LanguageIdentifier = NoLanguageIdentifier()
    /// F-05a §16 item 1: Gemini's input transcript of the current utterance (partials are deltas).
    private var geminiHeard = ""

    /// F-18 §21 item 2 (T-046i): silent destination notes (on with the search setting; off sends none).
    private var destinationNotes = false
    private var destination: String?
    /// The note waiting for an idle moment: `.some(name)` or `.some(nil)` for the end note. Only the latest is kept.
    private var pendingNote: String??
    /// What the last sent note said (`.some(nil)` = the end note), and whether a turn completed since.
    private var lastNote: String??
    private var turnSinceNote = false
    /// A (re)connect: the note goes again even with no turn since.
    private var noteOnConnect = false

    // MARK: F-09a (T-017a) state

    /// A closed sent utterance and its area (nil while the local final is awaited).
    private struct AreaUtterance {
        let index: Int
        var area: CarRequestArea?
        var comfortOk = false
        /// Model turns opened for it (after it closed, before the next one closed); not guidance readings.
        var turns: Set<TurnID> = []
    }
    /// On when the shell feeds the phone recognizer's words (`.driverWords`); off, every area is unknown (today's behaviour).
    private var carAreas = false
    /// The newest closed utterance (the one a call belongs to, §3 item 3) and the one before it (§2 rule 4).
    private var areaCurrent: AreaUtterance?
    private var areaPrevious: AreaUtterance?
    /// A local final that came while its utterance was still open: (speech onset, text; nil = unclear).
    private var areaEarlyFinal: (onset: Int, text: String?)?
    /// Comfort calls waiting for the area, already validated by the dispatcher.
    /// `utterance`: the closed-utterance index the call belongs to; `until` is nil while that utterance is still open.
    private var areaHeldCalls: [(turn: TurnID, call: ToolCall, utterance: Int, until: NovaInstant?)] = []
    /// Her judged reply waiting for the area (her turn's text and audio), and when that wait ends.
    private var areaHeldReply: [PipelineOutput] = []
    private var areaHeldUntil: NovaInstant?
    /// A turn whose reply was held closed meanwhile: whether it completed.
    private var areaHeldClosed: [TurnID: Bool] = [:]
    /// Turns Gemini opened while a sent utterance was still open: they answer that utterance (attached at its close).
    private var areaEarlyTurns: Set<TurnID> = []
    /// Comfort calls running, by the utterance they belong to (for `comfortOk`).
    private var comfortCalls: [CallID: Int] = [:]

    /// F-21 §16 (T-034c): when her new tone goes to Gemini; nil when the shell did not turn it on.
    public private(set) var tones: StyleUpdates?

    public init() {}

    /// F-18 §15 item 5: the session's no-answer times (web search on waits longer before the re-ask).
    /// F-18 §21 item 2: `destinationNotes` sends the destination notes.
    /// `resume`: F-24 §15 item 5, what the last give-up kept for this session's first connect.
    /// `revoicing`: F-07 §15 item 3, false when her voice is Gemini's own audio.
    /// `languageIdentifier`: F-05a §15 item 1, the detector her reply's language is checked with.
    /// `carRequestAreas`: F-09a (T-017a), comfort tools only for car requests and tired utterances silenced; the shell
    /// turns it on because it feeds the phone recognizer's words.
    /// `styleUpdates`: F-21 §16 (T-034c), the session's base, tone and model; with it a new tone reaches Gemini on the
    /// open connection, and every setup carries the current tone. Nil: the tone applies at the next session (as before).
    public init(truthfulness: TruthfulnessTuning, destinationNotes: Bool = false, resume: SessionResume? = nil,
                revoicing: Bool = true, languageIdentifier: any LanguageIdentifier = NoLanguageIdentifier(),
                carRequestAreas: Bool = false, styleUpdates: StyleUpdates? = nil) {
        if var tone = styleUpdates {
            // F-21 §16 item 5: a give-up handle's chain began with the instruction kept beside it.
            if let resume, resume.handle != nil { tone.resumeChain(original: resume.instruction) }
            tones = tone
        }
        carAreas = carRequestAreas
        pipeline = DriverTurnPipeline(tuning: truthfulness, streamsCleanAudio: !revoicing, detector: languageIdentifier)
        detector = languageIdentifier
        self.revoicing = revoicing
        if let resume { session = VoiceSession(resume: resume) }
        self.destinationNotes = destinationNotes
    }

    /// F-18 §21 item 2: the note texts.
    public static func destinationNote(_ name: String?) -> String {
        guard let name else { return "[系统] 导航已结束，现在没有目的地。这句不用回答。" }
        return "[系统] 现在的导航目的地是「\(name)」。司机没说清地点时，指的可能是这里。这句不用回答。"
    }

    public mutating func handle(_ event: AgentEvent, at now: NovaInstant) -> [AgentEffect] {
        let effects = dispatch(event, at: now)
        guard destinationNotes else { return effects }
        noteTriggers(event)
        return effects + flushNote()
    }

    /// §21 item 2 "When": a destination change, a completed turn, or a (re)connect with a destination.
    private mutating func noteTriggers(_ event: AgentEvent) {
        switch event {
        case .destination(let name):
            guard name != destination else { return }
            let had = destination != nil
            destination = name
            if let name { pendingNote = .some(name) } else if had { pendingNote = .some(nil) }
        case .realtime(.responseDone(_, .completed), _):
            // Only a completed turn counts (an interrupted one is no new exchange).
            turnSinceNote = true
            if let destination { pendingNote = .some(destination) }
        case .realtime(.setupComplete, _):
            if let destination {
                pendingNote = .some(destination)
                noteOnConnect = true
            }
        default:
            break
        }
    }

    /// §21 item 2 "Only when idle": connected, no reply open, no answer owed, no tool running, driver not
    /// speaking, no guidance prompt waiting. A note never interrupts a reply.
    private var noteIdle: Bool {
        session.state == .listening && openTurn == nil && !answerOwed && runningTools == 0 && !driverSpeaking
            && !utteranceOpen && relayAwaiting == nil && unclassified == nil
    }

    private mutating func flushNote() -> [AgentEffect] {
        guard let pending = pendingNote, noteIdle else { return [] }
        pendingNote = nil
        // No second note when nothing happened since the last one; the end note goes once.
        // The end note goes once, and only after a destination note was sent.
        if pending == nil, (lastNote ?? nil) == nil { return [] }
        if let name = pending, lastNote == .some(name), !turnSinceNote, !noteOnConnect { return [] }
        lastNote = .some(pending)
        turnSinceNote = false
        noteOnConnect = false
        // `turnComplete: false`, never `realtimeInput` (§21 item 2, item 8 is the risk).
        return [.provider(.text([TextTurn(role: .user, text: Self.destinationNote(pending))], turnComplete: false)),
                .diagnostic(.destinationNote)]
    }

    private mutating func dispatch(_ event: AgentEvent, at now: NovaInstant) -> [AgentEffect] {
        switch event {
        case .destination:
            return []
        case .speakingStyle(let style):
            // F-21 §16 item 4: at once when she is not replying, else when her reply ends.
            guard var tone = tones else { return [] }
            let step = tone.settingsChanged(style, replying: openTurn != nil, at: now)
            tones = tone
            return Self.effects(step)
        case .start:
            return session(.start, at: now)
        case .stop:
            return session(.stop, at: now)
        case .network(let available):
            var effects = session(available ? .networkRestored : .networkLost, at: now)
            if view.waitingForNetwork != session.waitingForNetwork {
                view.waitingForNetwork = session.waitingForNetwork
                effects.append(.publish(view))
            }
            return effects
        case .realtime(let realtime, let connection):
            guard connection == session.connection, session.state != .disconnected, session.state != .error else {
                return []
            }
            // F-21 §16 item 7: whether the socket's end rejected an update is read before the session closes it.
            let rejected = toneSocketEnded(realtime, at: now)
            // Session first (a terminal event closes the socket and the turn), then the reply side,
            // unless that event ended the session.
            let effects = rejected + session(.realtime(realtime, connection: connection), at: now)
            guard session.state != .disconnected, session.state != .error else { return effects }
            return effects + reply(realtime, at: now) + toneMoment(realtime, at: now)
        case .speechStarted(let recentSpeech, let sentToModel):
            utterances += 1
            utteranceOpen = true
            lastOnsetAt = now
            if !sentToModel, arbiter.replyPlaying { missCandidate = (utterances, arbiter.epoch) }
            utteranceSent = sentToModel
            // F-04 §14 item 1: an utterance the gate did not send is ignored (her reply plays on); only the
            // local 别说了 check still hears its words.
            guard sentToModel else { return bargeIn(.speechStarted(recentSpeech: recentSpeech), at: now) }
            driverSpeaking = true
            arbiter.driverSpeech(true)
            speechOnsets += 1
            transcript = ""
            // F-08 §15 item 4: the transcript stop's give-up never reaches the answer to this new question.
            var cleared: [AgentEffect] = []
            if abandonNextTurn { cleared = [.diagnostic(.abandonCleared)] }
            abandonNextTurn = false
            noUtteranceSinceStop = false
            // F-05a §16 item 1: a new utterance's line starts empty and stays empty without Gemini text.
            geminiHeard = ""
            if !view.driverLine.isEmpty {
                view.driverLine = ""
                cleared.append(.publish(view))
            }
            // The driver speaks to her: a reply may claim focus again after a permanent loss (R4).
            if recentSpeech { arbiter.regainFocus() }
            let effects = cleared + bargeIn(.speechStarted(recentSpeech: recentSpeech), at: now)
            return effects + session(.speechStarted, at: now) + arbiterChanged(at: now)
        case .speechStopped:
            utteranceOpen = false
            lastSpeechEndAt = now
            // F-04 §14 item 1: the end of a not-sent utterance changes nothing.
            guard utteranceSent else { return [] }
            driverSpeaking = false
            arbiter.driverSpeech(false)
            closedTurns += 1
            let area = areaClosed(at: now)
            // R6: she may answer this utterance while navigating.
            arbiter.driverSpoke(at: now)
            // F-08 §15 item 3: a stop phrase's own utterance owes no answer and starts no clock.
            if stopUtterance == utterances {
                return area + session(.speechStopped, at: now) + [.diagnostic(.reaskSuppressed)] + arbiterChanged(at: now)
            }
            answerOwed = true
            // The no-answer clock (W3) starts when the driver stops, with what we heard so far.
            return area + session(.speechStopped, at: now) + pipeline(.driverUtterance(transcript), at: now)
                + arbiterChanged(at: now)
        case .driverWords(let words):
            selectorOwnsWords = true
            guard session.state != .disconnected, session.state != .error else { return [] }
            switch words {
            case .partial(let text): return heard(text, isFinal: false, at: now)
            case .final(let text):
                // F-09a §2: the comfort area reads the phone recognizer's final (her echoed guidance is not the driver).
                var probe = relay
                let area = probe.isEcho(text, at: now) ? [] : areaFinal(text, at: now)
                return area + heard(text, isFinal: true, at: now)
            case .unclear:
                // S4: shown as 「（没听清）」 only; no stop-phrase check. F-09a §2 rule 1: the area is unknown.
                transcriptEpoch = speechOnsets
                transcript = ""
                return areaFinal(nil, at: now)
            }
        case .toolFinished(let turn, let call, let result):
            if call.name == "web_search", searchCalls.removeValue(forKey: call.id) == nil {
                asyncCalls[call.id] = nil
                return []
            }
            var elapsedMs: Int?
            if AsyncTool(name: call.name) != nil {
                // F-18 §27 item 4: a result whose socket was replaced is never sent.
                guard let started = asyncCalls.removeValue(forKey: call.id) else { return [] }
                elapsedMs = Int(now.milliseconds - started.at.milliseconds)
            }
            runningTools = max(runningTools - 1, 0)
            if let index = comfortCalls.removeValue(forKey: call.id), result.ok {
                if areaCurrent?.index == index { areaCurrent?.comfortOk = true }
                if areaPrevious?.index == index { areaPrevious?.comfortOk = true }
            }
            if uiCalls.remove(call.id) != nil {
                context.record(call, ok: result.ok, at: now)
                return uiResult(call, dispatcher.finish(call, result), at: now)
            }
            guard session.state != .disconnected, session.state != .error else { return [] }
            // R6: the answer to a tool the driver asked for may be spoken (PROPOSED: a navigation start
            // can take longer than the 10 s window after the utterance).
            arbiter.driverSpoke(at: now)
            context.record(call, ok: result.ok, at: now)
            let finished = dispatcher.finish(call, result)
            let response = ToolResponse(id: call.id, name: call.name, result: finished, elapsedMs: elapsedMs)
            // The model gets the result even for an abandoned turn; the reply pipeline ignores it there.
            // The model answers a tool result with a new turn: guidance waits for it (F-14 RESPONSE_OPEN).
            answerOwed = true
            // F-21 §16 item 2: an ok tone change is sent when the turn answering this result ends.
            if call.name == SpeakingStyleHandler.tool, finished.ok,
               let style = finished.data["style"]?.stringValue.flatMap(SpeakingStyle.init(rawValue:)) {
                tones?.toolResult(style)
            }
            return [.provider(.toolResponses([response]))] + pipeline(.toolResult(turn, response), at: now)
        case .playback(let playback):
            switch playback {
            // Only the current reply epoch counts: a late event of a flushed reply changes nothing.
            case .replyStarted(let epoch) where epoch == arbiter.epoch:
                _ = arbiter.handle(.replyPlaying(true))
                // A candidate of a flushed or superseded reply is not this reply's miss.
                if let missed = missCandidate, missed.epoch != epoch { missCandidate = nil }
            case .replyFinished(let epoch) where epoch == arbiter.epoch:
                _ = arbiter.handle(.replyPlaying(false))
            case .replyIdle(let epoch) where epoch == arbiter.epoch:
                if let missed = missCandidate, missed.epoch == epoch {
                    missCandidate = nil
                    return [.diagnostic(.stopPhraseMiss(utterance: missed.utterance))] + replyIdle(at: now)
                }
                return replyIdle(at: now)
            case .replyIdle:
                break
            case .replyStarted, .replyFinished: break
            case .guidanceStarted:
                arbiter.guidance(true, at: now)
            case .mediaPlaying(let playing):
                return pipeline(.musicPlaying(playing), at: now)
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
            var effects = relayOutputs(relay.timerFired(id, at: now, conditions: relayConditions), at: now)
            // The bracket ended her reading: whatever of that turn is still to come is not heard.
            if let turn = relayReading, relay.assistantID != relayTurns[turn] {
                relayReading = nil
                if openTurn == turn, !silenced.contains(turn) { effects += stopReply(turn) }
            }
            return effects + arbiterChanged(at: now)
        case .timer(.arbiter):
            return arbiterChanged(at: now)
        case .timer(.area):
            // F-09a §3 item 3: no local final within the wait: the area is unknown and what waited goes on.
            let due = areaHeldCalls.contains { $0.until.map { $0 <= now } == true } || areaHeldUntil.map { $0 <= now } == true
            guard due, areaCurrent != nil, areaCurrent?.area == nil else { return [] }
            return decideArea(nil, at: now)
        case .timer(.stopSync(let sent)):
            guard stopSyncAt == sent else { return [] }
            stopSyncAt = nil
            return [.diagnostic(.stopSyncNoInterrupt)]
        case .navigation(let flags):
            let wasNavigating = navigation.navigating
            let tripEnded = navigation.navigating && !flags.navigating
            navigation = flags
            arbiter.setNavigating(flags.navigating)
            let ended = tripEnded ? relayOutputs(relay.tripEnded(), at: now) : []
            // F-06: NAVIGATING is the evidence for a navigation claim; the pipeline needs each transition.
            let phase = wasNavigating == flags.navigating ? []
                : pipeline(.navigationPhase(flags.navigating ? .navigating : .idle), at: now)
            return ended + phase + arbiterChanged(at: now)
        case .guidancePrompt(let text, let id):
            return relayOutputs(relay.enqueue(text, id: id, at: now, conditions: relayConditions), at: now)
        case .guidanceRelay(let enabled):
            relayEnabled = enabled
            return []
        case .stopPhraseSpotted(let hit):
            // Nothing is sent to Gemini and no driver turn opens: the utterance stays unsent (F-04 §14 item 1).
            return stopPhrase(.kws, phrase: hit.phrase, score: hit.score, at: now) ?? []
        case .bargeInStop:
            var stop = bargeIn(.stopPhrase, at: now)
            if stop.isEmpty {
                // Between clauses the arbiter already counts her as silent, while the shell still plays the rest of
                // the reply: flush it the way a void does, so nothing of it plays over the new question.
                if let turn = openTurn { silenced.insert(turn) }
                segmenter.reset()
                heldClauses = []
                stop = arbiter.void().compactMap { effect in
                    switch effect {
                    case .flushPlayback(let epoch): .flushPlayback(epoch)
                    case .cancelRevoicing(let epoch): .cancelRevoicing(epoch)
                    case .bargeIn: nil
                    }
                } + session(.bargeIn(qualified: true), at: now)
            }
            missCandidate = nil
            arbiter.replyDrained()
            var spoken: [AgentEffect] = []
            if let waiting = waitingFallback {
                waitingFallback = nil
                spoken.append(.speakGuidance(waiting.text, waiting.id))
            }
            // F-18 §27 item 4 (T-020c, replaces §16 item 7 here): a barge-in does not cancel a running search.
            return stop + spoken + [.diagnostic(.bargeInStopped)] + arbiterChanged(at: now)
        case .ui(.choose(let row)):
            uiCount += 1
            let call = ToolCall(id: CallID("ui_\(uiCount)")!, name: "choose_navigation_option",
                                arguments: ["index": .int(Int64(row + 1))])
            let guardContext = GuardContext(turn: 0, closedTurns: closedTurns, now: now, navigating: navigation.navigating,
                                            guidanceRunning: navigation.guidanceRunning, listOpen: navigation.listOpen,
                                            fromTap: true)
            switch dispatcher.decide(call, context: guardContext) {
            case .execute(let running):
                uiCalls.insert(running.id)
                runningTools += 1
                return [.startTool(openTurn ?? .initial, running)]
            case .refuse(let result):
                // The driver gets the refusal from her, like any tap result.
                return [.diagnostic(.toolRefused(code: result.code ?? .invalidValue))] + uiResult(call, result, at: now)
            }
        case .musicPlaying(let playing):
            return pipeline(.musicPlaying(playing), at: now)
        case .manoeuvreDistance(let meters):
            arbiter.setManoeuvreDistance(meters)
            return arbiterChanged(at: now)
        }
    }

    /// I-6 / I-14: she announces a tap's outcome from its read-back, like a voice choice.
    private mutating func uiResult(_ call: ToolCall, _ result: ToolResult, at now: NovaInstant) -> [AgentEffect] {
        let connected: Bool = switch session.state {
        case .listening, .userSpeaking, .thinking, .speaking: true
        default: false
        }
        guard connected else { return [] }
        var payload: [String: JSONValue] = ["ok": .bool(result.ok)]
        payload["data"] = .object(result.data)
        if let code = result.code { payload["code"] = .string(code.rawValue) }
        if let advice = result.advice { payload["advice"] = .string(advice) }
        let json = (try? JSONValue.canonicalEncoder().encode(JSONValue.object(payload)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        answerOwed = true
        // The tap is the driver's own request: she may answer it while navigating (R6).
        arbiter.driverSpoke(at: now)
        let note = "[系统] 用户在屏幕上点选了 \(call.name)\(call.arguments["index"].map { " index=\($0)" } ?? "")，"
            + "结果：\(json)。只按这个结果用一句话告诉用户，不要再调用工具。"
        return [.provider(.text([TextTurn(role: .user, text: note)], turnComplete: true))]
    }

    // MARK: Guidance relay (F-14) and arbiter re-evaluation (F-08)

    private var relayConditions: GuidanceConditions {
        let connected: Bool = switch session.state {
        case .listening, .userSpeaking, .thinking, .speaking: true
        default: false
        }
        // F-07 §15: without revoicing there is no voice to read a sentence back in; guidance takes the fallback voice.
        return GuidanceConditions(enabled: relayEnabled, connected: connected, capable: revoicing,
                                  driverSpeaking: driverSpeaking, responseOpen: openTurn != nil || answerOwed,
                                  workPending: runningTools > 0, focusHeld: arbiter.focus == .held)
    }

    // MARK: F-05a §16 (T-016n): the driver's line

    /// Item 2: the whole Gemini text so far through `ScreenLanguage`; a hidden final shows 「（没听清）」 and writes one
    /// `screen-hidden kind=driver`. Display only: the stop phrase, the echo filter and the guards never read it.
    private mutating func driverLine(_ text: String, isFinal: Bool) -> [AgentEffect] {
        if isFinal { geminiHeard = text } else { geminiHeard += text }
        let shown = ScreenLanguage.driverDisplay(geminiHeard, final: isFinal, detector: detector)
        var effects: [AgentEffect] = []
        if shown.hidden, isFinal { effects.append(.screenHidden(.driver, geminiHeard)) }
        let line = shown.line ?? ""
        if line != view.driverLine {
            view.driverLine = line
            effects.append(.publish(view))
        }
        return effects
    }

    // MARK: F-05a §13 (T-016i): the screen check on her bubble

    /// The whole reply or reading so far; `view.subtitle` shows it only when it passes.
    private var subtitleRaw = ""
    private var subtitleKind: ScreenTextKind = .reply
    private var subtitleGuidance: String?
    private var subtitleHidden = false

    private mutating func resetSubtitle() {
        view.subtitle = ""
        subtitleRaw = ""
        subtitleKind = .reply
        subtitleGuidance = nil
        subtitleHidden = false
    }

    /// Item 2: checked on the whole text so far. `wait` shows nothing yet; `hide` shows nothing, or the engine's
    /// own sentence for a guidance reading. Once hidden, the text stays hidden.
    private mutating func subtitle(adding text: String, _ kind: ScreenTextKind, guidance: String? = nil) -> [AgentEffect] {
        subtitleRaw += text
        subtitleKind = kind
        if let guidance { subtitleGuidance = guidance }
        return applySubtitle(final: false)
    }

    /// The text is complete (the turn closed): `wait` becomes `show` or `hide`.
    private mutating func finalSubtitle() -> [AgentEffect] {
        guard !subtitleRaw.isEmpty, !subtitleHidden else { return [] }
        let before = view.subtitle
        let effects = applySubtitle(final: true)
        return effects + (view.subtitle == before ? [] : [.publish(view)])
    }

    private mutating func applySubtitle(final: Bool) -> [AgentEffect] {
        guard !subtitleHidden else { return [] }
        // F-05a §15 item 6: a Latin-only reply counts as English only when the language check allowed it.
        var language = ScreenLanguage.replyLanguage(subtitleRaw)
        if subtitleKind == .reply, language == .en, !pipeline.replyLanguageAllowed { language = nil }
        switch ScreenLanguage.check(subtitleRaw, final: final, language: language) {
        case .show: view.subtitle = subtitleRaw
        case .wait: view.subtitle = ""
        case .hide:
            subtitleHidden = true
            view.subtitle = subtitleKind == .guidance ? (subtitleGuidance ?? "") : ""
            return [.screenHidden(subtitleKind, subtitleRaw)]
        }
        return []
    }

    private mutating func relayOutputs(_ outputs: [GuidanceRelayOutput], at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for output in outputs {
            switch output {
            case .sendToModel(let id, let prompt):
                relayAwaiting = id
                awaitingText = relay.text(for: id)
                silenceNextRelayTurn = false
                answerOwed = false
                effects.append(.provider(.text([TextTurn(role: .user, text: prompt)], turnComplete: true)))
            case .speakFallback(let id, let text, _):
                // Guidance never overlaps her reply (F-14 §10). R1 holds from now, not from when the voice
                // is rendered, so no clause is released in between. A reply that already released clauses
                // (they may be at Azure or sounding) is cut whole (PROPOSED: guidance is the safety-relevant
                // voice; a reply not yet started is only held).
                arbiter.guidance(true, at: now)
                if let turn = openTurn, relayTurns[turn] == nil, !silenced.contains(turn),
                   arbiter.replyStarted || arbiter.replyPlaying {
                    // An answer still being generated is cut (it could run long).
                    effects += stopReply(turn)
                } else if arbiter.replyStarted || arbiter.replyPlaying {
                    // The turn has closed (or is a reading) but its audio may still be at Azure or sounding:
                    // wait until it drains, at most 4 s, then cut what is left.
                    waitingFallback = (text, id, now)
                    let at = now + Self.fallbackWaitMax
                    effects.append(.schedule(.arbiter(at), at: at))
                    continue
                }
                effects.append(.speakGuidance(text, id))
            case .silenceAssistant(let id):
                if let turn = relayReading, relayTurns[turn] == id {
                    relayReading = nil
                    if openTurn == turn, !silenced.contains(turn) { effects += stopReply(turn) }
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
        var effects: [AgentEffect] = []
        if let waiting = waitingFallback, now >= waiting.since + Self.fallbackWaitMax {
            waitingFallback = nil
            segmenter.reset()
            heldClauses = []
            effects += arbiter.void().compactMap { effect in
                switch effect {
                case .flushPlayback(let epoch): return .flushPlayback(epoch)
                case .cancelRevoicing(let epoch): return .cancelRevoicing(epoch)
                case .bargeIn: return nil
                }
            }
            effects.append(.speakGuidance(waiting.text, waiting.id))
        }
        effects += releaseHeld(at: now)
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
                if state == .connecting || state == .reconnecting || state == .listening { view.configError = nil }
                if state != .disconnected { view.offlineEnded = false }
                view.waitingForNetwork = session.waitingForNetwork
                effects.append(.publish(view))
            case .offlineEnded:
                view.offlineEnded = true
            case .keepHandle(let handle):
                // F-21 §16 item 5: the chain's original instruction stays beside the handle (memory only).
                effects.append(.keepResumption(handle, instruction: handle == nil ? nil : tones?.original))
            case .connect(let connection, let resume):
                effects += newSocket(at: now)
                if var tone = tones {
                    // F-21 §16 items 1, 5: the setup carries the current tone; a resumed one sends it first if needed.
                    let setup = tone.connect(resume: resume)
                    tones = tone
                    effects.append(.provider(.connect(connection: connection, resume: resume, instruction: setup.instruction,
                                                      updateAtSetup: setup.updateAtSetup)))
                } else {
                    effects.append(.provider(.connect(connection: connection, resume: resume)))
                }
            case .close:
                // F-21 §16 item 2: nothing waits for a turn of a closed socket.
                tones?.closed()
                // The turn in progress dies with its socket (contracts §5: Error/Closed drop the reply).
                effects += endTurn(at: now)
                effects += dropAsyncCalls()
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

    // MARK: F-21 §16 (T-034c): her new tone on the open connection

    /// A step of `StyleUpdates` as effects: the update first, then its line.
    private static func effects(_ step: StyleUpdates.Step) -> [AgentEffect] {
        (step.send.map { [.provider(.contextUpdate($0))] } ?? []) + (step.line.map { [.styleUpdateLine($0)] } ?? [])
    }

    /// Item 7: the socket's terminal events, before the session closes it.
    private mutating func toneSocketEnded(_ event: RealtimeEvent, at now: NovaInstant) -> [AgentEffect] {
        guard var tone = tones else { return [] }
        let code: RealtimeErrorCode?
        switch event {
        case .failed(let error): code = error.code
        case .closed, .goAway: code = nil
        default: return []
        }
        let step = tone.socketEnded(code, at: now)
        tones = tone
        return Self.effects(step)
    }

    /// Items 2, 4, 5: `setupComplete`, a turn opening or speaking, and its end (`turnComplete` or `interrupted`).
    private mutating func toneMoment(_ event: RealtimeEvent, at now: NovaInstant) -> [AgentEffect] {
        guard var tone = tones else { return [] }
        let steps: [StyleUpdates.Step]
        switch event {
        case .setupComplete: steps = tone.setupComplete(at: now)
        case .responseStarted(let turn), .replyText(let turn, _), .replyAudio(let turn, _):
            tone.turnActive(turn)
            steps = []
        case .responseDone(let turn, _), .interrupted(let turn, _): steps = [tone.turnEnded(turn, at: now)]
        default: return []
        }
        tones = tone
        return steps.flatMap(Self.effects)
    }

    private mutating func newSocket(at now: NovaInstant) -> [AgentEffect] {
        // A prompt sent on the old socket will never be read: it goes to the fallback voice now.
        var effects: [AgentEffect] = []
        if let id = relayAwaiting { effects = relayOutputs(relay.sendFailed(id, at: now), at: now) }
        if let turn = relayReading, let id = relayTurns[turn] {
            effects += relayOutputs(relay.sendFailed(id, at: now), at: now)
        }
        relayAwaiting = nil
        relayReading = nil
        relayTurns = [:]
        effects += dropAsyncCalls()
        // F-09a: calls and reply of the old socket that waited for the area are never sent.
        runningTools = max(runningTools - areaHeldCalls.count, 0)
        areaHeldCalls = []
        areaHeldReply = []
        areaHeldUntil = nil
        areaHeldClosed = [:]
        areaEarlyTurns = []
        comfortCalls = [:]
        areaCurrent?.turns = []
        unclassified = nil
        if let waiting = waitingFallback {
            waitingFallback = nil
            effects.append(.speakGuidance(waiting.text, waiting.id))
        }
        silenceNextRelayTurn = false
        answerOwed = false
        openTurn = nil
        abandoned = []
        silenced = []
        abandonNextTurn = false
        noUtteranceSinceStop = false
        return effects
    }

    /// Stops what is still playing or being voiced of the open turn and closes it as cancelled.
    private mutating func endTurn(at now: NovaInstant) -> [AgentEffect] {
        guard let turn = openTurn else { return [] }
        openTurn = nil
        let stops = silenced.contains(turn) ? [] : stopReply(turn)
        return stops + pipeline(.turnClosed(turn, .cancelled), at: now)
    }

    /// Raises the epoch: playback flushed, revoicing cancelled, held clauses dropped.
    /// Arbiter barge-in effects in contract order: flush, cancel revoicing, then the session.
    private mutating func bargeIn(_ input: ArbiterInput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for effect in arbiter.handle(input) {
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
        return effects
    }

    /// F-18 §27 item 4 (T-020c): background calls of a closed or replaced socket are dropped, never answered.
    private mutating func dropAsyncCalls() -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for (id, call) in asyncCalls.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            searchCalls[id] = nil
            runningTools = max(runningTools - 1, 0)
            effects += [.cancelTool(id), .diagnostic(.asyncToolDropped(tool: call.tool))]
        }
        asyncCalls = [:]
        return effects
    }

    /// F-18 §16 item 7: cancels the running searches that `match` their turn; their results are never sent.
    private mutating func cancelSearches(_ match: (TurnID) -> Bool) -> [AgentEffect] {
        let ids = searchCalls.filter { match($0.value) }.keys.sorted { $0.rawValue < $1.rawValue }
        for id in ids { searchCalls[id] = nil; asyncCalls[id] = nil }
        runningTools = max(runningTools - ids.count, 0)
        return ids.map { .cancelTool($0) }
    }

    /// Nothing of hers is left to sound. With her turn closed, a waiting fallback may speak.
    private mutating func replyIdle(at now: NovaInstant) -> [AgentEffect] {
        if openTurn == nil || openTurn.map({ relayTurns[$0] != nil && relayReading == nil }) == true {
            arbiter.replyDrained()
            if let waiting = waitingFallback {
                waitingFallback = nil
                return [.speakGuidance(waiting.text, waiting.id)] + arbiterChanged(at: now)
            }
        }
        return arbiterChanged(at: now)
    }

    /// F-08 §14 items 4, 5, 7: a stop phrase from the spotter or the transcript, whichever comes first. A second one
    /// within 1 s or in the same utterance is ignored; nil when it is ignored or she was not talking.
    private mutating func stopPhrase(_ source: StopPhraseSource, phrase: Int, score: Int,
                                     at now: NovaInstant) -> [AgentEffect]? {
        if let last = lastStopAt, now - last < .seconds(1) { return nil }
        // Item 5: the other source, in the same utterance, is ignored (whichever fired first stopped her). The
        // transcript's final lands after the utterance closed, so for it a closed utterance still counts.
        if stopUtterance == utterances, stopSource != source, utteranceOpen || source == .transcript { return nil }
        var stop = bargeIn(.stopPhrase, at: now)
        // F-18 §16 item 7: a stop phrase also cancels a running search, even while she waits silently for it.
        let cancelled = cancelSearches { _ in true }
        guard !stop.isEmpty else { return cancelled.isEmpty ? nil : cancelled }
        stop += cancelled
        lastStopAt = now
        stopUtterance = utterances
        stopSource = source
        missCandidate = nil
        let heardDriver = utteranceOpen || lastSpeechEndAt.map { now - $0 <= .seconds(1) } == true
        let ms = heardDriver ? lastOnsetAt.map { Int((now - $0).milliseconds) } ?? -1 : -1
        // F-08 §15 items 1–3: after the local flush Gemini is told too (the shell also ends the echo-tail mute), and
        // no re-ask pulls back to the stopped topic. Nothing of hers is left to sound: a waiting fallback may speak.
        arbiter.replyDrained()
        var sync: [AgentEffect] = []
        if let waiting = waitingFallback {
            waitingFallback = nil
            sync.append(.speakGuidance(waiting.text, waiting.id))
        }
        if session.state != .disconnected, session.state != .error {
            stopSyncAt = now
            stopSyncTurn = openTurn
            // Item 4: a turn Gemini opens for the empty activity is not spoken; a new sent utterance clears this.
            abandonNextTurn = openTurn == nil
            noUtteranceSinceStop = true
            sync += [.provider(.interruptReply), .diagnostic(.stopSyncSent),
                     .schedule(.stopSync(now), at: now + .seconds(1))]
        }
        return stop + sync + [.diagnostic(.stopPhrase(source: source, phrase: phrase, msFromSpeechStart: ms, score: score,
                                                      selfStop: !heardDriver))]
            + pipeline(.stopped, at: now) + arbiterChanged(at: now)
    }

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

    /// The driver's words so far (`text` is the whole utterance), from Gemini or from `TranscriptSelector`.
    private mutating func heard(_ text: String, isFinal: Bool, at now: NovaInstant) -> [AgentEffect] {
        // Her own guidance reading heard back through the microphone is not the driver (F-14 §8).
        if isFinal, relay.isEcho(text, at: now) { return [] }
        transcriptEpoch = speechOnsets
        transcript = text
        // Barge-in is a stop phrase only (owner rule 2026-10-28). It stops her at once, and the model's
        // answer to it is not heard: she just stops.
        if ListeningIntent.classify(text) == .shutUp {
            let stop = stopPhrase(.transcript, phrase: StopPhrases.index(of: text) ?? -1, score: 0, at: now)
            // Only a stop that fired gives up the turn: with her silent, 「停」 is a command for the model (music).
            if let stop {
                if isFinal { abandonNextTurn = true }
                return stop
            }
            // A stop already fired in this utterance (spotter or an earlier partial): its words are no command either.
            if stopUtterance == utterances {
                if isFinal { abandonNextTurn = true }
                return []
            }
        }
        // The flushed transcript of an utterance already given up on does not revive it; words of a not-sent
        // utterance never reach the tool path (F-04 §14 item 1).
        guard isFinal, !abandonNextTurn, utteranceSent else { return [] }
        return pipeline(.driverUtterance(text), at: now)
    }

    private mutating func reply(_ event: RealtimeEvent, at now: NovaInstant) -> [AgentEffect] {
        if let turn = event.turn, abandoned.contains(turn) {
            // W3: the utterance was given up on; a late call is dropped and never executed, nothing is said.
            if case .toolCalls = event { return [.diagnostic(.lateToolResultDropped(turn: turn))] }
            if openTurn == turn, event.closesTurn { openTurn = nil }
            return []
        }
        if let pending = unclassified, event.turn == pending.turn {
            return classify(event, pending, at: now)
        }
        switch event {
        case .userTranscript(let text, let isFinal):
            // F-05a §16 item 1: the driver's line is Gemini's text alone, whoever feeds the core's words. Her own
            // guidance reading heard back (F-14 §8 echo) is not the driver's line either.
            var probe = relay
            let echo = isFinal && probe.isEcho(text, at: now)
            var line: [AgentEffect] = []
            if echo {
                // Her reading's partials may already show: the echo final clears them.
                geminiHeard = ""
                if !view.driverLine.isEmpty { view.driverLine = ""; line = [.publish(view)] }
            } else {
                line = driverLine(text, isFinal: isFinal)
            }
            guard !selectorOwnsWords else { return line }
            // Gemini's partials are deltas. A stop's flush goes before the screen update.
            return heard(isFinal ? text : transcript + text, isFinal: isFinal, at: now) + line
        case .responseStarted(let turn):
            if abandonNextTurn {
                abandonNextTurn = false
                abandoned.insert(turn)
                return []
            }
            // F-08 §16 item 3: no resume after a stop; she speaks again only to answer an utterance sent since.
            if noUtteranceSinceStop, relayAwaiting == nil, turn != openTurn {
                abandoned.insert(turn)
                return [.diagnostic(.postStopTurnDropped)]
            }
            openTurn = turn
            segmenter.reset()
            arbiter.newReply()
            // A prompt is only sent when no answer is owed, and Gemini answers its inputs in order, so the
            // first turn after a prompt is its reading, even if the driver spoke meanwhile.
            if let id = relayAwaiting, answerOwed {
                // The driver spoke after the prompt: this may be the reading or their answer.
                unclassified = (turn, id)
                unclassifiedText = ""
                resetSubtitle()
                return [.newReply]
            }
            if let id = relayAwaiting {
                relayAwaiting = nil
                relayTurns[turn] = id
                if silenceNextRelayTurn {
                    // The deadline passed: the fallback voice has this sentence. Nothing of it is heard.
                    silenceNextRelayTurn = false
                    silenced.insert(turn)
                    return []
                }
                relayReading = turn
                resetSubtitle()
                return [.newReply] + relayOutputs(relay.assistantStarted(at: now), at: now)
            }
            answerOwed = false
            resetSubtitle()
            return [.newReply] + pipeline(.turnOpened(turn), at: now) + areaTurnOpened(turn)
        case .replyText(let turn, let text):
            guard !silenced.contains(turn) else { return [] }
            if relayTurns[turn] != nil {
                // A guidance reading: spoken as given, judged afterwards for fidelity, never a claim.
                if relayReading == turn { relay.assistantText(text) }
                let shown = subtitle(adding: text, .guidance, guidance: relayTurns[turn].flatMap { relay.text(for: $0) } ?? awaitingText)
                return shown + [.publish(view)] + speak(segmenter.append(text), at: now)
            }
            return pipeline(.replyText(turn, text), at: now)
        case .replyAudio(let turn, let pcm):
            guard !silenced.contains(turn), relayTurns[turn] == nil else { return [] }
            return pipeline(.replyAudio(turn, pcm), at: now)
        case .toolCalls(let turn, let calls) where relayTurns[turn] != nil:
            // A guidance reading never acts: every call of it is refused and nothing runs.
            return [.provider(.toolResponses(calls.map {
                ToolResponse(id: $0.id, name: $0.name, result: .failure(.actionNotAllowed))
            }))]
        case .toolCalls(let turn, let calls):
            var effects = pipeline(.toolCalls(turn, calls), at: now)
            // F-18 §15 item 8: refused below as UNKNOWN_TOOL like any undeclared name; only noted here.
            if calls.contains(where: { $0.name == "google_search" }) { effects.append(.diagnostic(.webSearchAsFunction)) }
            for call in calls {
                // F-05a §6: the guards read state and turn counts only, never the transcript.
                let guardContext = GuardContext(turn: speechOnsets, closedTurns: closedTurns, now: now,
                                                navigating: navigation.navigating,
                                                guidanceRunning: navigation.guidanceRunning,
                                                listOpen: navigation.listOpen)
                switch dispatcher.decide(call, context: guardContext) {
                case .execute(let running) where CarRequestRouter.comfortTools.contains(running.name):
                    // F-09a §3: a comfort call runs only for a car request; it waits for the area at most 800 ms.
                    // An early turn's call (or one while a sent utterance is open) belongs to that open utterance.
                    // A turn already attached to the closed utterance keeps that utterance's area (below).
                    let ofCurrent = areaCurrent?.turns.contains(turn) ?? false
                    if carAreas, areaEarlyTurns.contains(turn) || (driverSpeaking && utteranceSent && !ofCurrent) {
                        runningTools += 1
                        areaHeldCalls.append((turn, running, closedTurns + 1, nil))
                        continue
                    }
                    guard let current = areaCurrent else {
                        runningTools += 1
                        effects.append(.startTool(turn, running))
                        continue
                    }
                    if let area = current.area {
                        effects += comfortCall(turn, running, area: area, utterance: current.index, at: now)
                    } else {
                        runningTools += 1
                        let until = now + TranscriptSelector.Tuning().localFinalWait
                        areaHeldCalls.append((turn, running, current.index, until))
                        effects.append(.schedule(.area(until), at: until))
                    }
                case .execute(let running):
                    runningTools += 1
                    if running.name == "web_search" { searchCalls[running.id] = turn }
                    if let tool = AsyncTool(name: running.name) { asyncCalls[running.id] = (tool, now) }
                    effects.append(.startTool(turn, running))
                case .refuse(let result):
                    effects += refuse(turn, call, result, at: now)
                }
            }
            return effects
        case .toolCallCancellation(let ids):
            for id in ids {
                let search = searchCalls.removeValue(forKey: id) != nil
                let background = asyncCalls.removeValue(forKey: id) != nil
                // F-09a: a comfort call held for its area that Gemini cancels never runs.
                let held = areaHeldCalls.contains { $0.call.id == id }
                areaHeldCalls.removeAll { $0.call.id == id }
                if search || background || held { runningTools = max(runningTools - 1, 0) }
            }
            return ids.map { .cancelTool($0) }
        case .audioDone(let turn):
            if relayTurns[turn] != nil { return [] }
            return pipeline(.audioDone(turn), at: now)
        case .interrupted(let turn, _) where relayTurns[turn] != nil,
             .responseDone(let turn, _) where relayTurns[turn] != nil:
            if openTurn == turn { openTurn = nil }
            guard relayReading == turn else { return [] }
            relayReading = nil
            var effects: [AgentEffect] = finalSubtitle()
            let completed = if case .responseDone(_, .completed) = event { true } else { false }
            if completed, !silenced.contains(turn), let rest = segmenter.flush() {
                effects += speak([rest], at: now)
            }
            // A reading the driver cut is not unfaithful: no strike for it.
            return effects + relayOutputs(relay.assistantFinished(at: now, conditions: relayConditions,
                                                                  cut: !completed), at: now)
        case .interrupted(let turn, _):
            // F-08 §15 item 1: the stopped reply closed for Gemini too.
            // F-18 §27 item 4: the interrupted reply's running search keeps going.
            var synced: [AgentEffect] = []
            if let sent = stopSyncAt, stopSyncTurn == nil || stopSyncTurn == turn {
                stopSyncAt = nil
                stopSyncTurn = nil
                synced += [.diagnostic(.stopSyncInterrupted(ms: Int((now - sent).milliseconds))), .cancelTimer(.stopSync(sent))]
            }
            // Server-side interruption: whatever of this reply is still queued must not play.
            let stops = openTurn == turn && !silenced.contains(turn) ? stopReply(turn) : []
            let open = openTurn == turn
            if openTurn == turn { openTurn = nil }
            let closed = pipeline(.turnClosed(turn, .cancelled), at: now)
            if areaHolds(turn) { areaHeldClosed[turn] = false }
            return synced + stops + closed + (open ? finalSubtitle() : [])
        case .responseDone(let turn, let outcome):
            let open = openTurn == turn
            if openTurn == turn { openTurn = nil }
            var effects = pipeline(.turnClosed(turn, outcome), at: now)
            if areaHolds(turn) { areaHeldClosed[turn] = outcome == .completed }
            // F-05a §13: the reply is complete once the pipeline has released what it held.
            if open { effects += finalSubtitle() }
            // The last half clause is spoken only for a reply that completed and still may be heard.
            if outcome == .completed, !silenced.contains(turn), let rest = segmenter.flush() {
                effects += speak([rest], at: now)
            }
            return effects
        case .setupComplete, .resumptionHandle, .goAway, .failed, .closed, .turnEnded:
            return []
        }
    }

    /// Decides an unclassified turn on its first words (at least 4 letters or digits, or the whole
    /// sentence if shorter): the start of the sentence means her reading, anything else (or a tool
    /// call, or a turn that ends first) the driver's answer.
    private mutating func classify(_ event: RealtimeEvent, _ pending: (turn: TurnID, id: GuidanceID),
                                   at now: NovaInstant) -> [AgentEffect] {
        let sentence = GuidanceRelay.normalised(relay.text(for: pending.id) ?? awaitingText ?? "")
        var isReading = false
        switch event {
        case .replyText(_, let text):
            unclassifiedText += text
            let words = GuidanceRelay.normalised(unclassifiedText)
            let enough = min(4, max(sentence.count, 1))
            guard words.count >= enough || words.count >= sentence.count && !sentence.isEmpty else { return [] }
            isReading = !sentence.isEmpty && (sentence.hasPrefix(words) || words.hasPrefix(sentence))
        case .replyAudio:
            return []  // revoicing: the provider's audio is never played; wait for the words
        default:
            let words = GuidanceRelay.normalised(unclassifiedText)
            isReading = !words.isEmpty && !sentence.isEmpty && sentence.hasPrefix(words)
            if case .toolCalls = event { isReading = false }
        }
        unclassified = nil
        let heard = unclassifiedText
        unclassifiedText = ""
        var effects: [AgentEffect] = []
        if isReading {
            relayAwaiting = nil
            awaitingText = nil
            relayTurns[pending.turn] = pending.id
            if silenceNextRelayTurn || relay.assistantID != pending.id {
                // The deadline passed: the fallback voice has (or had) this sentence.
                silenceNextRelayTurn = false
                silenced.insert(pending.turn)
            } else {
                relayReading = pending.turn
                effects += relayOutputs(relay.assistantStarted(at: now), at: now)
            }
        } else {
            // The driver's answer; the reading was dropped by Gemini and the deadline covers it.
            answerOwed = false
            relayAwaiting = nil
            awaitingText = nil
            silenceNextRelayTurn = false
            effects += pipeline(.turnOpened(pending.turn), at: now) + areaTurnOpened(pending.turn)
        }
        if case .replyText = event {
            return effects + reply(.replyText(pending.turn, heard), at: now)
        }
        if !heard.isEmpty { effects += reply(.replyText(pending.turn, heard), at: now) }
        return effects + reply(event, at: now)
    }

    private mutating func pipeline(_ input: PipelineInput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        for output in pipeline.handle(input, at: now) { effects += pipelineOutput(output, at: now) }
        return effects
    }

    private mutating func pipelineOutput(_ output: PipelineOutput, at now: NovaInstant) -> [AgentEffect] {
        var effects: [AgentEffect] = []
        switch output {
            case .speechText(let turn, _) where areaHolds(turn), .speechAudio(let turn, _) where areaHolds(turn):
                // F-09a §4: nothing of her reply is heard or shown until the utterance's area is known.
                areaHeldReply.append(output)
                if areaHeldUntil == nil {
                    let until = now + TranscriptSelector.Tuning().localFinalWait
                    areaHeldUntil = until
                    effects.append(.schedule(.area(until), at: until))
                }
            case .sendCorrection where areaTired, .languageReask where areaTired, .fallbackLine where areaTired,
                 .reask where areaTired:
                // F-09a §4 item 2: no re-ask, correction or fallback line for a tired utterance.
                break
            case .speechText(let turn, let text):
                guard !silenced.contains(turn) else { break }
                effects += subtitle(adding: text, .reply)
                effects.append(.publish(view))
                if revoicing { effects += speak(segmenter.append(text), at: now) }
            case .speechAudio(let turn, let pcm):
                // Revoicing on (ADR-016): the provider's own audio is never played. Off (F-07 §15 item 3): the
                // pipeline released it judged, so it goes to the reply lane under the arbiter like a clause.
                guard !revoicing, !silenced.contains(turn) else { break }
                heldClauses.append(.playReplyAudio(turn, pcm))
                effects += releaseHeld(at: now)
            case .voided(let turn):
                areaHeldReply.removeAll { $0.turn == turn }
                // F-07 §15 item 8: a claim disproven while her audio already plays is cut here; the record says how much.
                if let played = turnAudio, played.turn == turn, !silenced.contains(turn) {
                    let heard = min(played.ms, Int((now - played.since).milliseconds))
                    effects.append(.diagnostic(.claimCut(turn: Int(turn.value), playedMs: max(0, heard))))
                }
                resetSubtitle()
                effects += silenced.contains(turn) ? [] : stopReply(turn)
                effects.append(.publish(view))
            case .sendCorrection(let reason):
                answerOwed = true
                effects.append(.provider(.text([TextTurn(role: .user, text: reason.instruction)], turnComplete: true)))
            case .languageReask:
                // F-05a §15 item 4: sent at once, not after the correction grace; §16 item 5: no heard words.
                answerOwed = true
                effects.append(.provider(.text([TextTurn(role: .user, text: CorrectionReason.wrongLanguage.instruction)],
                                               turnComplete: true)))
            case .fallbackLine:
                // F-05a §15 item 5: the app's own line, in the system voice on the guidance lane, shown as hers.
                answerOwed = false
                fallbackLines += 1
                resetSubtitle()
                effects += subtitle(adding: DriverTurnPipeline.fallbackLineText, .reply)
                effects.append(.publish(view))
                effects.append(.speakGuidance(DriverTurnPipeline.fallbackLineText, GuidanceID(UInt64.max - fallbackLines)))
            case .languageLine(let line):
                effects.append(.languageLine(line))
            case .reask(let text):
                answerOwed = true
                effects.append(.diagnostic(.turnUnanswered(turn: closedTurns)))  // F-04 §14 item 7
                effects.append(.provider(.text([TextTurn(role: .user, text: text)], turnComplete: true)))
            case .gaveUp:
                // The model will not answer this utterance any more: guidance may be offered again.
                answerOwed = false
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
        return effects
    }

    // MARK: F-09a (T-017a): car tools only for car requests

    /// The newest closed utterance is tired: her turns for it are silent and nothing re-asks (§4).
    private var areaTired: Bool { areaCurrent?.area == .tired }

    /// Her reply of `turn` waits: the turn answers the newest closed utterance, whose area is not known yet.
    private func areaHolds(_ turn: TurnID) -> Bool {
        if areaEarlyTurns.contains(turn) { return !silenced.contains(turn) }
        guard let current = areaCurrent, current.area == nil, current.turns.contains(turn) else { return false }
        return !silenced.contains(turn)
    }

    /// A sent utterance closed: it becomes the newest one. The one before, if still undecided, is unknown (§2 rule 1).
    private mutating func areaClosed(at now: NovaInstant) -> [AgentEffect] {
        guard carAreas else { return [] }
        var effects: [AgentEffect] = []
        if areaCurrent != nil, areaCurrent?.area == nil { effects += decideArea(nil, at: now) }
        areaPrevious = areaCurrent
        areaCurrent = AreaUtterance(index: closedTurns, turns: areaEarlyTurns)
        areaEarlyTurns = []
        // What already waits for the new utterance (early turns' replies and calls) waits at most 800 ms from now.
        let index = closedTurns
        let turns = areaCurrent?.turns ?? []
        let heldReply = areaHeldReply.contains { $0.turn.map(turns.contains) ?? false }
        let heldCalls = areaHeldCalls.contains { $0.utterance == index }
        if heldReply || heldCalls {
            let until = now + TranscriptSelector.Tuning().localFinalWait
            for i in areaHeldCalls.indices where areaHeldCalls[i].utterance == index { areaHeldCalls[i].until = until }
            if heldReply { areaHeldUntil = until }
            effects.append(.schedule(.area(until), at: until))
        }
        if let early = areaEarlyFinal, early.onset == speechOnsets { effects += decideArea(early.text, at: now) }
        areaEarlyFinal = nil
        return effects
    }

    /// The phone recognizer's final for the current utterance (nil = unclear).
    private mutating func areaFinal(_ text: String?, at now: NovaInstant) -> [AgentEffect] {
        // A not-sent utterance's words are no driver request (F-04 §14 item 1).
        guard utteranceSent, speechOnsets > 0 else { return [] }
        if closedTurns < speechOnsets {
            areaEarlyFinal = (speechOnsets, text)
            return []
        }
        guard let current = areaCurrent, current.index == closedTurns, current.area == nil else { return [] }
        return decideArea(text, at: now)
    }

    /// §2: the area of the newest closed utterance is decided; what waited for it goes on, or is refused / silenced.
    private mutating func decideArea(_ text: String?, at now: NovaInstant) -> [AgentEffect] {
        guard var current = areaCurrent, current.area == nil else { return [] }
        let previous = areaPrevious.flatMap { p in p.area.map { CarRequestRouter.Previous(area: $0, comfortOk: p.comfortOk) } }
        let area = CarRequestRouter.area(final: text, previous: previous)
        current.area = area
        areaCurrent = current
        var effects: [AgentEffect] = [.diagnostic(.carArea(utterance: current.index, area: area))]
        let calls = areaHeldCalls.filter { $0.utterance == current.index }
        areaHeldCalls.removeAll { $0.utterance == current.index }
        let connected = session.state != .disconnected && session.state != .error
        for held in calls {
            runningTools = max(runningTools - 1, 0)
            if connected { effects += comfortCall(held.turn, held.call, area: area, utterance: current.index, at: now) }
        }
        let reply = areaHeldReply.filter { $0.turn.map(current.turns.contains) ?? true }
        areaHeldReply.removeAll { $0.turn.map(current.turns.contains) ?? true }
        let closed = areaHeldClosed.filter { current.turns.contains($0.key) }.sorted { $0.key.value < $1.key.value }
        for entry in closed { areaHeldClosed[entry.key] = nil }
        if areaHeldReply.isEmpty { areaHeldUntil = nil }
        if area == .tired {
            // §4 item 1: every turn opened for it is silent; what of it was held is dropped.
            for turn in current.turns.sorted(by: { $0.value < $1.value }) where !silenced.contains(turn) {
                effects += silenceTired(turn)
            }
            return effects + arbiterChanged(at: now)
        }
        for output in reply { effects += pipelineOutput(output, at: now) }
        // A held turn that closed meanwhile: its subtitle is final and its last half clause may be spoken.
        for (turn, completed) in closed where openTurn == nil || openTurn == turn {
            effects += finalSubtitle()
            if completed, !silenced.contains(turn), let rest = segmenter.flush() { effects += speak([rest], at: now) }
        }
        return effects + arbiterChanged(at: now)
    }

    /// §3 item 1: run the comfort call, or refuse it with `NOT_A_CAR_REQUEST`.
    private mutating func comfortCall(_ turn: TurnID, _ call: ToolCall, area: CarRequestArea, utterance: Int,
                                      at now: NovaInstant) -> [AgentEffect] {
        guard CarRequestRouter.allows(area) else {
            return refuse(turn, call, ToolDispatcher.failure(.notACarRequest), at: now)
        }
        runningTools += 1
        comfortCalls[call.id] = utterance
        return [.startTool(turn, call)]
    }

    private mutating func refuse(_ turn: TurnID, _ call: ToolCall, _ result: ToolResult, at now: NovaInstant) -> [AgentEffect] {
        let response = ToolResponse(id: call.id, name: call.name, result: result)
        answerOwed = true
        return [.diagnostic(.toolRefused(code: result.code ?? .invalidValue)), .provider(.toolResponses([response]))]
            + pipeline(.toolResult(turn, response), at: now)
    }

    /// A model turn opened for the newest closed utterance (not a guidance reading).
    private mutating func areaTurnOpened(_ turn: TurnID) -> [AgentEffect] {
        guard carAreas else { return [] }
        // Gemini's VAD may open the answer before the phone closes the utterance: it belongs to that one.
        if driverSpeaking, utteranceSent {
            areaEarlyTurns.insert(turn)
            return []
        }
        guard areaCurrent != nil else { return [] }
        areaCurrent?.turns.insert(turn)
        return areaTired ? silenceTired(turn) : []
    }

    /// §4 item 1: nothing of `turn` is heard or shown; queued playback is flushed.
    private mutating func silenceTired(_ turn: TurnID) -> [AgentEffect] {
        var effects = stopReply(turn)
        if openTurn == turn || openTurn == nil {
            resetSubtitle()
            effects.append(.publish(view))
        }
        return effects + [.diagnostic(.tiredSilenced(turn: Int(turn.value)))]
    }

    /// Clauses go to the revoicer only while the arbiter says PLAY; HOLD keeps them, DROP discards them.
    private mutating func speak(_ clauses: [String], at now: NovaInstant) -> [AgentEffect] {
        guard !clauses.isEmpty else { return [] }
        heldClauses += clauses.map { .speak($0) }
        return releaseHeld(at: now)
    }

    private mutating func releaseHeld(at now: NovaInstant) -> [AgentEffect] {
        guard !heldClauses.isEmpty else { return [] }
        let (decision, wake) = arbiter.decide(at: now, exempt: openTurn.map { relayTurns[$0] != nil } ?? false)
        switch decision {
        case .play:
            let clauses = heldClauses
            heldClauses = []
            arbiter.markReplyStarted()
            for case .playReplyAudio(let turn, let pcm) in clauses {
                let ms = pcm.sampleRate > 0 ? pcm.samples.count * 1000 / pcm.sampleRate : 0
                if let t = turnAudio, t.turn == turn { turnAudio?.ms += ms } else { turnAudio = (turn, now, ms) }
            }
            return clauses
        case .hold:
            return wake.map { [.schedule(.arbiter($0), at: $0)] } ?? []
        case .drop:
            heldClauses = []
            return []
        }
    }
}

extension PipelineOutput {
    /// The turn a held reply output belongs to.
    var turn: TurnID? {
        switch self {
        case .speechText(let t, _), .speechAudio(let t, _), .voided(let t): t
        default: nil
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
        case .setupComplete, .userTranscript, .toolCallCancellation, .resumptionHandle, .goAway, .failed, .closed,
             .turnEnded:
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
