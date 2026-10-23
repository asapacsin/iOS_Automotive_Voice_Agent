import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

/// Fake shell: keeps scheduled timers, fires them as time passes, records connects.
struct SessionHarness {
    var session = VoiceSession()
    var now = NovaInstant.zero
    var timers: [SessionTimer.Kind: (SessionTimer, NovaInstant)] = [:]
    var log: [SessionEffect] = []
    var connects: [(Generation, String?)] { log.compactMap { if case .connect(let g, let h) = $0 { (g, h) } else { nil } } }

    @discardableResult
    mutating func send(_ input: SessionInput) -> [SessionEffect] {
        let effects = session.handle(input, at: now)
        log += effects
        for effect in effects {
            switch effect {
            case .schedule(let t, let at): timers[t.kind] = (t, at)
            case .cancelTimer(let kind): timers[kind] = nil
            default: break
            }
        }
        return effects
    }

    mutating func server(_ event: RealtimeEvent) { send(.realtime(event, connection: session.connection)) }

    mutating func advance(by d: NovaDuration) {
        let target = now + d
        while let (kind, (timer, at)) = timers.min(by: { $0.value.1 < $1.value.1 }), at <= target {
            now = at
            timers[kind] = nil
            send(.timerFired(timer))
        }
        now = target
    }

    mutating func connected() {
        send(.start)
        server(.setupComplete)
    }
}

@Suite("T-014 F-05 voice session")
struct VoiceSessionTests {
    @Test("F-05 normal turn walks the §1 states")
    func normalTurn() {
        var h = SessionHarness()
        h.send(.start)
        #expect(h.session.state == .connecting && h.session.state.chip == .processing)
        h.server(.setupComplete)
        #expect(h.session.state == .listening)
        h.send(.speechStarted)
        #expect(h.session.state == .userSpeaking)
        h.send(.speechStopped)
        #expect(h.session.state == .thinking)
        h.server(.replyText(.initial, "好的"))
        #expect(h.session.state == .speaking)
        h.server(.responseDone(.initial, outcome: .completed))
        #expect(h.session.state == .listening)
    }

    @Test("F-05 qualified barge-in goes to USER_SPEAKING; unqualified stays SPEAKING")
    func bargeIn() {
        var h = SessionHarness()
        h.connected()
        h.send(.speechStarted); h.send(.speechStopped)
        h.server(.replyAudio(.initial, PCMBuffer(sampleRate: 24_000, samples: [0])))
        h.send(.bargeIn(qualified: false))
        #expect(h.session.state == .speaking)
        h.send(.bargeIn(qualified: true))
        #expect(h.session.state == .userSpeaking)
    }

    @Test("F-05 setupComplete must arrive within 10 s, else TIMEOUT and a retry")
    func setupTimeout() {
        var h = SessionHarness()
        h.send(.start)
        h.advance(by: .milliseconds(9_999))
        #expect(h.session.state == .connecting)
        h.advance(by: .milliseconds(1))
        #expect(h.log.contains(.diagnostic(.setupTimeout)))
        #expect(h.session.state == .reconnecting)
    }

