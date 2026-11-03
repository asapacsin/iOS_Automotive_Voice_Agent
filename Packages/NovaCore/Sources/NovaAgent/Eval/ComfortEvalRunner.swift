import NovaKit
import NovaPorts
import NovaTools
import NovaVoice

/// What the runner needs from the app: a simulated vehicle it can reset and read, and the session's tools
/// (already behind `PolicedVehiclePort`, so the item 11 checks run as in a drive).
public struct ComfortEvalHarness: Sendable {
    public let reset: @Sendable (ComfortVehicleState) async -> Void
    public let snapshot: @Sendable () async -> ComfortVehicleState
    public let tools: [String: any ToolExecutor]

    public init(reset: @escaping @Sendable (ComfortVehicleState) async -> Void,
                snapshot: @escaping @Sendable () async -> ComfortVehicleState, tools: [String: any ToolExecutor]) {
        self.reset = reset
        self.snapshot = snapshot
        self.tools = tools
    }
}

/// F-12 §14 item 4 (T-031a), §15 items 1-3 (T-031d): sends each case as typed text through a real session with the
/// real tools and checks. Each run is a new session (new context) on a vehicle reset to the case's start. Text only:
/// no microphone, and her audio is timed but not played. Connecting has its own limit; the answer limit starts at
/// `sendText`. A session that fails is retried once; failing again is `infrastructure` and is not scored.
public actor ComfortEvalRunner {
    public static let attempts = 3
    public static let timeout = NovaDuration.seconds(20)
    public static let connectTimeout = NovaDuration.seconds(10)

    let provider: any RealtimeProvider
    let config: SessionConfig
    let harness: ComfortEvalHarness
    let clock: any NovaClock
    let timeout: NovaDuration
    let connectTimeout: NovaDuration
    private let declared: Set<String>

    private struct Pending {
        let connection: Generation
        let history: [TextTurn]
        let sentence: String
        var sentAt: NovaInstant?
        var calls: [ComfortCallRecord] = []
        var reply = ""
        var stages = ComfortStages()
        var firstToolResponseAt: NovaInstant?
        /// Something of the answer arrived (text, audio or a tool call) since the sentence.
        var started = false
        /// Tool responses were sent and nothing has answered them yet.
        var awaitingAfterTool = false
        /// Text or audio after the last tool responses: the model has answered.
        var answered = false
        /// Between `responseStarted` and `responseDone`.
        var turnOpen = false
        var turnEnd: TurnEndReason?
        var problem: ComfortRunProblem?
        /// §16 item 10: a correction was sent after an unbacked first reply; the run waits for the corrected turn.
        var correctionSent = false
        var firstReply = ""
        /// After the correction, events of the first turn (its late `responseDone`) are ignored until a new turn opens.
        var awaitingNewTurn = false
        var callsBeforeCorrection = 0
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private var connection = Generation.initial
    private var pending: Pending?
    private var consumer: Task<Void, Never>?
    private var cancelled = false
    /// §16 item 9: set by the app when it leaves the foreground; the run in progress is repeated.
    private var interruptedNow = false
    /// Interrupted runs, kept for the report's count.
    private var interruptedRuns: [ComfortRun] = []
    public static let maxRepeats = 3

    public init(provider: any RealtimeProvider, config: SessionConfig, harness: ComfortEvalHarness,
                clock: any NovaClock, timeout: NovaDuration = ComfortEvalRunner.timeout,
                connectTimeout: NovaDuration = ComfortEvalRunner.connectTimeout) {
        self.provider = provider
        self.config = config
        self.harness = harness
        self.clock = clock
        self.timeout = timeout
        self.connectTimeout = connectTimeout
        declared = Set(config.tools.map(\.name))
    }

    /// Stops after the run in progress.
    public func cancel() { cancelled = true }

    /// §16 item 9: the app left the foreground; the run in progress is marked `interrupted` and repeated.
    public func markInterrupted() { interruptedNow = true }

    /// Every case `attempts` times, in order. `progress(done, total)` after each run.
    public func runAll(_ cases: [ComfortCase], attempts: Int = ComfortEvalRunner.attempts,
                       progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> [ComfortRun] {
        var runs: [ComfortRun] = []
        let total = cases.count * attempts
        for c in cases {
            for attempt in 1...attempts {
                if cancelled { break }
                let r = await run(c, attempt: attempt)
                runs += interruptedRuns
                interruptedRuns = []
                runs.append(r)
                await progress(runs.filter { $0.problem != .interrupted }.count, total)
            }
        }
        consumer?.cancel()
        consumer = nil
        return runs
    }

    /// One scored run: a failed session is retried once, then reported as `infrastructure`.
    public func run(_ c: ComfortCase, attempt: Int) async -> ComfortRun {
        var result = await connected(c, attempt: attempt)
        var repeats = 0
        while result.problem == .interrupted, repeats < Self.maxRepeats, !cancelled {
            interruptedRuns.append(result)
            repeats += 1
            result = await connected(c, attempt: attempt)
        }
        return result
    }

    private func connected(_ c: ComfortCase, attempt: Int) async -> ComfortRun {
        let first = await once(c, attempt: attempt)
        guard first.problem == .sessionFailed else { return first }
        let second = await once(c, attempt: attempt)
        guard second.problem == .sessionFailed else { return second }
        return ComfortRun(caseID: second.caseID, attempt: attempt, end: second.end, calls: second.calls, reply: second.reply,
                          stages: second.stages, problem: .infrastructure, turnEnd: second.turnEnd)
    }

    private func once(_ c: ComfortCase, attempt: Int) async -> ComfortRun {
        if consumer == nil {
            let events = provider.events
            consumer = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
        }
        await harness.reset(c.start)
        interruptedNow = false
        connection = connection.next()
        let mine = connection
        pending = Pending(connection: mine, history: c.history, sentence: c.sentence)
        let connectTimer = timer(after: connectTimeout, mine, sent: false)
        await provider.connect(config, resume: nil, connection: mine)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if pending?.connection == mine, pending?.finished == false { pending?.waiter = done } else { done.resume() }
        }
        connectTimer.cancel()
        answerTimer?.cancel()
        answerTimer = nil
        await provider.close()
        let finished = pending
        pending = nil
        let end = await harness.snapshot()
        let problem: ComfortRunProblem? = interruptedNow ? .interrupted
            : finished == nil ? .sessionFailed : finished?.problem
        return ComfortRun(caseID: c.id, attempt: attempt, end: end, calls: finished?.calls ?? [], reply: finished?.reply ?? "",
                          stages: finished?.stages ?? ComfortStages(), problem: problem,
                          turnEnd: finished?.turnEnd, firstReplyClaim: finished?.correctionSent ?? false)
    }

    private var answerTimer: Task<Void, Never>?

    private func timer(after limit: NovaDuration, _ id: Generation, sent: Bool) -> Task<Void, Never> {
        let clock = clock
        return Task { [weak self] in
            try? await clock.sleep(until: clock.now + limit)
            guard !Task.isCancelled else { return }
            await self?.expire(id, sent: sent)
        }
    }

    private func expire(_ id: Generation, sent: Bool) {
        guard let p = pending, p.connection == id, !p.finished else { return }
        if !sent {
            // The connect limit only counts while no sentence has been sent.
            guard p.sentAt == nil else { return }
            pending?.problem = .sessionFailed
        } else if p.correctionSent {
            // No corrected answer in time: the first reply (and its claim) is the final one.
            if p.reply.isEmpty { pending?.reply = p.firstReply }
        } else if p.awaitingAfterTool {
            pending?.problem = .stuckAfterTool
        } else if p.started {
            pending?.problem = .slowAnswer
        } else {
            pending?.problem = .noAnswer
        }
        finish()
    }

    private func finish() {
        guard pending?.finished == false else { return }
        pending?.finished = true
        pending?.waiter?.resume()
        pending?.waiter = nil
    }

    /// The reply has ended. §16 item 10: an unbacked claim gets the drive's correction, once, in the same session,
    /// with 20 s more; otherwise the run is done.
    private func answerComplete() async {
        guard let p = pending, !p.finished else { return }
        if p.correctionSent, !p.awaitingNewTurn, p.reply.isEmpty, p.calls.count == p.callsBeforeCorrection {
            // The corrected turn said nothing: keep the first reply.
            pending?.reply = p.firstReply
        }
        let run = ComfortRun(caseID: "", attempt: 0, end: .default, calls: p.calls, reply: p.reply, firstAudioMs: nil)
        if !p.correctionSent, ComfortScorer.unbackedClaim(run) {
            let failed = p.calls.contains { $0.acts && !$0.ok }
            let reason: CorrectionReason = failed ? .claimAfterFailure : .unverifiedClaim
            pending?.correctionSent = true
            pending?.firstReply = p.reply
            pending?.reply = ""
            pending?.answered = false
            pending?.awaitingNewTurn = true
            pending?.callsBeforeCorrection = p.calls.count
            answerTimer?.cancel()
            answerTimer = timer(after: timeout, p.connection, sent: true)
            await provider.sendText([TextTurn(role: .user, text: reason.instruction)], turnComplete: true)
            return
        }
        if p.stages.answerDoneMs == nil { pending?.stages.answerDoneMs = ms(since: p.sentAt) }
        finish()
    }

    private func current(_ id: Generation) -> Bool { pending?.connection == id && pending?.finished == false }

    private func ms(since start: NovaInstant?) -> Int? {
        start.map { Int((clock.now - $0).milliseconds) }
    }

    private func handle(_ event: ProviderEvent) async {
        guard let p = pending, event.connection == p.connection, !p.finished else { return }
        if p.sentAt != nil, p.stages.firstEventMs == nil, event.event.isAnswer {
            pending?.stages.firstEventMs = ms(since: p.sentAt)
        }
        switch event.event {
        case .setupComplete:
            guard p.sentAt == nil else { return }
            pending?.sentAt = clock.now
            answerTimer = timer(after: timeout, p.connection, sent: true)
            await provider.sendText(p.history + [TextTurn(role: .user, text: p.sentence)], turnComplete: true)
        case .replyText(_, let text):
            pending?.reply += text
            pending?.started = true
            pending?.answered = true
            pending?.awaitingAfterTool = false
        case .audioDone:
            // §16 item 1: generationComplete ends the reply when an answer arrived and no tool response is awaited.
            guard !p.awaitingNewTurn else { return }
            if p.answered, !p.awaitingAfterTool { await answerComplete() }
        case .replyAudio:
            pending?.awaitingNewTurn = false
            if p.stages.firstAudioMs == nil { pending?.stages.firstAudioMs = ms(since: p.sentAt) }
            if p.firstToolResponseAt != nil, p.stages.toolToAudioMs == nil {
                pending?.stages.toolToAudioMs = ms(since: p.firstToolResponseAt)
            }
            pending?.started = true
            pending?.answered = true
            pending?.awaitingAfterTool = false
        case .toolCalls(_, let calls):
            pending?.awaitingNewTurn = false
            if p.stages.firstToolMs == nil { pending?.stages.firstToolMs = ms(since: p.sentAt) }
            pending?.started = true
            var responses: [ToolResponse] = []
            for call in calls {
                let result = await execute(call)
                // The actor may have moved on to the next run during the await.
                guard current(p.connection) else { return }
                pending?.calls.append(ComfortCallRecord(name: call.name, ok: result.ok, code: result.code, data: result.data))
                responses.append(ToolResponse(id: call.id, name: call.name, result: result))
            }
            pending?.answered = false
            pending?.awaitingAfterTool = true
            if pending?.firstToolResponseAt == nil { pending?.firstToolResponseAt = clock.now }
            await provider.sendToolResponses(responses)
        case .turnEnded(let reason):
            pending?.turnEnd = reason
            // A turn that closed with nothing open: no responseDone follows, so the run ends here.
            guard !p.turnOpen else { return }
            if p.correctionSent {
                pending?.awaitingNewTurn = false
                await answerComplete()
                return
            }
            if !p.answered { pending?.problem = p.awaitingAfterTool ? .stuckAfterTool : .noAnswer }
            finish()
        case .responseStarted:
            pending?.turnOpen = true
            pending?.awaitingNewTurn = false
        case .responseDone:
            pending?.turnOpen = false
            if p.awaitingNewTurn { return }
            if p.correctionSent {
                if p.answered || p.calls.count == p.callsBeforeCorrection { await answerComplete() }
                return
            }
            if pending?.answered == true { await answerComplete() } else if pending?.calls.isEmpty == true {
                // A turn with no words, audio or call is no answer, not a noTool decision.
                pending?.problem = .noAnswer
                finish()
            }
        case .failed, .closed:
            // Item 1: a failed or closed session is the connection, whenever it happens; retried once.
            pending?.problem = .sessionFailed
            finish()
        default:
            break
        }
    }

    /// The session's own rules: a tool it did not declare is unknown; arguments are validated as in a drive.
    private func execute(_ call: ToolCall) async -> ToolResult {
        guard declared.contains(call.name) else { return ToolDispatcher.failure(.unknownTool) }
        if let code = ToolCatalog.validate(call) { return ToolDispatcher.failure(code) }
        let result = await (harness.tools[call.name] ?? NotYetExecutor()).execute(call)
        return ToolDispatcher().finish(call, result)
    }
}

extension RealtimeEvent {
    /// Part of the model's answer (for the first-event stage).
    var isAnswer: Bool {
        switch self {
        case .responseStarted, .replyText, .replyAudio, .toolCalls, .turnEnded, .responseDone: true
        default: false
        }
    }
}
