import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

final class VoiceTestSettings: SettingsStore, @unchecked Sendable {
    private let values = Mutex<[String: String]>([:])
    private let flags = Mutex<[String: Bool]>([:])
    init(_ strings: [String: String] = [:], bools: [String: Bool] = [:]) {
        values.withLock { $0 = strings }
        flags.withLock { $0 = bools }
    }
    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func bool(_ key: String) -> Bool? { flags.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func set(_ value: Bool, for key: String) { flags.withLock { $0[key] = value } }
    var allStrings: [String: String] { values.withLock { $0 } }
    var allBools: [String: Bool] { flags.withLock { $0 } }
}

private func texts(_ effects: [AgentEffect]) -> [String] {
    effects.flatMap { e -> [String] in
        if case .provider(.text(let turns, _)) = e { return turns.map(\.text) }
        return []
    }
}

private func responses(_ effects: [AgentEffect]) -> [ToolResponse] {
    var out: [ToolResponse] = []
    for case .provider(.toolResponses(let r)) in effects { out += r }
    return out
}

/// A Qwen session: no background tools, fresh reconnects with the summary.
private func qwenAsking(_ words: String) -> Drive {
    var d = Drive()
    d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false, backgroundTools: false,
                         freshReconnect: ExchangeMemory())
    d.connect()
    d.send(.speechStarted(recentSpeech: true))
    d.send(.speechStopped)
    d.realtime(.userTranscript(words, isFinal: true))
    d.realtime(.responseStarted(TurnID(1)))
    return d
}

@Suite("T-016q F-05 §15 voice model choice")
struct VoiceModelTests {
    @Test("T-016r F-05 row 10: a Qwen choice needs only the 百炼 key (no API Host)")
    func t016rRow10() {
        #expect(VoiceModel.qwenFlash.isAvailable(qwenKeySaved: true))
        #expect(VoiceModel.qwenFlash.disabledReason(qwenKeySaved: true) == nil)
        #expect(VoiceModel.qwenPlus.disabledReason(qwenKeySaved: false) == "先在设置里填百炼 key")
        let saved = VoiceTestSettings([SettingsKey.voiceModel: VoiceModel.qwenFlash.rawValue])
        #expect(VoiceModel.effective(in: saved, qwenKeySaved: true) == .qwenFlash)
    }

