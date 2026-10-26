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
        #expect(spoken(out).isEmpty)  // guidance + 500 ms tail first
        d.now = NovaInstant(milliseconds: 2500)
        out = d.send(.timer(.arbiter(d.now)))
        #expect(spoken(out) == "今天晴。")
        #expect(out.contains(.uplink(open: true)))
    }

    @Test("W5 review B1: while the driver's answer is owed, guidance is not sent to the model; the answer keeps its tools and claim gate")
    func answerOwed() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.send(.speechStopped)
        d.now = NovaInstant(milliseconds: 300)
        let out = d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        #expect(guidance(out) == ["前方右转"] && sentText(out).isEmpty)
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        let calls = d.realtime(.toolCalls(t, [climateOn()]))
        #expect(calls.contains(.startTool(t, climateOn())))
    }

    @Test("W5 review B2: relay state dies with the socket; the first turn after a reconnect is the driver's")
    func reconnect() {
        var d = Drive()
        d.connect()
        d.navigate()
        let g = GuidanceID(1)
        d.send(.guidancePrompt("前方右转", g))
        // The socket drops before her reading opens, and reconnects.
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        d.send(.timer(.session(timer.last!)))
        #expect(guidance(d.effects) == ["前方右转"])
        d.realtime(.setupComplete)
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.send(.speechStopped)
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        let calls = d.realtime(.toolCalls(t, [climateOn()]))
        #expect(calls.contains(.startTool(t, climateOn())))
    }

    @Test("W5 review B3: R1 holds from the moment the fallback is issued, before the voice is rendered")
    func holdFromIssue() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("今天天气怎么样", isFinal: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        // Rendering: no guidanceStarted yet, and still nothing of her reply is released.
        let out = d.realtime(.replyText(TurnID(1), "今天晴。"))
        #expect(spoken(out).isEmpty)
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

    @Test("W5 re-review B1: after a tool result the model owes a turn; guidance in that gap goes to the fallback")
    func toolResultGap() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.realtime(.responseDone(t1, outcome: .completed))
        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        let out = d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        #expect(guidance(out) == ["前方右转"] && sentText(out).isEmpty)
        // Her announcement goes through the claim gate as usual.
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        d.send(.playback(.guidanceEnded(GuidanceID(1))))
        d.now = NovaInstant(milliseconds: 1000)
        d.realtime(.replyText(t2, "空调已经打开了。"))
        d.realtime(.responseDone(t2, outcome: .completed))
        #expect(spoken(d.effects) == "空调已经打开了。")
    }

    @Test("W5 re-review B2: the driver speaking after the prompt does not turn her reading into the answer")
    func driverAfterPrompt() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.send(.speechStopped)
        let reading = TurnID(1)
        d.realtime(.responseStarted(reading))
        d.realtime(.replyText(reading, "前方右转。"))
        d.realtime(.responseDone(reading, outcome: .completed))
        #expect(d.state.relay.fidelityStrikes == 0 && !d.state.relay.busy)
        let answer = TurnID(2)
        d.realtime(.responseStarted(answer))
        let calls = d.realtime(.toolCalls(answer, [climateOn()]))
        #expect(calls.contains(.startTool(answer, climateOn())))
    }

    @Test("W5 round 3: a fallback after the reply closed waits for her audio to drain, at most 4 s, never overlapping")
    func overlapAfterClose() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("今天天气怎么样", isFinal: true))
        d.send(.speechStopped)
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "今天晴。"))
        d.realtime(.responseDone(t, outcome: .completed))
        #expect(spoken(d.effects) == "今天晴。")
        let epoch = d.state.arbiter.epoch
        d.send(.playback(.replyStarted(epoch)))
        d.send(.guidanceRelay(enabled: false))
        var out = d.send(.guidancePrompt("前方右转", GuidanceID(1)))
        #expect(guidance(out).isEmpty)  // her sentence is still sounding
        out = d.send(.playback(.replyFinished(epoch)))
        #expect(guidance(out) == ["前方右转"])
        #expect(!out.contains { if case .flushPlayback = $0 { true } else { false } })

        // A lane that never reports the end is cut after 4 s, flush before the guidance.
        d.send(.playback(.guidanceEnded(GuidanceID(1))))
        d.now = NovaInstant(milliseconds: 10_000)
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("再说一遍", isFinal: true))
        d.send(.speechStopped)
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        d.realtime(.replyText(t2, "今天晴。"))
        d.realtime(.responseDone(t2, outcome: .completed))
        d.send(.playback(.replyStarted(d.state.arbiter.epoch)))
        out = d.send(.guidancePrompt("进入辅路", GuidanceID(2)))
        #expect(guidance(out).isEmpty)
        d.now = NovaInstant(milliseconds: 14_000)
        out = d.send(.timer(.arbiter(d.now)))
        let flush = out.firstIndex { if case .flushPlayback = $0 { true } else { false } }
        let speak = out.firstIndex { if case .speakGuidance = $0 { true } else { false } }
        #expect(flush != nil && speak != nil && flush! < speak!)
    }

    @Test("W5 round 3: when Gemini drops the reading because the driver spoke, their answer is not silenced")
    func droppedReading() {
        var d = Drive()
        d.connect()
        d.navigate()
        let g = GuidanceID(1)
        d.send(.guidancePrompt("前方右转", g))
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.send(.speechStopped)
        d.now = NovaInstant(milliseconds: 1200)
        #expect(guidance(d.send(.timer(.guidance(g)))) == ["前方右转"])
        let answer = TurnID(1)
        d.realtime(.responseStarted(answer))
        let calls = d.realtime(.toolCalls(answer, [climateOn()]))
        #expect(calls.contains(.startTool(answer, climateOn())))
    }

    @Test("W5 round 3: a turn after the prompt whose words are the sentence is the reading")
    func classifiedReading() {
        var d = Drive()
        d.connect()
        d.navigate()
        d.send(.guidancePrompt("前方300米右转", GuidanceID(1)))
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("嗯", isFinal: true))
        d.send(.speechStopped)
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        d.realtime(.replyText(t, "前方300米"))
        d.realtime(.replyText(t, "右转。"))
        d.realtime(.responseDone(t, outcome: .completed))
        #expect(spoken(d.effects) == "前方300米右转。")
        #expect(!d.state.relay.busy && d.state.relay.fidelityStrikes == 0)
    }
}

@Suite("T-047 F-25 taps through AgentCore (I-6)")
struct UITapTests {
    @Test("F-25 §10 row 2: a row tap is the voice choice call through the dispatcher; she announces the read-back")
    func tap() {
        var d = Drive()
        d.connect()
        d.send(.navigation(NavigationFlags(listOpen: true)))
        let out = d.send(.ui(.choose(row: 1)))
        guard case .startTool(_, let call)? = out.first else {
            Issue.record("no tool start")
            return
        }
        #expect(call.name == "choose_navigation_option" && call.arguments["index"] == .int(2))
        let done = d.send(.toolFinished(.initial, call, .success(["status": "destination_selected"])))
        #expect(!done.contains { if case .provider(.toolResponses) = $0 { true } else { false } })
        let notes = done.compactMap { if case .provider(.text(let t, _)) = $0 { t.first?.text } else { nil } }
        #expect(notes.count == 1 && notes[0].contains("destination_selected"))
    }
}
