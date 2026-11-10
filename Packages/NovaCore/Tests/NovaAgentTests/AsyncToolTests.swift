import Foundation
import NovaTools
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

func liveInfoCall(_ id: String = "call_w") -> ToolCall {
    ToolCall(id: CallID(id)!, name: "query_live_info", arguments: ["kind": "weather", "where": "上海"])
}

/// F-18 §27 rows 2–4 (T-020c), the core side. The codec rows (1–3 wire format) are in NovaRealtime.
@Suite("T-020c F-18 §27 background search")
struct AsyncToolTests {
    static func asking(_ words: String = "现在天气怎么样", revoicing: Bool = false) -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: revoicing)
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript(words, isFinal: true))
        d.realtime(.responseStarted(TurnID(1)))
        return d
    }

    static func responses(_ effects: [AgentEffect]) -> [ToolResponse] {
        var out: [ToolResponse] = []
        for case .provider(.toolResponses(let r)) in effects { out += r }
        return out
    }

    @Test("Row 2: query_live_info runs 3 s while her audio keeps playing; the result goes back WHEN_IDLE with its time")
    func backgroundLiveInfo() throws {
        var d = Self.asking()
        let call = liveInfoCall()
        let started = d.realtime(.toolCalls(TurnID(1), [call]))
        #expect(started.contains(.startTool(TurnID(1), call)))
        // While it runs: Gemini's 「我查一下」 audio is played, nothing waits on the tool.
        let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])
        let start = d.now
        for second in 1...3 {
            d.now = start + .seconds(Int64(second))
            let played = GeminiVoiceTests.played(d.realtime(.replyAudio(TurnID(1), pcm)))
            if second == 1 {
                // F-05a §15 item 3: no text yet, so the first audio waits at most 800 ms for the language verdict.
                #expect(played.isEmpty)
                #expect(GeminiVoiceTests.played(d.fire(.language)) == [TurnID(1)])
            } else {
                #expect(played == [TurnID(1)])
            }
        }
        d.now = start + .seconds(3)
        let done = d.send(.toolFinished(TurnID(1), call, .success(["temperature_c": 12])))
        let r = try #require(Self.responses(done).first)
        #expect(r.scheduling == "WHEN_IDLE" && r.elapsedMs == 3_000)
    }

    @Test("Row 3: control_climate is answered as before: no scheduling, no time")
    func blockingClimate() {
        var d = Self.asking("打开空调")
        d.realtime(.toolCalls(TurnID(1), [climateOn()]))
        let r = Self.responses(d.send(.toolFinished(TurnID(1), climateOn(), .success(["power": true]))))
        #expect(r.count == 1 && r[0].scheduling == nil && r[0].elapsedMs == nil)
    }

    @Test("Row 4: the socket drops while web_search runs: cancelled, dropped reason=reconnect, result never sent")
    func reconnectDrops() {
        var d = Self.asking("今天油价多少")
        let call = searchCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        let failed = d.realtime(.failed(RealtimeError(.disconnect)))
        #expect(failed.contains(.cancelTool(call.id)))
        #expect(failed.contains(.diagnostic(.asyncToolDropped(tool: .webSearch))))
        #expect(DiagnosticEvent.asyncToolDropped(tool: .webSearch).logLine == "tool-result web_search dropped reason=reconnect")
        #expect(Self.responses(d.send(.toolFinished(TurnID(1), call, .success(["answer": "7元"])))).isEmpty)
    }

    @Test("Item 4: a barge-in does not cancel a running search; its result is still sent")
    func bargeInKeepsSearch() {
        var d = Self.asking("今天油价多少", revoicing: true)
        let call = searchCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        d.realtime(.replyText(TurnID(1), "我查一下。"))
        d.send(.playback(.replyStarted(d.state.arbiter.epoch)))
        #expect(!d.send(.bargeInStop).contains(.cancelTool(call.id)))
        #expect(Self.responses(d.send(.toolFinished(TurnID(1), call, .success(["answer": "7元"])))).first?.id == call.id)
    }

    @Test("Item 6: record lines tool-call async=true and tool-result scheduling=WHEN_IDLE ms=; dropped line")
    func recordLines() {
        var r = ConversationRecorder()
        #expect(r.add(.toolCall(name: "web_search", arguments: ["query": "油价"]), atMs: 1)
            == [#"1 tool-call web_search async=true {"query":"油价"}"#])
        #expect(r.add(.toolCall(name: "control_climate", arguments: [:]), atMs: 2) == ["2 tool-call control_climate {}"])
        #expect(r.add(.toolResult(name: "query_live_info", ok: true, code: nil, data: [:], elapsedMs: 3_000), atMs: 3)
            == ["3 tool-result query_live_info scheduling=WHEN_IDLE ms=3000 ok=true code=none {}"])
        #expect(r.add(.toolDropped(.webSearch), atMs: 4) == ["4 tool-result web_search dropped reason=reconnect"])
    }
}