    @Test("T-016q F-05 row 10: three choices, Gemini default; Qwen disabled without the 百炼 key; change note 下次连接时生效")
    func row10() {
        #expect(VoiceModel.allCases.map(\.label) == ["Gemini 3.8 Live", "Qwen Audio 3.1 Flash", "Qwen Audio 3.1 Plus"])
        #expect(VoiceModel.allCases.map(\.modelID)
            == ["gemini-3.8-live", "qwen-audio-3.1-realtime-flash", "qwen-audio-3.1-realtime-plus"])
        #expect(VoiceModel.saved(in: VoiceTestSettings()) == .geminiLive)
        #expect(VoiceModel.saved(in: VoiceTestSettings([SettingsKey.voiceModel: "nonsense"])) == .geminiLive)
        #expect(VoiceModel.geminiLive.disabledReason(qwenKeySaved: false) == nil)
        #expect(VoiceModel.qwenFlash.disabledReason(qwenKeySaved: false) == "先在设置里填百炼 key")
        #expect(VoiceModel.qwenPlus.isAvailable(qwenKeySaved: true))
        let saved = VoiceTestSettings([SettingsKey.voiceModel: VoiceModel.qwenPlus.rawValue])
        #expect(VoiceModel.effective(in: saved, qwenKeySaved: true) == .qwenPlus)
        #expect(VoiceModel.effective(in: saved, qwenKeySaved: false) == .geminiLive)
        #expect(VoiceModel.nextConnectNote == "下次连接时生效")
        // Item 6: the record header names the voice model.
        let header = RecordHeader(appVersion: "0.1.0(1) abc1234", comfortMode: "model", interruptible: true,
                                  speakingStyle: "warm", voiceModel: VoiceModel.qwenFlash.modelID)
        #expect(header.lines.contains("voiceModel qwen-audio-3.1-realtime-flash"))
        #expect(header.lines[1] == "voiceModel qwen-audio-3.1-realtime-flash")
    }

    @Test("T-016q F-05 row 14: plan_trip on Qwen gets the handoff result at once; its final result goes later as a text turn")
    func row14() {
        var d = qwenAsking("帮我安排珠海两天")
        let call = ToolCall(id: CallID("call_p")!, name: "plan_trip", arguments: ["asked": ["text": "珠海两天"]])
        let started = d.realtime(.toolCalls(TurnID(1), [call]))
        #expect(started.contains(.startTool(TurnID(1), call)))
        let immediate = responses(started)
        #expect(immediate.map(\.id) == [call.id])
        #expect(immediate.first?.result.data["status"] == "running")
        #expect(immediate.first?.result.ok == true)
        // The app still says the handoff line itself.
        #expect(started.contains { if case .speakGuidance(let line, _) = $0 { line.hasPrefix("好，我交给规划助手") } else { false } })
        // She answers the handoff and goes idle.
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.realtime(.responseStarted(TurnID(2)))
        d.realtime(.replyText(TurnID(2), "好的。"))
        d.realtime(.responseDone(TurnID(2), outcome: .completed))
        d.send(.playback(.replyFinished(d.state.arbiter.epoch)))
        d.send(.playback(.replyIdle(d.state.arbiter.epoch)))
        d.now = d.now + .seconds(30)
        let result = ToolResult.success(["plan": "两天", "next": "跟司机说行程好了。"])
        let done = d.send(.toolFinished(TurnID(1), call, result))
        #expect(responses(done).isEmpty)
        #expect(texts(done).contains { $0.hasPrefix("（刚才plan_trip的结果：{") && $0.hasSuffix("）跟司机说行程好了。") })
        #expect(done.contains { if case .provider(.text(_, turnComplete: true)) = $0 { true } else { false } })
    }

    @Test("T-016q F-05 row 14: on Gemini the same call is answered only when it finishes (NON_BLOCKING unchanged)")
    func row14Gemini() {
        var d = AsyncToolTests.asking("帮我安排珠海两天")
        let call = ToolCall(id: CallID("call_p")!, name: "plan_trip", arguments: ["asked": ["text": "珠海两天"]])
        #expect(responses(d.realtime(.toolCalls(TurnID(1), [call]))).isEmpty)
        #expect(responses(d.send(.toolFinished(TurnID(1), call, .success(["plan": "两天"])))).map(\.id) == [call.id])
    }

    @Test("T-016q F-05 row 15: the Qwen socket drops; a fresh reconnect with the summary note; qwen reconnect fresh=yes")
    func row15() {
        var d = qwenAsking("打开空调")
        d.realtime(.toolCalls(TurnID(1), [climateOn()]))
        d.send(.toolFinished(TurnID(1), climateOn(), .success(["power": "on"])))
        d.realtime(.replyText(TurnID(1), "空调开了。"))
        let exchange = d.realtime(.responseDone(TurnID(1), outcome: .completed))
        #expect(exchange.contains { if case .exchange = $0 { true } else { false } })
        d.send(.playback(.replyFinished(d.state.arbiter.epoch)))
        d.send(.playback(.replyIdle(d.state.arbiter.epoch)))
        d.realtime(.failed(RealtimeError(.connectionClosed)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let reconnect = d.send(.timer(.session(timer.last!)))
        #expect(reconnect.contains { if case .provider(.connect(_, resume: nil)) = $0 { true } else { false } })
        #expect(reconnect.contains(.diagnostic(.qwenReconnect)))
        #expect(DiagnosticEvent.qwenReconnect.logLine == "qwen reconnect fresh=yes")
        let ready = d.realtime(.setupComplete)
        let note = texts(ready).first ?? ""
        #expect(note.hasPrefix("[系统] 接着之前的对话。最近几句：司机「"))
        #expect(note.contains("空调开了。"))
        #expect(ready.contains { if case .diagnostic(.summaryNote(exchanges: 1, _)) = $0 { true } else { false } })
    }

    @Test("T-016q F-05 row 15: a Gemini session (no fresh-reconnect memory) logs no qwen reconnect")
    func row15Gemini() {
        var d = Drive()
        d.connect()
        d.realtime(.failed(RealtimeError(.connectionClosed)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        #expect(!d.send(.timer(.session(timer.last!))).contains(.diagnostic(.qwenReconnect)))
    }

    @Test("T-020e F-07 row 28: session start with each 语音模型: revoicing false, no TTS clause, a clean turn's audio released as it arrives (held_ms 0)")
    func t020eRow28() {
        let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])
        for model in VoiceModel.allCases {
            var d = Drive()
            d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false, backgroundTools: model.backgroundTools,
                                 freshReconnect: model.resumes ? nil : ExchangeMemory())
            d.connect()
            #expect(!d.state.revoicing)
            d.send(.speechStarted(recentSpeech: true))
            d.send(.speechStopped)
            let t1 = TurnID(1)
            d.realtime(.userTranscript("讲个笑话", isFinal: true))
            d.realtime(.responseStarted(t1))
            d.realtime(.replyText(t1, "好的，有一只小猫。"))
            let out = d.realtime(.replyAudio(t1, pcm))
            #expect(out.contains(.playReplyAudio(t1, pcm)))
            #expect(spoken(d.effects).isEmpty)
            var timing = GeminiVoiceTiming(source: model.timingSource)
            timing.audioReceived(turn: 1, at: d.now)
            let line = timing.audioPlayed(turn: 1, at: d.now)
            #expect(line?.heldMs == 0)
            #expect(line?.source == (model.isQwen ? "qwen-realtime" : "gemini"))
        }
    }
}
