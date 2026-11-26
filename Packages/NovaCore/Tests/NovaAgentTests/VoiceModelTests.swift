import Foundation
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

private final class ModelSettings: SettingsStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func string(_ key: String) -> String? { values[key] }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) { values[key] = value }
    func set(_ value: Bool, for key: String) {}
}

/// The capabilities `QwenRealtimeProvider` declares (F-05 §15 item 5).
private let qwen = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false,
                                        resumption: false, backgroundTools: false)

private func qwenAsking(_ words: String) -> Drive {
    var d = Drive()
    d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false, capabilities: qwen)
    d.connect()
    d.send(.speechStarted(recentSpeech: true))
    d.send(.speechStopped)
    d.realtime(.userTranscript(words, isFinal: true))
    d.realtime(.responseStarted(TurnID(1)))
    return d
}

private func texts(_ effects: [AgentEffect]) -> [(String, Bool)] {
    effects.flatMap { e -> [(String, Bool)] in
        if case .provider(.text(let turns, let complete)) = e { return turns.map { ($0.text, complete) } }
        return []
    }
}

/// F-05 §15 (T-016q): the voice model choice and what the core does for a provider without resumption or background
/// tools (Qwen-Audio realtime).
@Suite("T-016q F-05 §15 voice model")
struct VoiceModelTests {
    @Test("T-016q F-05 row 10: three choices; Gemini default; Qwen disabled without the 百炼 key; 「下次连接时生效」")
    func row10() {
        #expect(VoiceModel.allCases.map(\.label) == ["Gemini 3.8 Live", "Qwen Audio 3.1 Flash", "Qwen Audio 3.1 Plus"])
        #expect(VoiceModel.allCases.map(\.modelID)
            == ["gemini-3.8-live", "qwen-audio-3.1-realtime-flash", "qwen-audio-3.1-realtime-plus"])
        let settings = ModelSettings()
        #expect(VoiceModel.saved(in: settings) == .geminiLive)
        #expect(VoiceModel.geminiLive.disabledReason(qwenKey: nil) == nil)
        #expect(VoiceModel.qwenFlash.disabledReason(qwenKey: nil) == "先在设置里填百炼 key")
        #expect(VoiceModel.qwenFlash.disabledReason(qwenKey: "") == "先在设置里填百炼 key")
        // T-016r: only the 百炼 key; no saved voice API Host is needed.
        #expect(VoiceModel.qwenPlus.disabledReason(qwenKey: "k") == nil)
        VoiceModel.save(.qwenFlash, in: settings)
        #expect(VoiceModel.saved(in: settings) == .qwenFlash)
        #expect(VoiceModel.resolved(in: settings, qwenKey: "k") == .qwenFlash)
        // The key removed since: the next connect uses Gemini.
        #expect(VoiceModel.resolved(in: settings, qwenKey: nil) == .geminiLive)
        #expect(VoiceModel.nextConnectNote == "下次连接时生效")
        #expect(VoiceModel.title == "语音模型")
    }

    @Test("T-016q F-05 row 14: plan_trip on Qwen: the handoff result at once; the final result later as a text turn")
    func row14() {
        var d = qwenAsking("帮我安排珠海两天")
        let call = ToolCall(id: CallID("call_t")!, name: "plan_trip", arguments: ["asked": ["text": "珠海两天"]])
        let out = d.realtime(.toolCalls(TurnID(1), [call]))
        #expect(out.contains(.startTool(TurnID(1), call)))
        let handoff = AsyncToolTests.responses(out)
        #expect(handoff.map(\.id) == [call.id])
        #expect(handoff.first?.result.data["status"] == "running")
        #expect(handoff.first?.result.data["next"]?.stringValue == AsyncTool.handoffNextSilent)
        // The app says the handoff line itself (F-15b §62 item 12).
        #expect(out.contains(.diagnostic(.handoffSaid(tool: .planTrip, ms: 0))))
        // Turn 1 ends; Qwen answers the handoff output with a new response (`response.create`), then idles.
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.realtime(.responseStarted(TurnID(2)))
        d.realtime(.replyText(TurnID(2), "好的。"))
        d.realtime(.responseDone(TurnID(2), outcome: .completed))
        d.send(.playback(.replyFinished(d.state.arbiter.epoch)))
        d.send(.playback(.replyIdle(d.state.arbiter.epoch)))
        d.now = d.now + .seconds(30)
        let done = d.send(.toolFinished(TurnID(1), call, .success(["status": "trip_plan", "next": "说计划。"])))
        #expect(AsyncToolTests.responses(done).isEmpty)
        let late = texts(done)
        #expect(late.count == 1)
        #expect(late.first?.0.hasPrefix("（刚才plan_trip的结果：{") == true && late.first?.0.hasSuffix("）说计划。") == true)
        #expect(late.first?.1 == true)
        #expect(done.contains(.diagnostic(.asyncResultViaText(tool: .planTrip, reason: .handoff))))
        #expect(DiagnosticEvent.asyncResultViaText(tool: .planTrip, reason: .handoff).logLine
            == "tool-result plan_trip via=text reason=handoff")
    }

    @Test("T-016q F-05 §15 item 5: find_events and a blocking tool in one batch: one handoff, the blocking call unchanged")
    func handoffBatch() {
        var d = qwenAsking("这周末珠海有什么展，顺便开空调")
        let events = ToolCall(id: CallID("call_e")!, name: "find_events",
                              arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"])
        let out = d.realtime(.toolCalls(TurnID(1), [events, climateOn()]))
        let handoff = AsyncToolTests.responses(out)
        #expect(handoff.map(\.id) == [events.id])
        #expect(handoff.first?.result.data["next"]?.stringValue == AsyncTool.handoffNext)
        #expect(out.contains(.startTool(TurnID(1), climateOn())))
        // The blocking result goes back as a tool response, as on Gemini.
        let blocking = d.send(.toolFinished(TurnID(1), climateOn(), .success(["ok": true])))
        #expect(AsyncToolTests.responses(blocking).map(\.id) == [climateOn().id])
    }

    @Test("T-016q F-05 §15 item 5: Gemini (background tools) is unchanged: no handoff response")
    func geminiUnchanged() {
        var d = AsyncToolTests.asking("这周末珠海有什么展")
        let events = ToolCall(id: CallID("call_e")!, name: "find_events",
                              arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"])
        #expect(AsyncToolTests.responses(d.realtime(.toolCalls(TurnID(1), [events]))).isEmpty)
    }

    @Test("T-016q F-05 row 15: the socket drops on Qwen: fresh reconnect with the summary note; qwen reconnect fresh=yes")
    func row15() {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), capabilities: qwen)
        d.connect()
        let turn = FlexibleAssistantTests.turn(&d, calls: [climateOn()], reply: "空调开了。")
        #expect(turn.contains(.diagnostic(.qwenHistory(turns: 1))))
        #expect(DiagnosticEvent.qwenHistory(turns: 1).logLine == "qwen history turns=1")
        d.send(.playback(.replyFinished(d.state.arbiter.epoch)))
        d.send(.playback(.replyIdle(d.state.arbiter.epoch)))
        d.now = d.now + .seconds(20)
        let failed = d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = (d.effects + failed).compactMap {
            if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil }
        }
        let reconnect = d.send(.timer(.session(timer.last!)))
        // No handle: Qwen never sends one, so the connect is fresh.
        #expect(reconnect.contains { if case .provider(.connect(_, resume: nil)) = $0 { true } else { false } })
        #expect(reconnect.contains(.diagnostic(.qwenReconnectFresh)))
        #expect(DiagnosticEvent.qwenReconnectFresh.logLine == "qwen reconnect fresh=yes")
        let ready = d.realtime(.setupComplete)
        let notes = FlexibleAssistantTests.notes(ready)
        #expect(notes.first?.hasPrefix("[系统] 接着之前的对话。最近几句：") == true)
        #expect(notes.first?.contains("空调开了") == true)
        #expect(ready.contains { if case .diagnostic(.summaryNote(exchanges: 1, _)) = $0 { true } else { false } })
        // The next turn on the new socket counts from 1 again.
        #expect(FlexibleAssistantTests.turn(&d).contains(.diagnostic(.qwenHistory(turns: 1))))
    }

    @Test("T-016q F-05 §15 item 5: Gemini reconnects keep no summary of their own (resumption carries the context)")
    func geminiReconnect() {
        var d = Drive()
        d.connect()
        FlexibleAssistantTests.turn(&d)
        let failed = d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = (d.effects + failed).compactMap {
            if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil }
        }
        #expect(!d.send(.timer(.session(timer.last!))).contains(.diagnostic(.qwenReconnectFresh)))
    }

    @Test("T-016q F-05 §15 item 6: the record header names the voice model")
    func header() {
        let lines = RecordHeader(appVersion: "0.1.0(1)", comfortMode: "model", interruptible: true, speakingStyle: "warm",
                                 voiceModel: VoiceModel.qwenFlash.modelID).lines
        #expect(lines.contains("voiceModel qwen-audio-3.1-realtime-flash"))
        #expect(!RecordHeader(appVersion: "a", comfortMode: "m", interruptible: true, speakingStyle: "s").lines
            .contains { $0.hasPrefix("voiceModel") })
    }

    @Test("T-016q F-05 §15 item 5 review: on Qwen, find_events handed off still running: 「没有找到活动」 gets RESULT_PENDING")
    func pendingAfterHandoff() {
        var d = qwenAsking("这周末珠海有什么展")
        let call = ToolCall(id: CallID("call_e")!, name: "find_events",
                            arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"])
        #expect(AsyncToolTests.responses(d.realtime(.toolCalls(TurnID(1), [call]))).count == 1)
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.realtime(.responseStarted(TurnID(2)))
        let out = d.realtime(.replyText(TurnID(2), "抱歉，没有找到活动。"))
            + d.realtime(.responseDone(TurnID(2), outcome: .completed))
        let corrected = out + d.fire(.correction)
        #expect(texts(corrected).contains { $0.0.contains("RESULT_PENDING tool=find_events") })
    }
}
