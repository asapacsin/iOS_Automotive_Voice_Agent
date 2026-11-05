import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-016j F-24 §15 retry window, give-up, kept handle")
struct SessionGiveUpTests {
    /// Fails every attempt at once; returns the start time of each reconnect attempt.
    @discardableResult
    func failUntilGiveUp(_ h: inout SessionHarness, code: RealtimeErrorCode = .connection) -> [Int64] {
        var starts: [Int64] = []
        while let (_, at) = h.timers[.reconnectDelay] {
            h.advance(by: at - h.now)
            starts.append(h.now.milliseconds)
            h.server(.failed(RealtimeError(code)))
        }
        return starts
    }

    func gaveUp(_ h: SessionHarness) -> [DiagnosticEvent] {
        h.log.compactMap { if case .diagnostic(let e) = $0, case .sessionGaveUp = e { e } else { nil } }
    }

    func kept(_ h: SessionHarness) -> [String?] {
        h.log.compactMap { if case .keepHandle(let k) = $0 { k } else { nil } }
    }

    @Test("§15 row 1: no attempt limit, delays capped at 8 s past 5 attempts, last starts before 60 s, then give-up")
    func row1Window() {
        var h = SessionHarness()
        h.connected()
        h.server(.closed)  // first failure at t=0
        let starts = failUntilGiveUp(&h)
        let delays = h.log.compactMap { if case .diagnostic(.reconnectAttempt(_, let d)) = $0 { d.milliseconds } else { nil } }
        #expect(delays == [200, 400, 800, 1600, 3200, 6400, 8000, 8000, 8000, 8000, 8000])
        #expect(starts.count == 11 && starts.count > 5)
        #expect(starts.allSatisfy { $0 < 60_000 })
        #expect(gaveUp(h) == [.sessionGaveUp(ms: 52_600, attempts: 11, code: .connection)])
        #expect(h.session.state == .disconnected)
        #expect(h.log.contains(.offlineEnded))
        #expect(!h.log.contains(.stateChanged(.error)))
        #expect(h.timers.isEmpty)
    }

    @Test("§15 row 2: setup completes after 30 s of failures; a new failure starts the window again")
    func row2SetupClears() {
        var h = SessionHarness()
        h.connected()
        h.server(.closed)
        while h.now.milliseconds < 30_000, let (_, at) = h.timers[.reconnectDelay] {
            h.advance(by: at - h.now)
            h.server(.failed(RealtimeError(.connection)))
        }
        let (_, at) = h.timers[.reconnectDelay]!
        h.advance(by: at - h.now)
        h.server(.setupComplete)
        #expect(h.session.state == .listening && h.session.policy.firstFailure == nil)
        let restart = h.now.milliseconds
        h.server(.closed)
        #expect(h.session.policy.firstFailure?.milliseconds == restart)
        failUntilGiveUp(&h)
        #expect(gaveUp(h) == [.sessionGaveUp(ms: 52_600, attempts: 11, code: .connection)])
        #expect(h.now.milliseconds == restart + 52_600)
    }

    @Test("§15 row 3: 50 s of failures, networkLost, later networkRestored: §14 waiting, fresh window on restore")
    func row3OfflineFreshWindow() {
        var h = SessionHarness()
        h.connected()
        h.server(.closed)
        while h.now.milliseconds < 40_000, let (_, at) = h.timers[.reconnectDelay] {
            h.advance(by: at - h.now)
            h.server(.failed(RealtimeError(.connection)))
        }
        h.advance(by: .milliseconds(50_000 - h.now.milliseconds))
        #expect(h.session.state == .reconnecting && gaveUp(h).isEmpty)
        h.send(.networkLost)
        #expect(h.session.waitingForNetwork)
        let before = h.connects.count
        h.advance(by: .seconds(120))
        #expect(h.connects.count == before && gaveUp(h).isEmpty)
        h.send(.networkRestored)
        #expect(h.connects.count == before + 1)
        let restored = h.now.milliseconds
        h.server(.failed(RealtimeError(.connection)))
        #expect(h.session.policy.firstFailure?.milliseconds == restored)
        failUntilGiveUp(&h)
        #expect(gaveUp(h) == [.sessionGaveUp(ms: 52_600, attempts: 11, code: .connection)])
    }

