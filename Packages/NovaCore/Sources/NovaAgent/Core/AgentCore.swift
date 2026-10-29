import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
import Synchronization

/// Where the effects of `AgentState` go. Production wires the real provider, revoicer and playback;
/// tests record. Called in effect order by the AgentCore drainer.
public protocol AgentEffectSink: Sendable {
    func provider(_ command: ProviderCommand) async
    func flushPlayback(to epoch: Epoch)
    func cancelRevoicing(_ epoch: Epoch) async
    func newReply() async
    func speak(_ clause: String) async
    func publish(_ view: AgentViewState) async
    func diagnostic(_ event: DiagnosticEvent)
    /// Fallback voice on the guidance lane (F-14). Must report `guidanceEnded(id)` through the playback
    /// events even when the sentence cannot be rendered.
    func speakGuidance(_ text: String, id: GuidanceID) async
    /// The uplink gate force-closes while `open` is false (F-08).
    func uplink(open: Bool)
    /// F-15a §2.5: utterances that begin while `muted` are not sent to the model (the gate still hears them).
    func modelUplink(muted: Bool)
}

/// Runs tool calls as child tasks (ios-architecture §5.1): cancellable, always ends in a `ToolResult`.
public final class ToolRunner: Sendable {
    private let executors: [String: any ToolExecutor]
    private let fallback: any ToolExecutor
    private let running = Mutex<[CallID: Task<Void, Never>]>([:])

    public init(executors: [String: any ToolExecutor], fallback: any ToolExecutor = NotYetExecutor()) {
        self.executors = executors
        self.fallback = fallback
    }

    public func start(_ call: ToolCall, onFinish: @escaping @Sendable (ToolResult) async -> Void) {
        let executor = executors[call.name] ?? fallback
        // Registered under the lock before it can finish, so its own removal always finds it.
        running.withLock { tasks in
            tasks[call.id] = Task { [self] in
                let result = await executor.execute(call)
                let current = running.withLock { $0.removeValue(forKey: call.id) != nil }
                // `toolCallCancellation`: the result of a cancelled call is never sent.
                guard current, !Task.isCancelled else { return }
                await onFinish(result)
            }
        }
    }

    public func cancel(_ id: CallID) { running.withLock { $0.removeValue(forKey: id) }?.cancel() }
}

/// Turns timer effects into `.timer` events on the injected clock (ios-architecture §5.5).
final class TimerService: Sendable {
    private let clock: any NovaClock
    private let tasks = Mutex<[AgentTimer: Task<Void, Never>]>([:])

    init(clock: any NovaClock) { self.clock = clock }

    func schedule(_ timer: AgentTimer, at deadline: NovaInstant, fire: @escaping @Sendable (AgentTimer) async -> Void) {
        let clock = clock
        tasks.withLock { tasks in
            tasks[timer]?.cancel()
            tasks[timer] = Task { [self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                guard self.tasks.withLock({ $0.removeValue(forKey: timer) != nil }) else { return }
                await fire(timer)
            }
        }
    }

    func cancel(_ timer: AgentTimer) { tasks.withLock { $0.removeValue(forKey: timer) }?.cancel() }
}

/// The single entry point for control-plane events (ios-architecture §5.3). Transitions are pure and
/// synchronous. Effects run afterwards, strictly in order: one drainer handles every event and its
/// effects before the next, so an event arriving while an effect awaits cannot cut in between
/// (a barge-in flush never lands between two clauses of the old reply).
public actor AgentCore {
    public private(set) var state = AgentState()
    private let clock: any NovaClock
    private let sink: any AgentEffectSink
    private let tools: ToolRunner
    private let timers: TimerService
    private var queue: [AgentEvent] = []
    private var draining = false

    public init(clock: any NovaClock, sink: any AgentEffectSink, tools: ToolRunner) {
        self.clock = clock
        self.sink = sink
        self.tools = tools
        timers = TimerService(clock: clock)
    }

    /// Enqueues `event`. Returns once it is handled, unless another caller is draining; then that
    /// caller handles it in order.
    public func send(_ event: AgentEvent) async {
        queue.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for effect in state.handle(next, at: clock.now) { await run(effect) }
        }
    }

    private func run(_ effect: AgentEffect) async {
        switch effect {
        case .provider(let command): await sink.provider(command)
        case .flushPlayback(let epoch): sink.flushPlayback(to: epoch)
        case .cancelRevoicing(let epoch): await sink.cancelRevoicing(epoch)
        case .newReply: await sink.newReply()
        case .speak(let clause): await sink.speak(clause)
        case .startTool(let turn, let call):
            tools.start(call) { [weak self] result in await self?.send(.toolFinished(turn, call, result)) }
        case .cancelTool(let id): tools.cancel(id)
        case .schedule(let timer, let deadline):
            timers.schedule(timer, at: deadline) { [weak self] timer in await self?.send(.timer(timer)) }
        case .cancelTimer(let timer): timers.cancel(timer)
        case .publish(let view): await sink.publish(view)
        case .diagnostic(let event): sink.diagnostic(event)
        case .speakGuidance(let text, let id): await sink.speakGuidance(text, id: id)
        case .uplink(let open): sink.uplink(open: open)
        case .modelUplinkMuted(let muted): sink.modelUplink(muted: muted)
        }
    }
}
