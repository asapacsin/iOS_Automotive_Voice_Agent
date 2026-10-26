import Testing
@testable import NovaKit
@testable import NovaVoice

private func at(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }
private let g1 = GuidanceID(1), g2 = GuidanceID(2), g3 = GuidanceID(3)

/// Sentences spoken by each voice, from relay outputs plus the assistant readings the test drives.
private func fallbacks(_ outputs: [GuidanceRelayOutput]) -> [GuidanceID] {
    outputs.compactMap { if case .speakFallback(let id, _, _) = $0 { id } else { nil } }
}

private func sent(_ outputs: [GuidanceRelayOutput]) -> [GuidanceID] {
    outputs.compactMap { if case .sendToModel(let id, _) = $0 { id } else { nil } }
}

@Suite("T-051 F-14 guidance relay")
struct GuidanceRelayTests {
    @Test("F-14 §10 row 1: each sentence is spoken exactly once, by one voice, one at a time")
    func exactlyOnce() {
        var r = GuidanceRelay()
        var out = r.enqueue("前方300米右转", id: g1, at: at(0), conditions: .init())
        #expect(sent(out) == [g1] && fallbacks(out).isEmpty)
        // A second sentence waits while the first is pending: never two at once.
        out = r.enqueue("进入辅路", id: g2, at: at(100), conditions: .init())
        #expect(out.isEmpty && r.queue.count == 1)
        _ = r.assistantStarted(at: at(600))
        r.assistantText("前方300米右转。")
        // The deadline timer of a started reading changes nothing.
        let v1 = r.timerFired(g1, at: at(1200), conditions: .init())
        #expect(v1.isEmpty)
        out = r.assistantFinished(at: at(2000), conditions: .init())
        // g2 waited 1.9 s, past its 1.2 s deadline: Amap's voice speaks it, she does not.
        #expect(sent(out).isEmpty && fallbacks(out) == [g2])
        #expect(out.contains(.speakFallback(g2, text: "进入辅路", reason: .expired)))
        #expect(r.fidelityStrikes == 0)
        out = r.fallbackFinished(g2, at: at(3500), conditions: .init())
        #expect(out.isEmpty && !r.busy)
    }

    @Test("F-14 §10 row 2: a disconnected session falls back immediately")
    func disconnected() {
        var r = GuidanceRelay()
        let out = r.enqueue("前方路口左转", id: g1, at: at(0), conditions: .init(connected: false))
        #expect(out == [.speakFallback(g1, text: "前方路口左转", reason: .notConnected)])
    }

    @Test("F-14 deadline: the late reading is silenced before the fallback speaks; never both")
    func deadline() {
        var r = GuidanceRelay()
        _ = r.enqueue("前方300米右转", id: g1, at: at(0), conditions: .init())
        let v2 = r.timerFired(g1, at: at(1199), conditions: .init())
        #expect(v2.isEmpty)
        let out = r.timerFired(g1, at: at(1200), conditions: .init())
        #expect(out == [.silenceAssistant(g1), .speakFallback(g1, text: "前方300米右转", reason: .deadline)])
        // Her turn opening afterwards does not make it hers again.
        let v3 = r.assistantStarted(at: at(1500))
        #expect(v3.isEmpty && r.assistantID == nil)
    }

    @Test("F-14 two consecutive deadline fallbacks start a 60 s cooldown; a reading resets the count")
    func cooldown() {
        var r = GuidanceRelay()
        _ = r.enqueue("一", id: g1, at: at(0), conditions: .init())
        _ = r.timerFired(g1, at: at(1200), conditions: .init())
        _ = r.fallbackFinished(g1, at: at(2000), conditions: .init())
        _ = r.enqueue("二", id: g2, at: at(3000), conditions: .init())
        _ = r.timerFired(g2, at: at(4200), conditions: .init())
        _ = r.fallbackFinished(g2, at: at(5000), conditions: .init())
        #expect(r.cooldownUntil == at(4200 + 60_000))
        var out = r.enqueue("三", id: g3, at: at(10_000), conditions: .init())
        #expect(out == [.speakFallback(g3, text: "三", reason: .cooldown)])
        _ = r.fallbackFinished(g3, at: at(11_000), conditions: .init())
        out = r.enqueue("四", id: GuidanceID(4), at: at(64_300), conditions: .init())
        #expect(sent(out) == [GuidanceID(4)])
        _ = r.assistantStarted(at: at(64_500))
        #expect(r.consecutiveDeadlines == 0)
    }

