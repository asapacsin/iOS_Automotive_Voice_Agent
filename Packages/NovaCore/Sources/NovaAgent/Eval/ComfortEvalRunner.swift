import NovaKit
import NovaPorts
import NovaTools

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

/// F-12 §14 item 4 (T-031a): sends each case as typed text through a real session with the real tools and checks.
/// Each run is a new session (new context) on a vehicle reset to the case's start. Text only: no microphone, and
/// her audio is timed but not played.
public actor ComfortEvalRunner {
    public static let attempts = 3
    public static let timeout = NovaDuration.seconds(20)

    let provider: any RealtimeProvider
    let config: SessionConfig
    let harness: ComfortEvalHarness
    let clock: any NovaClock
    let timeout: NovaDuration
    private let declared: Set<String>

    private struct Pending {
        let connection: Generation
        let history: [TextTurn]
        let sentence: String
        var sentAt: NovaInstant?
        var calls: [ComfortCallRecord] = []
        var reply = ""
        var firstAudio: NovaInstant?
        /// Text or audio after the last tool responses: the model has answered.
        var answered = false
        var timedOut = false
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private var connection = Generation.initial
    private var pending: Pending?
    private var consumer: Task<Void, Never>?
    private var cancelled = false

    public init(provider: any RealtimeProvider, config: SessionConfig, harness: ComfortEvalHarness,
                clock: any NovaClock, timeout: NovaDuration = ComfortEvalRunner.timeout) {
        self.provider = provider
        self.config = config
        self.harness = harness
        self.clock = clock
        self.timeout = timeout
        declared = Set(config.tools.map(\.name))
    }

    /// Stops after the run in progress.
    public func cancel() { cancelled = true }

    /// Every case `attempts` times, in order. `progress(done, total)` after each run.
    public func runAll(_ cases: [ComfortCase], attempts: Int = ComfortEvalRunner.attempts,
                       progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> [ComfortRun] {
        var runs: [ComfortRun] = []
        let total = cases.count * attempts
        for c in cases {
            for attempt in 1...attempts {
                if cancelled { break }
                runs.append(await run(c, attempt: attempt))
                await progress(runs.count, total)
            }
        }
        consumer?.cancel()
        consumer = nil
        return runs
    }

    public func run(_ c: ComfortCase, attempt: Int) async -> ComfortRun {
        if consumer == nil {
            let events = provider.events
            consumer = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
        }
        await harness.reset(c.start)
        connection = connection.next()
        let mine = connection
        pending = Pending(connection: mine, history: c.history, sentence: c.sentence)
        await provider.connect(config, resume: nil, connection: mine)
        let clock = clock, timeout = timeout
        let timer = Task { [weak self] in
            try? await clock.sleep(until: clock.now + timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(mine)
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if pending?.connection == mine, pending?.finished == false { pending?.waiter = done } else { done.resume() }
        }
        timer.cancel()
        await provider.close()
        let finished = pending
        pending = nil
        let end = await harness.snapshot()
        let first = zip(finished?.sentAt, finished?.firstAudio).map { Int(($1 - $0).milliseconds) }
        return ComfortRun(caseID: c.id, attempt: attempt, end: end, calls: finished?.calls ?? [], reply: finished?.reply ?? "",
                          firstAudioMs: first, timedOut: finished?.timedOut ?? true)
    }

    private func expire(_ id: Generation) {
        guard pending?.connection == id else { return }
        pending?.timedOut = true
        finish()
    }

    private func finish() {
        guard pending?.finished == false else { return }
        pending?.finished = true
        pending?.waiter?.resume()
        pending?.waiter = nil
    }

    private func handle(_ event: ProviderEvent) async {
        guard let p = pending, event.connection == p.connection, !p.finished else { return }
        switch event.event {
        case .setupComplete:
            guard p.sentAt == nil else { return }
            pending?.sentAt = clock.now
            await provider.sendText(p.history + [TextTurn(role: .user, text: p.sentence)], turnComplete: true)
        case .replyText(_, let text):
            pending?.reply += text
            pending?.answered = true
        case .replyAudio:
            if pending?.firstAudio == nil { pending?.firstAudio = clock.now }
            pending?.answered = true
        case .toolCalls(_, let calls):
            var responses: [ToolResponse] = []
            for call in calls {
                let result = await execute(call)
                pending?.calls.append(ComfortCallRecord(name: call.name, ok: result.ok, code: result.code, data: result.data))
                responses.append(ToolResponse(id: call.id, name: call.name, result: result))
            }
            pending?.answered = false
            await provider.sendToolResponses(responses)
        case .responseDone:
            if pending?.answered == true || pending?.calls.isEmpty == true { finish() }
        case .failed, .closed:
            pending?.timedOut = true
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

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
