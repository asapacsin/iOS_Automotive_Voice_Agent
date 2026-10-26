import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

private func guidance(_ effects: [AgentEffect]) -> [String] {
    effects.compactMap { if case .speakGuidance(let s, _) = $0 { s } else { nil } }
}

private func sentText(_ effects: [AgentEffect]) -> [String] {
    effects.compactMap { if case .provider(.text(let turns, _)) = $0 { turns.map(\.text).joined() } else { nil } }
}

private extension Drive {
    mutating func navigate() {
        send(.navigation(NavigationFlags(navigating: true, guidanceRunning: true)))
    }
}

@Suite("T-051/T-052 W5 guidance relay and arbitration through AgentCore")
struct GuidanceWalkthroughTests {
    @Test("W5 relay: the sentence goes to the model verbatim, she reads it, Amap's voice stays silent")
    func relayed() {
        var d = Drive()
        d.connect()
        d.navigate()
        let g = GuidanceID(1)
        let out = d.send(.guidancePrompt("前方300米右转", g))
        #expect(sentText(out) == [GuidanceRelay.prompt(for: "前方300米右转")])
        d.now = NovaInstant(milliseconds: 500)
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "前方300米右转。"))
        d.realtime(.responseDone(t, outcome: .completed))
        #expect(spoken(d.effects) == "前方300米右转。")
        #expect(guidance(d.effects).isEmpty)
        #expect(!d.state.relay.busy && d.state.relay.fidelityStrikes == 0)
    }

    @Test("W5 deadline: a reading that has not started in 1.2 s is given to the fallback voice; her late turn is never heard")
    func deadline() {
        var d = Drive()
        d.connect()
        d.navigate()
        let g = GuidanceID(1)
        d.send(.guidancePrompt("前方300米右转", g))
        d.now = NovaInstant(milliseconds: 1200)
        let out = d.send(.timer(.guidance(g)))
        #expect(guidance(out) == ["前方300米右转"])
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "前方300米右转。"))
        d.realtime(.responseDone(t, outcome: .completed))
        #expect(spoken(d.effects).isEmpty)
    }

    @Test("W5 disconnected: guidance falls back immediately and nothing is sent to the model")
    func disconnected() {
        var d = Drive()
        d.navigate()
        let out = d.send(.guidancePrompt("前方路口左转", GuidanceID(1)))
        #expect(guidance(out) == ["前方路口左转"] && sentText(out).isEmpty)
    }

    @Test("W5 a reply ready while the fallback voice speaks is held and plays after it; the uplink closes with a 500 ms tail")
    func holdDuringGuidance() {
        var d = Drive()
        d.connect()
        d.navigate()
        let g = GuidanceID(1)
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("今天天气怎么样", isFinal: true))
        d.send(.speechStopped)
        // The driver just spoke, so the sentence goes to Amap's voice (her reply is about to open).
        d.realtime(.responseStarted(TurnID(1)))
        #expect(guidance(d.send(.guidancePrompt("前方右转", g))) == ["前方右转"])
        var out = d.send(.playback(.guidanceStarted(g)))
        #expect(out.contains(.uplink(open: false)))
        out = d.realtime(.replyText(TurnID(1), "今天晴。"))
        #expect(spoken(out).isEmpty)
        d.now = NovaInstant(milliseconds: 2000)
        out = d.send(.playback(.guidanceEnded(g)))
        #expect(spoken(out) == "今天晴。")
        d.now = NovaInstant(milliseconds: 2500)
        out = d.send(.timer(.arbiter(d.now)))
        #expect(out.contains(.uplink(open: true)))
    }

    @Test("W5 her reading heard back through the microphone does not become a driver utterance")
    func echoDropped() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.guidancePrompt("前方300米右转", GuidanceID(1)))
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "前方300米右转"))
        d.realtime(.responseDone(t, outcome: .completed))
        d.now = NovaInstant(milliseconds: 3000)
        let out = d.realtime(.userTranscript("前方300米右转。", isFinal: true))
        #expect(out.isEmpty)
    }

    @Test("W5 a guidance reading never acts: its tool calls are refused and nothing runs")
    func readingNeverActs() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        let out = d.realtime(.toolCalls(t, [climateOn()]))
        #expect(!out.contains { if case .startTool = $0 { true } else { false } })
        #expect(out.contains { if case .provider(.toolResponses) = $0 { true } else { false } })
    }

    @Test("W5 R6: while navigating an unprompted model reply is not spoken")
    func unpromptedDropped() {
        var d = Drive()
        d.connect()
        d.navigate()
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "我们聊聊天吧。"))
        d.realtime(.responseDone(t, outcome: .completed))
        #expect(spoken(d.effects).isEmpty)
    }
}