/// F-07 §16 row 17 (T-020c): her received audio kept per turn, byte for byte.
@Suite("T-020c F-07 §16 keep her received audio")
struct ReplyAudioKeeperTests {
    @Test("Row 17: two turns give two 24 kHz mono 16-bit WAVs whose data equals the received audio")
    func twoTurns() throws {
        var k = ReplyAudioKeeper(record: "20261107-144201.txt")
        let a1 = PCMBuffer(sampleRate: 24_000, samples: [1, -2, 300])
        let a2 = PCMBuffer(sampleRate: 24_000, samples: [Int16.min, Int16.max])
        k.add(TurnID(1), a1)
        k.add(TurnID(1), a2)
        let r1 = k.finish(TurnID(1))
        let f1 = try #require(r1)
        let again = k.finish(TurnID(1))
        #expect(again == nil)   // generation complete then turn complete: one file
        k.add(TurnID(2), a1)
        let r2 = k.finish(TurnID(2))
        let f2 = try #require(r2)
        #expect(f1.name == "20261107-144201-turn1.wav" && f2.name == "20261107-144201-turn2.wav")
        func le(_ s: [Int16]) -> Data { s.reduce(into: Data()) { d, v in withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } } }
        #expect(f1.wav.dropFirst(44) == le(a1.samples + a2.samples))
        #expect(f2.wav.dropFirst(44) == le(a1.samples))
        let h = [UInt8](f1.wav.prefix(44))
        func u32(_ o: Int) -> Int { Int(h[o]) | Int(h[o+1]) << 8 | Int(h[o+2]) << 16 | Int(h[o+3]) << 24 }
        func u16(_ o: Int) -> Int { Int(h[o]) | Int(h[o+1]) << 8 }
        #expect(String(decoding: h[0..<4], as: UTF8.self) == "RIFF" && String(decoding: h[8..<12], as: UTF8.self) == "WAVE")
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 24_000 && u16(34) == 16 && u32(40) == 10)
        // A turn with no audio (a tool-only turn) writes nothing.
        let none = k.finish(TurnID(3))
        #expect(none == nil)
    }

    @Test("Item 2: the playback format line")
    func formatLine() {
        #expect(PlaybackFormat(rate: 48_000, channels: 1, mode: "voiceChat", voiceProcessing: true).line
            == "playback format rate=48000 channels=1 mode=voiceChat voiceProcessing=on")
    }
}

@Suite("T-020c review fixes")
struct AsyncToolReviewTests {
    @Test("A later turn of an utterance whose call was blocking is still held whole (I-1, I-5)")
    func laterTurnHeld() {
        var p = DriverTurnPipeline(streamsCleanAudio: true)
        let now = NovaInstant.zero
        _ = p.handle(.driverUtterance("我有点冷"), at: now)
        _ = p.handle(.turnOpened(TurnID(1)), at: now)
        _ = p.handle(.toolCalls(TurnID(1), [climateOn()]), at: now)
        _ = p.handle(.turnOpened(TurnID(2)), at: now)
        let out = p.handle(.replyAudio(TurnID(2), PCMBuffer(sampleRate: 24_000, samples: [1])), at: now)
        #expect(!out.contains { if case .speechAudio = $0 { true } else { false } })
    }

    @Test("A server-cancelled query_live_info frees the tool count")
    func cancelledLiveInfo() {
        var d = AsyncToolTests.asking()
        let call = liveInfoCall()
        d.realtime(.toolCalls(TurnID(1), [call]))
        d.realtime(.toolCallCancellation([call.id]))
        #expect(d.state.runningTools == 0)
    }
}
