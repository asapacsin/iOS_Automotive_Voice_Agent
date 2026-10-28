import Foundation
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

/// Recorded Gemini Live sessions (T-003, iPhone 17, 2026-10-25), replayed frame by frame.
enum Fixtures {
    struct Entry {
        let frame: Data?
        let close: (code: Int, reason: String)?
        let note: String?
    }

    static func load(_ name: String) throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/gemini/\(name).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let entry = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            switch entry["dir"]?.stringValue {
            case "server":
                return Entry(frame: try JSONValue.canonicalEncoder().encode(entry["message"] ?? [:]), close: nil, note: nil)
            case "server-raw":
                return Entry(frame: Data((entry["text"]?.stringValue ?? "").utf8), close: nil, note: nil)
            case "close":
                return Entry(frame: nil, close: (Int(entry["code"]?.intValue ?? 0), entry["reason"]?.stringValue ?? ""),
                             note: nil)
            default:
                return Entry(frame: nil, close: nil, note: entry["text"]?.stringValue)
            }
        }
    }

    /// Events per connection; a note "reconnect with handle" starts a new connection and assembler.
    static func replay(_ name: String) throws -> [[RealtimeEvent]] {
        var connections: [[RealtimeEvent]] = [[]]
        var assembler = GeminiTurnAssembler()
        for entry in try load(name) {
            if entry.note == "reconnect with handle" {
                connections.append([])
                assembler = GeminiTurnAssembler()
            }
            guard let frame = entry.frame else { continue }
            let parts = try #require(GeminiCodec.decode(frame))
            connections[connections.count - 1] += assembler.consume(parts)
        }
        return connections
    }
}

/// Control events only (reply text and audio left out), so order assertions stay readable.
func shape(_ events: [RealtimeEvent]) -> [String] {
    var out: [String] = []
    for event in events {
        let name: String
        switch event {
        case .setupComplete: name = "setupComplete"
        case .userTranscript: name = "userTranscript"
        case .responseStarted(let t): name = "responseStarted(\(t))"
        case .replyText, .replyAudio: continue
        case .toolCalls(let t, let calls): name = "toolCalls(\(t),\(calls.map(\.name).joined(separator: ",")))"
        case .toolCallCancellation: name = "toolCallCancellation"
        case .audioDone(let t): name = "audioDone(\(t))"
        case .interrupted(let t, let r): name = "interrupted(\(t),\(r.rawValue))"
        case .responseDone(let t, let o): name = "responseDone(\(t),\(o.rawValue))"
        case .resumptionHandle(let h): name = h == nil ? "handle(nil)" : "handle"
        case .goAway: name = "goAway"
        case .failed(let e): name = "failed(\(e.code.rawValue))"
        case .closed: name = "closed"
        }
        out.append(name)
    }
    return out
}

@Suite("T-015 F-05 Gemini codec and turn assembler (fixture replay)")
struct GeminiReplayTests {
    @Test("F-05 plain turn: setup, then one audio turn in §4 order")
    func plain() throws {
        let events = try Fixtures.replay("plain")[0]
        let s = shape(events)
        #expect(Array(s.prefix(3)) == ["setupComplete", "handle", "responseStarted(1)"])
        #expect(events.contains { if case .replyAudio(let t, let pcm) = $0 { t.value == 1 && pcm.sampleRate == 24_000 } else { false } })
        #expect(s.suffix(2) == ["audioDone(1)", "responseDone(1,completed)"])
        let text = events.compactMap { if case .replyText(_, let t) = $0 { t } else { nil } }.joined()
        #expect(text.contains("Nova"))
    }