    @Test("F-05 F-24 socket drop mid-turn reconnects with the handle and the chip shows PROCESSING")
    func dropMidTurn() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h-1"))
        h.send(.speechStarted); h.send(.speechStopped)
        h.server(.closed)
        #expect(h.session.state == .reconnecting)
        #expect(h.session.state.chip == .processing)
        #expect(!h.log.contains(.stateChanged(.error)))
        h.advance(by: .milliseconds(200))
        #expect(h.connects.last?.1 == "h-1")
        h.server(.setupComplete)
        #expect(h.session.state == .listening)
        #expect(h.session.policy.attempts == 0)
    }

    @Test("F-05 an auth error is terminal: no retry, config message shown")
    func authTerminal() {
        var h = SessionHarness()
        h.send(.start)
        h.server(.failed(RealtimeError(.auth)))
        #expect(h.session.state == .error)
        #expect(h.log.contains(.showConfigError(.auth)))
        h.advance(by: .minutes(5))
        #expect(h.connects.count == 1)
    }

    @Test("F-05 every terminal code skips retry")
    func terminalCodes() {
        for code in RealtimeErrorCode.allCases where !code.isRetryable {
            var h = SessionHarness()
            h.connected()
            h.server(.failed(RealtimeError(code)))
            #expect(h.session.state == .error, "\(code)")
            #expect(h.session.policy.attempts == 0)
        }
    }

    @Test("F-05 1007 clears the resumption handle before reconnecting")
    func resumeUnavailable() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h-1"))
        h.server(.failed(RealtimeError(.resumeUnavailable)))
        h.advance(by: .seconds(1))
        #expect(h.connects.last?.1 == nil)
    }

    @Test("F-05 stop closes and forgets the handle; late events of the old socket are ignored")
    func stop() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h-1"))
        let old = h.session.connection
        h.send(.stop)
        #expect(h.session.state == .disconnected && h.session.resumptionHandle == nil)
        #expect(h.send(.realtime(.failed(RealtimeError(.disconnect)), connection: old)).isEmpty)
        #expect(h.timers.isEmpty)
    }
}

@Suite("T-014 F-24 reconnect policy")
struct ReconnectPolicyTests {
    @Test("F-24 5 attempts at 200, 400, 800, 1600, 3200 ms, then ERROR")
    func schedule() {
        var h = SessionHarness()
        h.connected()
        h.server(.closed)
        var delays: [NovaDuration] = []
        for effect in h.log { if case .diagnostic(.reconnectAttempt(_, let d)) = effect { delays.append(d) } }
        for _ in 0..<5 {
            guard let (_, at) = h.timers[.reconnectDelay] else { break }
            h.advance(by: at - h.now)
            h.server(.failed(RealtimeError(.connection)))
        }
        delays = h.log.compactMap { if case .diagnostic(.reconnectAttempt(_, let d)) = $0 { d } else { nil } }
        #expect(delays.map(\.milliseconds) == [200, 400, 800, 1600, 3200])
        #expect(h.session.state == .error)
        #expect(!h.log.contains { if case .showConfigError = $0 { true } else { false } })
        #expect(h.connects.count == 1 + 5)
    }

    @Test("F-24 the delay doubles to the 8 s cap")
    func cap() {
        let t = ReconnectTuning()
        #expect(t.delay(beforeAttempt: 6).milliseconds == 6400)
        #expect(t.delay(beforeAttempt: 7) == .seconds(8))
        #expect(t.delay(beforeAttempt: 20) == .seconds(8))
    }

    @Test("F-24 a second error from the same dying socket joins the reconnect in flight")
    func secondErrorJoins() {
        var h = SessionHarness()
        h.connected()
        let dying = h.session.connection
        h.send(.realtime(.failed(RealtimeError(.wsFailed)), connection: dying))
        #expect(h.send(.realtime(.closed, connection: dying)).isEmpty)
        #expect(h.session.policy.attempts == 1)
    }

    @Test("F-24 terminal codes are never retried by the policy")
    func policyTerminal() {
        var p = ReconnectPolicy()
        #expect(p.next(after: .quota) == .giveUp)
        #expect(p.next(after: .dns) == .retry(attempt: 1, after: .milliseconds(200)))
    }

    @Test("F-24 goAway moves to a fresh socket resuming with the handle")
    func goAway() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h-2"))
        h.server(.goAway(timeLeft: .seconds(30)))
        h.advance(by: .seconds(1))
        #expect(h.connects.last?.1 == "h-2")
        #expect(h.session.state == .reconnecting)
    }

    @Test("chip mapping equals AssistantUiStateMapper")
    func chips() {
        #expect(SessionUIState.allCases.map(\.chip) ==
                [.idle, .processing, .listening, .listening, .processing, .speaking, .processing, .error])
    }
}
