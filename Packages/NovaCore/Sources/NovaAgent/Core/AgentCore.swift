import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
import Synchronization

/// Where the effects of `AgentState` go. Production wires the real provider, revoicer and playback;
/// tests record. Called in effect order, from the AgentCore actor.
public protocol AgentEffectSink: Sendable {
    func provider(_ command: ProviderCommand) async
    func flushPlayback(to epoch: Epoch)
    func cancelRevoicing(_ epoch: Epoch) async
    func newReply() async
    func speak(_ clause: String) async
    func publish(_ view: AgentViewState) async
    func diagnostic(_ event: DiagnosticEvent)
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
        let task = Task { [running] in
            let result = await executor.execute(call)
            _ = running.withLock { $0.removeValue(forKey: call.id) }
            if Task.isCancelled { return }
            await onFinish(result)
        }
        running.withLock { $0[call.id] = task }
    }

    /// `toolCallCancellation`: the result of a cancelled call is never sent.
    public func cancel(_ id: CallID) { running.withLock { $0.removeValue(forKey: id) }?.cancel() }
}

/// Turns timer effects into `.timer` events on the injected clock (ios-architecture §5.5).
final class TimerService: Sendable {
    private let clock: any NovaClock
    private let tasks = Mutex<[AgentTimer: Task<Void, Never>]>([:])

    init(clock: any NovaClock) { self.clock = clock }

    func schedule(_ timer: AgentTimer, at deadline: NovaInstant, fire: @escaping @Sendable (AgentTimer) async -> Void) {
        let clock = clock
        let task = Task {
            do { try await clock.sleep(until: deadline) } catch { return }
            await fire(timer)
        }
        tasks.withLock { $0.updateValue(task, forKey: timer) }?.cancel()
    }

    func cancel(_ timer: AgentTimer) { tasks.withLock { $0.removeValue(forKey: timer) }?.cancel() }
}

/// The single entry point for control-plane events (ios-architecture §5.3). Transitions are pure and
/// synchronous; the effects run afterwards, in order.
public actor AgentCore {
    public private(set) var state = AgentState()
    private let clock: any NovaClock
    private let sink: any AgentEffectSink
    private let tools: ToolRunner
    private let timers: TimerService

    public init(clock: any NovaClock, sink: any AgentEffectSink, tools: ToolRunner) {
        self.clock = clock
        self.sink = sink
        self.tools = tools
        timers = TimerService(clock: clock)
    }

    public func send(_ event: AgentEvent) async {
        let effects = state.handle(event, at: clock.now)
        for effect in effects { await run(effect) }
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
        }
    }
}