    @Test("F-05 tool turn: call opens turn 1 unheld, the answer after toolResponse is turn 2")
    func tool() throws {
        let s = shape(try Fixtures.replay("tool")[0])
        #expect(s == ["setupComplete", "handle", "responseStarted(1)", "toolCalls(1,control_climate)",
                      "audioDone(1)", "responseDone(1,completed)",
                      "responseStarted(2)", "audioDone(2)", "responseDone(2,completed)"])
        let calls = try Fixtures.replay("tool")[0].compactMap { if case .toolCalls(_, let c) = $0 { c } else { nil } }
        #expect(calls.first?.first?.arguments == ["action": "on"])
    }

    @Test("F-05 interrupted: §4 rule 5 closes the turn cancelled and ignores the trailing turnComplete")
    func interrupted() throws {
        let s = shape(try Fixtures.replay("interrupted")[0])
        #expect(s.suffix(3) == ["audioDone(1)", "interrupted(1,server_vad)", "responseDone(1,cancelled)"])
        #expect(!s.contains("responseDone(1,completed)"))
    }

    @Test("F-05 resumption: a handle from connection 1 sets up connection 2, which answers from memory")
    func resumption() throws {
        let connections = try Fixtures.replay("resumption")
        #expect(connections.count == 2)
        #expect(connections[0].contains { if case .resumptionHandle(let h?) = $0 { !h.isEmpty } else { false } })
        let second = shape(connections[1])
        #expect(second.first == "setupComplete")
        #expect(second.last == "responseDone(1,completed)")
        let answer = connections[1].compactMap { if case .replyText(_, let t) = $0 { t } else { nil } }.joined()
        #expect(answer.contains("七") || answer.contains("7"))
    }

    @Test("F-05 empty `{}` frames decode to no parts, non-JSON frames to nil")
    func emptyFrames() throws {
        #expect(GeminiCodec.decode(Data("{}\n".utf8)) == [])
        #expect(GeminiCodec.decode(Data("not json".utf8)) == nil)
        #expect(try Fixtures.load("tool").contains { $0.frame == Data("{}\n".utf8) })
    }
}

@Suite("T-015 F-05 turn ordering rules 1-2 (synthetic frames)")
struct GeminiOrderingTests {
    func frame(_ json: String) -> [GeminiServerPart] { GeminiCodec.decode(Data(json.utf8)) ?? [] }

    @Test("F-05 §4 rules 1-2: stashed output text; opening flushes UserTranscript, then ResponseStarted, then the text")
    func stashAndFlush() {
        var a = GeminiTurnAssembler()
        var events = a.consume(frame(#"{"serverContent":{"inputTranscription":{"text":"打开"}}}"#))
        events += a.consume(frame(#"{"serverContent":{"inputTranscription":{"text":"空调"}}}"#))
        events += a.consume(frame(#"{"serverContent":{"outputTranscription":{"text":"好的"}}}"#))
        #expect(events == [.userTranscript("打开", isFinal: false), .userTranscript("空调", isFinal: false)])
        let opened = a.consume(frame(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"control_climate","args":{"action":"power_on"}}]}}"#))
        let call = ToolCall(id: CallID("c1")!, name: "control_climate", arguments: ["action": "power_on"])
        #expect(opened == [.userTranscript("打开空调", isFinal: true), .responseStarted(TurnID(1)),
                           .replyText(TurnID(1), "好的"), .toolCalls(TurnID(1), [call])])
    }

    @Test("F-05 §4 rule 1: transcript alone never opens a turn; a text-only turn completes with nothing leaking")
    func textOnly() {
        var a = GeminiTurnAssembler()
        let events = a.consume(frame(#"{"serverContent":{"outputTranscription":{"text":"嗯"},"turnComplete":true}}"#))
        #expect(events.isEmpty)
        let next = a.consume(frame(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"AAAA"}}]}}}"#))
        #expect(next.first == .responseStarted(TurnID(1)))
        #expect(!next.contains(.replyText(TurnID(1), "嗯")))
    }
}

@Suite("T-015 F-05 close classification")
struct GeminiCloseTests {
    @Test("F-05 recorded 1007: a rejected setup is MALFORMED (terminal); on a resumed setup RESUME_UNAVAILABLE")
    func close1007() throws {
        let close = try #require(try Fixtures.load("close1007").compactMap(\.close).first)
        #expect(close.code == 1007)
        #expect(GeminiCloseClassifier.classify(code: close.code, reason: close.reason, resumedSetup: false) == .malformed)
        #expect(GeminiCloseClassifier.classify(code: 1007, reason: "", resumedSetup: true) == .resumeUnavailable)
        #expect(!RealtimeErrorCode.malformed.isRetryable)
        #expect(RealtimeErrorCode.resumeUnavailable.isRetryable)
    }

    @Test("F-05 recorded 1008 on an unknown handle is RESUME_UNAVAILABLE; other 1008 CONNECTION_CLOSED unless auth/quota")
    func close1008() throws {
        let close = try #require(try Fixtures.load("close1008").compactMap(\.close).first)
        #expect(close.code == 1008)
        #expect(GeminiCloseClassifier.classify(code: close.code, reason: close.reason, resumedSetup: true) == .resumeUnavailable)
        #expect(GeminiCloseClassifier.classify(code: 1008, reason: "Policy violation", resumedSetup: false) == .connectionClosed)
        #expect(GeminiCloseClassifier.classify(code: 1008, reason: "API key not valid", resumedSetup: false) == .auth)
        #expect(GeminiCloseClassifier.classify(code: 1008, reason: "Quota exceeded", resumedSetup: false) == .quota)
        #expect(GeminiCloseClassifier.classify(code: 1000, reason: "", resumedSetup: false) == nil)
        #expect(GeminiCloseClassifier.classify(code: 1006, reason: "", resumedSetup: false) == .disconnect)
    }
}

