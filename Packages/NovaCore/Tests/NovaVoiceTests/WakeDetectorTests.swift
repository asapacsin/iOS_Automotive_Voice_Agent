import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaVoice

/// Fails `start` the first `failStarts` times; records frames; lets the test fire engine events.
final class ScriptedWakeEngine: WakeEngine {
    let starts = Mutex(0)
    let stops = Mutex(0)
    let frames = Mutex(0)
    let failStarts: Int
    let handler = Mutex<(@Sendable (WakeEngineEvent) -> Void)?>(nil)

    init(failStarts: Int = 0) { self.failStarts = failStarts }

    struct StartFailed: Error {}

    func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws {
        let n = starts.withLock { s -> Int in s += 1; return s }
        if n <= failStarts { throw StartFailed() }
        handler.withLock { $0 = onEvent }
    }

    func write(_ frame: PCMFrame16k) { frames.withLock { $0 += 1 } }
    func stop() async { stops.withLock { $0 += 1 } }
    func fire(_ event: WakeEngineEvent) { handler.withLock { $0 }?(event) }
}

private func settle() async { for _ in 0..<50 { await Task.yield() } }

@Suite("T-060 F-01 wake detector with bounded retry")
struct WakeDetectorTests {
    @Test("F-01 row 3: arm starts the engine (ready), a detection is one wake, frames only while running")
    func armWakeFeed() async {
        let engine = ScriptedWakeEngine()
        let detector = RetryingWakeDetector(engine: engine, clock: ManualClock())
        var it = detector.events.makeAsyncIterator()
        detector.feed(.silence)
        await detector.arm()
        #expect(await it.next() == .ready)
        detector.feed(.silence)
        #expect(engine.frames.withLock { $0 } == 1)
        engine.fire(.detected)
        #expect(await it.next() == .wake)
        await detector.disarm()
        engine.fire(.detected)              // late callback after disarm: dropped
        detector.feed(.silence)
        #expect(engine.frames.withLock { $0 } == 1)
        #expect(engine.stops.withLock { $0 } == 1)
    }

    @Test("F-01 row 3: start failures retry 1.5 s, 3 s, 6 s … then UNAVAILABLE after 6 attempts")
    func boundedRetry() async {
        let clock = ManualClock()
        let engine = ScriptedWakeEngine(failStarts: 100)
        let detector = RetryingWakeDetector(engine: engine, clock: clock)
        var it = detector.events.makeAsyncIterator()
        await detector.arm()
        let delays: [Int64] = [1_500, 3_000, 6_000, 12_000, 24_000]
        for (i, delay) in delays.enumerated() {
            #expect(await it.next() == .failed(attempt: i + 1))
            await settle()
            clock.advance(by: .milliseconds(delay - 1))
            await settle()
            #expect(engine.starts.withLock { $0 } == i + 1)
            clock.advance(by: .milliseconds(1))
            await settle()
        }
        #expect(await it.next() == .failed(attempt: 6))
        #expect(await it.next() == .unavailable)
        clock.advance(by: .seconds(60))
        await settle()
        #expect(engine.starts.withLock { $0 } == 6)
    }

    @Test("F-01: a runtime failure restarts after the backoff; success resets the count; disarm cancels a retry")
    func runtimeFailure() async {
        let clock = ManualClock()
        let engine = ScriptedWakeEngine()
        let detector = RetryingWakeDetector(engine: engine, clock: clock)
        var it = detector.events.makeAsyncIterator()
        await detector.arm()
        #expect(await it.next() == .ready)
        engine.fire(.failed)
        #expect(await it.next() == .failed(attempt: 1))
        await settle()
        clock.advance(by: .milliseconds(1_500))
        #expect(await it.next() == .ready)
        #expect(engine.starts.withLock { $0 } == 2)

        engine.fire(.failed)
        #expect(await it.next() == .failed(attempt: 1))   // count reset by the successful restart
        await detector.disarm()
        clock.advance(by: .seconds(30))
        await settle()
        #expect(engine.starts.withLock { $0 } == 2)
    }
}

@Suite("T-061 F-01 when the idle app listens for the wake word")
struct WakeListenPolicyTests {
    @Test("F-01: listens only in the foreground, idle, linked, configured, mic granted, and not given up")
    func policy() {
        var p = WakeListenPolicy()
        p.engineLinked = true; p.configured = true; p.micGranted = true
        #expect(p.shouldListen)
        for change in [\WakeListenPolicy.sessionRunning, \.gaveUp] {
            var q = p; q[keyPath: change] = true
            #expect(!q.shouldListen)
        }
        for change in [\WakeListenPolicy.foreground, \.engineLinked, \.configured, \.micGranted] {
            var q = p; q[keyPath: change] = false
            #expect(!q.shouldListen)
        }
    }
}