    @Test("§15 row 4: auth or quota is ERROR at once, no retry and no kept handle")
    func row4Terminal() {
        for code in [RealtimeErrorCode.auth, .quota] {
            var h = SessionHarness()
            h.connected()
            h.server(.resumptionHandle("h1"))
            h.server(.failed(RealtimeError(code)))
            #expect(h.session.state == .error)
            #expect(h.session.policy.attempts == 0 && h.timers[.reconnectDelay] == nil)
            #expect(kept(h).isEmpty && !h.log.contains(.offlineEnded) && gaveUp(h).isEmpty)
        }
    }

    @Test("§15 row 5: give-up with a handle keeps it; the next start sends it once and reports resumed")
    func row5KeepAndResume() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h1"))
        h.server(.closed)
        failUntilGiveUp(&h)
        #expect(kept(h) == ["h1"])
        let keepIndex = h.log.firstIndex(of: .keepHandle("h1"))!
        #expect(keepIndex < h.log.firstIndex(of: .offlineEnded)!)
        #expect(h.session.state == .disconnected && h.session.resumptionHandle == nil)

        var store = KeptResumption()
        store.keep(kept(h)[0], at: h.now)
        let resume = store.take(at: h.now + .minutes(5))
        #expect(resume == SessionResume(handle: "h1"))
        #expect(store.take(at: h.now + .minutes(6)) == nil)  // once

        var next = SessionHarness(session: VoiceSession(resume: resume))
        next.send(.start)
        #expect(next.connects.map(\.1) == ["h1"])
        next.server(.setupComplete)
        #expect(next.log.contains(.diagnostic(.sessionResume(handle: true, result: .resumed))))
        next.server(.resumptionHandle("h2"))
        next.server(.closed)
        next.advance(by: .seconds(1))
        #expect(next.connects.map(\.1) == ["h1", "h2"])
        next.server(.setupComplete)
        #expect(next.log.filter { if case .diagnostic(.sessionResume) = $0 { true } else { false } }.count == 1)
    }

    @Test("§15 row 6: kept handle and the driver stops / 2 hours pass / the server rejects it")
    func row6NotSent() {
        var store = KeptResumption()
        store.keep("h1", at: .zero)
        store.drop()
        #expect(store.take(at: .zero + .seconds(1)) == nil)

        store.keep("h1", at: .zero)
        #expect(store.take(at: .zero + .minutes(120)) == SessionResume(handle: nil))
        store.keep("h1", at: .zero)
        #expect(store.take(at: .zero + .minutes(119)) == SessionResume(handle: "h1"))

        var none = SessionHarness(session: VoiceSession(resume: SessionResume(handle: nil)))
        none.send(.start)
        #expect(none.connects.map(\.1) == [nil])
        none.server(.setupComplete)
        #expect(none.log.contains(.diagnostic(.sessionResume(handle: false, result: .none))))

        var h = SessionHarness(session: VoiceSession(resume: SessionResume(handle: "h1")))
        h.send(.start)
        h.server(.failed(RealtimeError(.resumeUnavailable)))
        h.advance(by: .seconds(1))
        #expect(h.connects.map(\.1) == ["h1", nil])
        h.server(.setupComplete)
        #expect(h.log.contains(.diagnostic(.sessionResume(handle: true, result: .rejected))))
        #expect(!h.log.contains(.diagnostic(.resumed(handle: true))))
    }

    @Test("§15 item 4: the offline cap keeps the handle too; a plain start reports nothing")
    func offlineCapKeeps() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h1"))
        h.send(.networkLost)
        h.advance(by: .seconds(600))
        #expect(kept(h) == ["h1"])
        var plain = SessionHarness()
        plain.connected()
        #expect(!plain.log.contains { if case .diagnostic(.sessionResume) = $0 { true } else { false } })
    }

    @Test("§15 item 6: chip text follows the wake listener")
    func chip() {
        #expect(SessionEndedChip.text(wakeArmed: true) == "连接断开，说“你好小诺”重连")
        #expect(SessionEndedChip.text(wakeArmed: false) == "连接断开，点按重连")
    }

    @Test("§15 item 8: log lines carry numbers and codes only")
    func logLines() {
        #expect(DiagnosticEvent.sessionGaveUp(ms: 52_600, attempts: 11, code: .connection).logLine
                == "session gave-up ms=52600 attempts=11 code=CONNECTION")
        #expect(DiagnosticEvent.sessionResume(handle: true, result: .rejected).logLine
                == "session resume handle=yes result=rejected")
        for code in RealtimeErrorCode.allCases {
            #expect((code.retryableCode != nil) == code.isRetryable)
            if let r = code.retryableCode { #expect(r.rawValue == code.rawValue) }
        }
    }
}
