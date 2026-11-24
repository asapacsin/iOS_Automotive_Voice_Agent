import Foundation
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

private func eventsCall(_ id: String = "call_e") -> ToolCall {
    ToolCall(id: CallID(id)!, name: "find_events", arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"])
}

private func texts(_ effects: [AgentEffect]) -> [String] {
    effects.flatMap { e -> [String] in
        if case .provider(.text(let turns, _)) = e { return turns.map(\.text) }
        return []
    }
}

private func diagnostics(_ effects: [AgentEffect]) -> [DiagnosticEvent] {
    effects.compactMap { if case .diagnostic(let d) = $0 { d } else { nil } }
}

/// The reply of turn `id` ends, so she is idle again.
private func finishTurn(_ d: inout Drive, _ id: TurnID, _ text: String = "我查一下。") {
    d.realtime(.replyText(id, text))
    d.realtime(.responseDone(id, outcome: .completed))
    d.send(.playback(.replyFinished(d.state.arbiter.epoch)))
    d.send(.playback(.replyIdle(d.state.arbiter.epoch)))
}

/// F-18 §37 (T-046z): background results that overlap or arrive late.
@Suite("T-046z F-18 §37 late and overlapping background results")
struct LateResultTests {
    @Test("T-046z F-18 §37 row 37: two web_search 2 s apart, the older answers last, the newer ok: only the newer reaches her")
    func row37() {
        var d = AsyncToolTests.asking("酒店含早餐吗")
        let older = searchCall("酒店含早餐吗", id: "call_a"), newer = searchCall("酒店早餐几点", id: "call_b")
        d.realtime(.toolCalls(TurnID(1), [older]))
        d.now = d.now + .seconds(2)
        d.realtime(.toolCalls(TurnID(1), [newer]))
        // The older answers while the newer still runs: held.
        #expect(AsyncToolTests.responses(d.send(.toolFinished(TurnID(1), older, .success(["answer": "包含早餐"])))).isEmpty)
        let done = d.send(.toolFinished(TurnID(1), newer, .success(["answer": "不一定"])))
        #expect(AsyncToolTests.responses(done).map(\.id) == [newer.id])
        #expect(diagnostics(done).contains(.asyncResultDropped(tool: .webSearch, reason: .superseded)))
        #expect(DiagnosticEvent.asyncResultDropped(tool: .webSearch, reason: .superseded).logLine
            == "tool-result web_search dropped reason=superseded")
    }

    @Test("T-046z F-18 §37 row 37b: the older answers after the newer ended ok: dropped")
    func row37b() {
        var d = AsyncToolTests.asking("酒店含早餐吗")
        let older = searchCall("a", id: "call_a"), newer = searchCall("b", id: "call_b")
        d.realtime(.toolCalls(TurnID(1), [older]))
        d.realtime(.toolCalls(TurnID(1), [newer]))
        #expect(AsyncToolTests.responses(d.send(.toolFinished(TurnID(1), newer, .success(["answer": "不一定"])))).count == 1)
        let late = d.send(.toolFinished(TurnID(1), older, .success(["answer": "包含早餐"])))
        #expect(AsyncToolTests.responses(late).isEmpty)
        #expect(diagnostics(late).contains(.asyncResultDropped(tool: .webSearch, reason: .superseded)))
    }

    @Test("T-046z F-18 §37 row 38: the newer fails: the older result is sent")
    func row38() {
        var d = AsyncToolTests.asking("酒店含早餐吗")
        let older = searchCall("a", id: "call_a"), newer = searchCall("b", id: "call_b")
        d.realtime(.toolCalls(TurnID(1), [older]))
        d.realtime(.toolCalls(TurnID(1), [newer]))
        #expect(AsyncToolTests.responses(d.send(.toolFinished(TurnID(1), older, .success(["answer": "包含早餐"])))).isEmpty)
        let done = d.send(.toolFinished(TurnID(1), newer, .failure(.liveInfoUnavailable)))
        #expect(AsyncToolTests.responses(done).map(\.id) == [older.id])
        #expect(d.state.runningTools == 0)
    }

    @Test("T-046z F-18 §37 row 39: find_events running 40 s; 「没有找到活动」 gets RESULT_PENDING; the 现在 note says it runs")
    func row39() {
        var d = AsyncToolTests.asking("这周末珠海有什么展")
        d.send(.context(ContextNoteTests.snap()))
        let call = eventsCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        finishTurn(&d, TurnID(1))
        d.now = d.now + .seconds(40)
        let note = texts(d.send(.context(ContextNoteTests.snap(district: "金湾区")))).joined()
        #expect(note.contains("后台在查：活动（已过40秒）"))
        // The driver asks again; she says there is nothing although the loop still runs.
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("找到了吗", isFinal: true))
        d.realtime(.responseStarted(TurnID(2)))
        let out = d.realtime(.replyText(TurnID(2), "抱歉，没有找到活动。"))
            + d.realtime(.responseDone(TurnID(2), outcome: .completed))
        let corrected = out + d.fire(.correction)
        #expect(texts(corrected).contains { $0.contains("RESULT_PENDING tool=find_events：活动还在查，跟司机说还在查，好了告诉他。") })
        #expect(!spoken(out).contains("没有找到"))
    }

    @Test("T-046z F-18 §37 row 40: the session reconnects while find_events runs; its result goes as a text turn when idle")
    func row40() {
        var d = AsyncToolTests.asking("这周末珠海有什么展")
        let call = eventsCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        let failed = d.realtime(.failed(RealtimeError(.disconnect)))
        // §37 item 3 amends §27 item 4: the call keeps running.
        #expect(!failed.contains(.cancelTool(call.id)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        d.send(.timer(.session(timer.last!)))
        d.realtime(.setupComplete)
        let result = ToolResult.success(["events": [], "source": "browse", "next": "这些是页面上写着日期的活动。"])
        let done = d.send(.toolFinished(TurnID(1), call, result))
        #expect(AsyncToolTests.responses(done).isEmpty)
        let late = texts(done)
        #expect(late.contains { $0.hasPrefix("（刚才find_events的结果：{") && $0.hasSuffix("）这些是页面上写着日期的活动。") })
        #expect(diagnostics(done).contains(.asyncResultViaText(tool: .findEvents)))
        #expect(DiagnosticEvent.asyncResultViaText(tool: .findEvents).logLine == "tool-result find_events via=text reason=reconnected")
        #expect(done.contains { if case .provider(.text(_, turnComplete: true)) = $0 { true } else { false } })
    }

    @Test("T-046z F-18 §37 item 4: a result older than 10 minutes is not spoken")
    func stale() {
        var d = AsyncToolTests.asking("这周末珠海有什么展")
        let call = eventsCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        d.now = d.now + .seconds(601)
        let done = d.send(.toolFinished(TurnID(1), call, .success(["events": []])))
        #expect(AsyncToolTests.responses(done).isEmpty)
        #expect(diagnostics(done).contains(.asyncResultDropped(tool: .findEvents, reason: .stale)))
        #expect(DiagnosticEvent.asyncResultDropped(tool: .findEvents, reason: .stale).logLine == "tool-result find_events dropped reason=stale")
    }

    @Test("T-046z F-18 §37 review: after a late result the RESULT_PENDING check no longer fires")
    func lateClearsPending() {
        var d = AsyncToolTests.asking("这周末珠海有什么展")
        let call = eventsCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        d.send(.timer(.session(timer.last!)))
        d.realtime(.setupComplete)
        d.send(.toolFinished(TurnID(1), call, .success(["events": [], "next": "没有就说没找到"])))
        d.realtime(.responseStarted(TurnID(2)))
        let out = d.realtime(.replyText(TurnID(2), "在本地宝上没找到这几天的活动。"))
            + d.realtime(.responseDone(TurnID(2), outcome: .completed)) + d.fire(.correction)
        #expect(!texts(out).contains { $0.contains("RESULT_PENDING") })
    }

    @Test("T-046z F-18 §37 review: three overlapping searches leave nothing running")
    func threeSearches() {
        var d = AsyncToolTests.asking("酒店含早餐吗")
        let a = searchCall("a", id: "call_a"), b = searchCall("b", id: "call_b"), c = searchCall("c", id: "call_c")
        d.realtime(.toolCalls(TurnID(1), [a]))
        d.realtime(.toolCalls(TurnID(1), [b]))
        d.send(.toolFinished(TurnID(1), a, .success(["answer": "1"])))
        d.realtime(.toolCalls(TurnID(1), [c]))
        d.send(.toolFinished(TurnID(1), b, .success(["answer": "2"])))
        let done = d.send(.toolFinished(TurnID(1), c, .success(["answer": "3"])))
        #expect(AsyncToolTests.responses(done).map(\.id) == [c.id])
        #expect(d.state.runningTools == 0)
    }
}
