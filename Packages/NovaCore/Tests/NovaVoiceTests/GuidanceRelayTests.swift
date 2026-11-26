import Testing
@testable import NovaKit
@testable import NovaVoice

private func at(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }
private let g1 = GuidanceID(1), g2 = GuidanceID(2)

private func fallbacks(_ outputs: [GuidanceRelayOutput]) -> [GuidanceID] {
    outputs.compactMap { if case .speakFallback(let id, _, _) = $0 { id } else { nil } }
}

/// F-14 guidance relay. F-07 §18 (T-020e): no voice model reads a sentence back (that path needed revoicing); every
/// sentence takes the fallback voice, once, one at a time.
@Suite("T-051 F-14 guidance relay")
struct GuidanceRelayTests {
    @Test("F-14 §10 row 1: each sentence is spoken exactly once, by one voice, one at a time")
    func exactlyOnce() {
        var r = GuidanceRelay()
        var out = r.enqueue("前方300米右转", id: g1, at: at(0), conditions: .init())
        #expect(out == [.speakFallback(g1, text: "前方300米右转", reason: .noCapability)])
        out = r.enqueue("进入辅路", id: g2, at: at(100), conditions: .init())
        #expect(out.isEmpty && r.queue.count == 1)
        out = r.fallbackFinished(g1, at: at(1000), conditions: .init())
        #expect(fallbacks(out) == [g2])
        out = r.fallbackFinished(g2, at: at(2500), conditions: .init())
        #expect(out.isEmpty && !r.busy)
    }

    @Test("F-14 §10 row 2: a disconnected session falls back immediately")
    func disconnected() {
        var r = GuidanceRelay()
        let out = r.enqueue("前方路口左转", id: g1, at: at(0), conditions: .init(connected: false))
        #expect(out == [.speakFallback(g1, text: "前方路口左转", reason: .notConnected)])
    }

    @Test("T-020e F-07 §18 item 2: every connected sentence takes the fallback voice (no reading by the voice model)")
    func reasons() {
        let cases: [(GuidanceConditions, GuidanceFallbackReason)] = [
            (.init(enabled: false), .disabled), (.init(), .noCapability), (.init(focusHeld: false), .noCapability),
            (.init(driverSpeaking: true), .noCapability), (.init(responseOpen: true), .noCapability),
        ]
        for (conditions, reason) in cases {
            var r = GuidanceRelay()
            #expect(r.enqueue("右转", id: g1, at: at(0), conditions: conditions)
                == [.speakFallback(g1, text: "右转", reason: reason)])
        }
    }

    @Test("F-14 trip end clears the queue")
    func tripEnd() {
        var r = GuidanceRelay()
        _ = r.enqueue("右转", id: g1, at: at(0), conditions: .init())
        _ = r.enqueue("左转", id: g2, at: at(10), conditions: .init())
        _ = r.tripEnded()
        #expect(r.queue.isEmpty && !r.busy)
    }
}
