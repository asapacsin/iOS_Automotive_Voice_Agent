import NovaKit
import NovaPorts
import Synchronization

/// The vendor wake engine behind `RetryingWakeDetector` (T-060). The iFlytek adapter implements it in
/// NovaWakeIflytek; tests use a scripted engine. `start` loads the model and begins listening; a
/// detection or a runtime failure arrives through `onEvent`.
public protocol WakeEngine: Sendable {
    func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws
    func write(_ frame: PCMFrame16k)
    func stop() async
}

public enum WakeEngineEvent: Sendable, Hashable {
    case detected
    case failed
}

/// F-01 wake detector (`A/wake/IflytekWakeWordDetector.kt:20,279-286`): arming starts the engine;
/// a start or runtime failure retries with `BoundedRetry` (1.5 s doubling to 30 s, 6 attempts), then
/// reports `.unavailable` and stops trying (the talk button still works). Frames reach the engine only
/// while it runs; a wake after `disarm()` is dropped.
public final class RetryingWakeDetector: WakeWordDetector {
    public let events: AsyncStream<WakeEvent>
    private let continuation: AsyncStream<WakeEvent>.Continuation
    private let engine: any WakeEngine
    private let clock: any NovaClock

    private struct State {
        var armed = false
        var running = false
        /// Bumped by every arm/disarm, so a late retry or callback of an older arming does nothing.
        var token: UInt64 = 0
        var retry: BoundedRetry
        var pending: Task<Void, Never>?
    }

    private let state: Mutex<State>

    public init(engine: any WakeEngine, clock: any NovaClock, tuning: WakeRetryTuning = WakeRetryTuning()) {
        self.engine = engine
        self.clock = clock
        state = Mutex(State(retry: BoundedRetry(tuning: tuning)))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public func arm() async {
        let token = state.withLock { s -> UInt64? in
            guard !s.armed else { return nil }
            s.armed = true
            s.token += 1
            return s.token
        }
        guard let token else { return }
        await attempt(token)
    }

    public func disarm() async {
        let wasRunning = state.withLock { s -> Bool in
            s.armed = false
            s.token += 1
            s.pending?.cancel()
            s.pending = nil
            defer { s.running = false }
            return s.running
        }
        if wasRunning { await engine.stop() }
    }

    public func feed(_ frame: PCMFrame16k) {
        guard state.withLock({ $0.running }) else { return }
        engine.write(frame)
    }

    private func current(_ token: UInt64) -> Bool { state.withLock { $0.armed && $0.token == token } }

    private func attempt(_ token: UInt64) async {
        guard current(token) else { return }
        do {
            try await engine.start { [weak self] event in self?.engineEvent(event, token: token) }
        } catch {
            await failure(token)
            return
        }
        let started = state.withLock { s -> Bool in
            guard s.armed && s.token == token else { return false }
            s.running = true
            s.retry.succeeded()
            return true
        }
        guard started else {
            // Disarmed while starting.
            await engine.stop()
            return
        }
        continuation.yield(.ready)
    }

    private func engineEvent(_ event: WakeEngineEvent, token: UInt64) {
        guard current(token) else { return }
        switch event {
        case .detected:
            continuation.yield(.wake)
        case .failed:
            let task = Task { [weak self] in
                guard let self else { return }
                await self.engine.stop()
                self.state.withLock { $0.running = false }
                await self.failure(token)
            }
            state.withLock { $0.pending = task }
        }
    }

    private func failure(_ token: UInt64) async {
        let next = state.withLock { s -> (attempt: Int, delay: NovaDuration?)? in
            guard s.armed && s.token == token else { return nil }
            let delay = s.retry.failed()
            return (s.retry.failures, delay)
        }
        guard let next else { return }
        continuation.yield(.failed(attempt: next.attempt))
        guard let delay = next.delay else {
            continuation.yield(.unavailable)
            return
        }
        let deadline = clock.now + delay
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(until: deadline) } catch { return }
            await self.attempt(token)
        }
        state.withLock { s in if s.token == token { s.pending = task } else { task.cancel() } }
    }
}