    @Test("F-14 fidelity: two unfaithful readings send the rest of the trip to the fallback voice")
    func fidelity() {
        var r = GuidanceRelay()
        for (n, id) in [g1, g2].enumerated() {
            let t = Int64(n) * 10_000
            _ = r.enqueue("前方300米右转", id: id, at: at(t), conditions: .init())
            _ = r.assistantStarted(at: at(t + 300))
            r.assistantText("好的，前方三百米右转哦")
            let out = r.assistantFinished(at: at(t + 3000), conditions: .init())
            #expect(out.contains(.fidelityStrike(id, strikes: n + 1)))
        }
        let out = r.enqueue("进入辅路", id: g3, at: at(30_000), conditions: .init())
        #expect(out == [.speakFallback(g3, text: "进入辅路", reason: .fidelityStrikes)])
        // A new trip starts clean.
        _ = r.fallbackFinished(g3, at: at(31_000), conditions: .init())
        _ = r.tripEnded()
        #expect(sent(r.enqueue("进入辅路", id: GuidanceID(4), at: at(40_000), conditions: .init())) == [GuidanceID(4)])
    }

    @Test("F-14 routing reasons: disabled, capability, focus, driver speaking, reply open, work pending")
    func reasons() {
        let cases: [(GuidanceConditions, GuidanceFallbackReason)] = [
            (.init(enabled: false), .disabled), (.init(capable: false), .noCapability),
            (.init(focusHeld: false), .focus), (.init(driverSpeaking: true), .driverSpeaking),
            (.init(responseOpen: true), .responseOpen), (.init(workPending: true), .workPending),
        ]
        for (conditions, reason) in cases {
            var r = GuidanceRelay()
            let v4 = r.enqueue("右转", id: g1, at: at(0), conditions: conditions)
            #expect(v4 == [.speakFallback(g1, text: "右转", reason: reason)])
        }
    }

    @Test("F-14 bracket: a reading that never ends releases the lane after 300 ms per char (min 1.5 s)")
    func bracket() {
        var r = GuidanceRelay()
        _ = r.enqueue("右转", id: g1, at: at(0), conditions: .init())
        let out = r.assistantStarted(at: at(500))
        #expect(out == [.schedule(g1, at: at(2000))])
        r.assistantText("右转")
        let v5 = r.timerFired(g1, at: at(1999), conditions: .init())
        #expect(v5.isEmpty && r.busy)
        _ = r.timerFired(g1, at: at(2000), conditions: .init())
        #expect(!r.busy && r.fidelityStrikes == 0)
    }

    @Test("F-14 echo: her reading heard back within 10 s is dropped once")
    func echo() {
        var r = GuidanceRelay()
        _ = r.enqueue("前方300米右转", id: g1, at: at(0), conditions: .init())
        _ = r.assistantStarted(at: at(400))
        r.assistantText("前方300米右转")
        _ = r.assistantFinished(at: at(2000), conditions: .init())
        let v6 = r.isEcho("前方300米右转。", at: at(3000))
        #expect(v6)
        let v7 = r.isEcho("前方300米右转", at: at(3500))
        #expect(!v7)
        _ = r.enqueue("左转", id: g2, at: at(5000), conditions: .init())
        _ = r.assistantStarted(at: at(5300))
        r.assistantText("左转")
        _ = r.assistantFinished(at: at(6000), conditions: .init())
        let v8 = r.isEcho("左转", at: at(16_001))
        #expect(!v8)
    }

    @Test("F-14 a failed send falls back with SEND_FAILED")
    func sendFailed() {
        var r = GuidanceRelay()
        _ = r.enqueue("右转", id: g1, at: at(0), conditions: .init())
        let v9 = r.sendFailed(g1, at: at(10))
        #expect(v9 == [.silenceAssistant(g1), .speakFallback(g1, text: "右转", reason: .sendFailed)])
    }
}