@Suite("T-015 F-05 client messages")
struct GeminiClientMessageTests {
    @Test("F-05 setup carries model, AUDIO, zh-CN voice, thinking, VAD, tools, transcription and the handle")
    func setup() throws {
        var config = SessionConfig(systemInstruction: "persona", tools: [
            ToolDeclaration(name: "control_climate", description: "d", parametersJSONSchema: ["type": "object"]),
        ])
        config.activityDetection.silenceDuration = .milliseconds(50)
        let msg = GeminiCodec.setup(config, resume: "h1")["setup"]
        #expect(msg?["model"] == "models/gemini-3.8-live")
        #expect(msg?["generationConfig"]?["responseModalities"] == ["AUDIO"])
        #expect(msg?["generationConfig"]?["speechConfig"]?["languageCode"] == "zh-CN")
        #expect(msg?["generationConfig"]?["thinkingConfig"]?["thinkingLevel"] == "LOW")
        #expect(msg?["realtimeInputConfig"]?["automaticActivityDetection"]?["silenceDurationMs"] == 100)
        #expect(msg?["realtimeInputConfig"]?["automaticActivityDetection"]?["startOfSpeechSensitivity"]
            == "START_SENSITIVITY_LOW")
        #expect(msg?["tools"] == [["functionDeclarations": [[
            "name": "control_climate", "description": "d", "parametersJsonSchema": ["type": "object"]]]]])
        #expect(msg?["sessionResumption"] == ["handle": "h1"])
        #expect(msg?["inputAudioTranscription"] == [:])
        #expect(msg?["contextWindowCompression"] == ["slidingWindow": [:]])
        #expect(GeminiCodec.setup(config, resume: nil)["setup"]?["sessionResumption"] == [:])
    }

    @Test("Manual activity detection disables the server's and brackets the utterance")
    func manualActivity() {
        var config = SessionConfig(systemInstruction: "persona", tools: [])
        config.activityDetection.manual = true
        let msg = GeminiCodec.setup(config, resume: nil)["setup"]
        #expect(msg?["realtimeInputConfig"]?["automaticActivityDetection"] == ["disabled": true])
        // Owner rule 2026-10-28: driver activity never drops her reply; only a stop phrase stops her.
        #expect(msg?["realtimeInputConfig"]?["activityHandling"] == "NO_INTERRUPTION")
        // Owner rule 2026-10-28: driver activity never drops her reply; only a stop phrase stops her.
        #expect(msg?["realtimeInputConfig"]?["activityHandling"] == "NO_INTERRUPTION")
        // Owner rule 2026-10-28: driver activity never drops her reply; only a stop phrase stops her.
        #expect(msg?["realtimeInputConfig"]?["activityHandling"] == "NO_INTERRUPTION")
        #expect(GeminiCodec.activityStart == ["realtimeInput": ["activityStart": [:]]])
        #expect(GeminiCodec.activityEnd == ["realtimeInput": ["activityEnd": [:]]])
    }

    @Test("F-05 audio is 16 kHz little-endian base64; tool responses carry ok, code and data")
    func audioAndTools() throws {
        var samples = Array(repeating: Int16(0), count: PCMFrame16k.samplesPerFrame)
        samples[0] = 0x0102
        samples[1] = -1
        let frame = try #require(PCMFrame16k(samples: samples))
        let data = try #require(GeminiCodec.audio([frame])["realtimeInput"]?["audio"]?["data"]?.stringValue)
        let bytes = try #require(Data(base64Encoded: data))
        #expect(bytes.count == PCMFrame16k.byteCount)
        #expect(Array(bytes.prefix(4)) == [0x02, 0x01, 0xFF, 0xFF])
        let id = try #require(CallID("call_1"))
        let response = GeminiCodec.toolResponses([ToolResponse(id: id, name: "control_climate",
            result: .failure(.vehicleUnavailable, advice: "稍后再试"))])
        let first = response["toolResponse"]?["functionResponses"]
        #expect(first == [["id": "call_1", "name": "control_climate",
                          "response": ["ok": false, "code": "VEHICLE_UNAVAILABLE", "advice": "稍后再试"]]])
        #expect(GeminiCodec.duration("12.5s") == .milliseconds(12_500))
    }
}
