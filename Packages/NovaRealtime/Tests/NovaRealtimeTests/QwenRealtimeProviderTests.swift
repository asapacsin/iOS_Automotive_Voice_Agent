import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

/// A scripted Qwen-Audio realtime server: frames flow after the client's `session.update`.
final class FakeQwenServer: WebSocketConnector, @unchecked Sendable {
    let opened = Mutex<[QwenFakeSocket]>([])
    private let frames: [String]
    private let closeAfter: WebSocketClosed?

    init(frames: [String], closeAfter: WebSocketClosed? = nil) {
        self.frames = frames
        self.closeAfter = closeAfter
    }

    func open(_ request: URLRequest) async throws -> any WebSocketConnection {
        let socket = QwenFakeSocket(request: request, frames: frames, closeAfter: closeAfter)
        opened.withLock { $0.append(socket) }
        return socket
    }
}

final class QwenFakeSocket: WebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    let sent = Mutex<[String]>([])
    private let inbox = FakeInbox()
    private let frames: [String]
    private let closeAfter: WebSocketClosed?
    private let started = Mutex(false)

    init(request: URLRequest, frames: [String], closeAfter: WebSocketClosed?) {
        self.request = request
        self.frames = frames
        self.closeAfter = closeAfter
    }

    func send(_ text: String) async throws {
        sent.withLock { $0.append(text) }
        guard text.contains("\"session.update\""), started.withLock({ s in defer { s = true }; return !s }) else { return }
        for frame in frames { await inbox.push(.success(Data(frame.utf8))) }
        if let closeAfter { await inbox.push(.failure(closeAfter)) }
    }

    func receive() async throws -> Data {
        switch await inbox.next() {
        case .success(let data): return data
        case .failure(let closed): throw closed
        }
    }

    func ping() async throws {}

    func close() {
        let inbox = self.inbox
        Task { await inbox.finish() }
    }

    var messages: [JSONValue] {
        sent.withLock { $0 }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}

private func config() -> SessionConfig {
    SessionConfig(model: "qwen-audio-3.1-realtime-flash", systemInstruction: "你是小诺。",
                  tools: [ToolDeclaration(name: "navigate_to", description: "导航",
                                          parametersJSONSchema: ["type": "object", "properties": ["destination": ["type": "string"]]]),
                          ToolDeclaration(name: "plan_trip", description: "行程", parametersJSONSchema: ["type": "object"])],
                  thinkingLevel: nil)
}

final class LineBox: Sendable {
    let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    init() {}
}

private func provider(_ server: FakeQwenServer, lines: LineBox? = nil) -> QwenRealtimeProvider {
    QwenRealtimeProvider(credentials: KeyCredentials(), connector: server, onLine: { line in lines?.lines.withLock { $0.append(line) } })
}

/// Reads events until `count` are in or the socket ends.
private func collect(_ p: QwenRealtimeProvider, until stop: (RealtimeEvent) -> Bool) async -> [RealtimeEvent] {
    var out: [RealtimeEvent] = []
    for await e in p.events {
        out.append(e.event)
        if stop(e.event) { break }
    }
    return out
}

private func waitSent(_ socket: QwenFakeSocket, _ count: Int) async {
    for _ in 0..<200 where socket.sent.withLock({ $0.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
}

@Suite("T-016q F-05 §15 QwenRealtimeProvider")
struct QwenRealtimeProviderTests {
    @Test("T-016q F-05 row 11: connect sends session.update first with instructions, converted tools, smart_turn_v2, 50 turns; setupComplete on session.updated")
    func row11() async throws {
        let server = FakeQwenServer(frames: [#"{"type":"session.created"}"#, #"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(config(), resume: nil, connection: Generation(1))
        let events = await collect(p) { $0 == .setupComplete }
        #expect(events == [RealtimeEvent.setupComplete])
        let socket = try #require(server.opened.withLock { $0.first })
        #expect(socket.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        // T-016r: the fixed Beijing endpoint, never the saved 千问 voice API Host.
        #expect(socket.request.url?.absoluteString
            == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.1-realtime-flash")
        let first = try #require(socket.messages.first)
        #expect(first["type"] == "session.update")
        let session = try #require(first["session"])
        #expect(session["instructions"] == "你是小诺。")
        #expect(session["turn_detection"] == ["type": "smart_turn_v2"])
        #expect(session["max_history_turns"] == .int(50))
        #expect(session["voice"] == "longanqian_v3.1")
        #expect(session["modalities"] == ["text", "audio"])
        #expect(session["tools"] == [
            ["type": "function", "function": ["name": "navigate_to", "description": "导航",
                                              "parameters": ["type": "object", "properties": ["destination": ["type": "string"]]]]],
            ["type": "function", "function": ["name": "plan_trip", "description": "行程", "parameters": ["type": "object"]]],
        ])
        await p.close()
    }

    @Test("T-016q F-05 row 12: transcript, audio, two calls in one toolCalls, response.done completed and cancelled, error → the item 4 events in order")
    func row12() async throws {
        let audio = Data([1, 0, 2, 0]).base64EncodedString()
        let frames = [
            #"{"type":"session.updated"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"导航"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"导航去珠海站"}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"response.audio_transcript.delta","delta":"好的"}"#,
            "{\"type\":\"response.audio.delta\",\"delta\":\"\(audio)\"}",
            #"{"type":"response.function_call_arguments.done","call_id":"call_1","name":"navigate_to","arguments":"{\"destination\":\"珠海站\"}"}"#,
            #"{"type":"response.function_call_arguments.done","call_id":"call_2","name":"plan_trip","arguments":"{}"}"#,
            #"{"type":"response.audio.done"}"#,
            #"{"type":"response.done","response":{"status":"completed","usage":{"input_token_details":{"audio_tokens":120,"text_tokens":900},"output_token_details":{"audio_tokens":300,"text_tokens":20}}}}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"input_audio_buffer.speech_started"}"#,
            #"{"type":"response.done","response":{"status":"cancelled","status_details":{"reason":"turn_detected"}}}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"response.done","response":{"status":"cancelled","status_details":{"reason":"turn_detected"}}}"#,
            #"{"type":"error","error":{"type":"server_error","code":"Arrearage"}}"#,
        ]
        let lines = LineBox()
        let server = FakeQwenServer(frames: frames)
        let p = provider(server, lines: lines)
        await p.connect(config(), resume: nil, connection: Generation(1))
        let events = await collect(p) { if case .failed = $0 { true } else { false } }
        let t1 = TurnID(1), t2 = TurnID(2), t3 = TurnID(3)
        let expected: [RealtimeEvent] = [
            .setupComplete,
            .userTranscript("导航", isFinal: false),
            .userTranscript("导航去珠海站", isFinal: true),
            .responseStarted(t1),
            .replyText(t1, "好的"),
            .replyAudio(t1, PCMBuffer(sampleRate: 24_000, samples: [1, 2])),
            .audioDone(t1),
            .toolCalls(t1, [ToolCall(id: CallID("call_1")!, name: "navigate_to", arguments: ["destination": "珠海站"]),
                            ToolCall(id: CallID("call_2")!, name: "plan_trip", arguments: [:])]),
            .responseDone(t1, outcome: .completed),
            .responseStarted(t2),
            .interrupted(t2, reason: .serverVAD),
            .responseDone(t2, outcome: .cancelled),
            .responseStarted(t3),
            .interrupted(t3, reason: .serverVAD),
            .responseDone(t3, outcome: .cancelled),
            .failed(RealtimeError(.quota)),
        ]
        #expect(events == expected)
        #expect(lines.all.prefix(2) == ["qwen usage in=120,900 out=300,20", "qwen history turns=1"])
        #expect(!events.contains { if case .resumptionHandle = $0 { true } else if case .goAway = $0 { true } else { false } })
    }

    @Test("T-016r F-05 §15 vendor facts (row 16 precondition): the voice model connects to wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=<model>")
    func t016rEndpoint() {
        #expect(QwenRoute.realtimeEndpoint == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime")
        #expect(QwenRealtimeProvider.endpoint(model: "qwen-audio-3.1-realtime-plus")?.absoluteString
            == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.1-realtime-plus")
    }

    @Test("T-016q F-05 row 12: error and socket failures map to the session's codes")
    func row12Codes() {
        #expect(QwenRealtimeCodec.classify(handshakeStatus: 401) == .auth)
        #expect(QwenRealtimeCodec.classify(handshakeStatus: 403) == .auth)
        #expect(QwenRealtimeCodec.classify(handshakeStatus: 429) == .rateLimited)
        #expect(QwenRealtimeCodec.classify(handshakeStatus: 500) == .connectionClosed)
        #expect(QwenRealtimeCodec.classify("Arrearage") == .quota)
        #expect(QwenRealtimeCodec.classify("Throttling.RateQuota") == .quota)
        #expect(QwenRealtimeCodec.classify("InvalidApiKey") == .auth)
        #expect(QwenRealtimeCodec.classify("InternalError") == .connectionClosed)
        var a = QwenRealtimeAssembler()
        #expect(a.consume(.error(type: "invalid_request_error", code: "x")).failure == nil)
    }

    @Test("T-016q F-05 row 13: two tool results → two function_call_output items and one response.create")
    func row13() async throws {
        let server = FakeQwenServer(frames: [#"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(config(), resume: nil, connection: Generation(1))
        _ = await collect(p) { $0 == .setupComplete }
        await p.sendToolResponses([
            ToolResponse(id: CallID("call_1")!, name: "navigate_to", result: .success(["destination": "珠海站"])),
            ToolResponse(id: CallID("call_2")!, name: "get_vehicle_state", result: .failure(.vehicleExecutionFailed)),
        ])
        let socket = try #require(server.opened.withLock { $0.first })
        await waitSent(socket, 4)
        let sent = Array(socket.messages.dropFirst())
        #expect(sent.map { $0["type"] } == ["conversation.item.create", "conversation.item.create", "response.create"])
        #expect(sent[0]["item"]?["type"] == "function_call_output")
        #expect(sent[0]["item"]?["call_id"] == "call_1")
        let output = try #require(sent[0]["item"]?["output"]?.stringValue)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        #expect(decoded["ok"] == .bool(true) && decoded["destination"] == "珠海站")
        #expect(sent[1]["item"]?["call_id"] == "call_2")
        // Text turns: a user message each; response.create only with turnComplete.
        await p.sendText([TextTurn(role: .user, text: "[系统] 现在…")], turnComplete: false)
        await p.sendText([TextTurn(role: .user, text: "刚才的结果")], turnComplete: true)
        await waitSent(socket, 7)
        let more = Array(socket.messages.dropFirst(4))
        #expect(more.map { $0["type"] } == ["conversation.item.create", "conversation.item.create", "response.create"])
        #expect(more[0]["item"]?["role"] == "user")
        #expect(more[0]["item"]?["content"] == [["type": "input_text", "text": "[系统] 现在…"]])
        await p.close()
    }

    @Test("T-016q F-05 §15 item 3: audio goes up as 40 ms appends; the utterance end flushes and adds silence")
    func audioAppends() async throws {
        let server = FakeQwenServer(frames: [#"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(config(), resume: nil, connection: Generation(1))
        _ = await collect(p) { $0 == .setupComplete }
        for _ in 0..<5 { p.sendAudio(PCMFrame16k.silence) }
        p.sendActivityEnd()
        let socket = try #require(server.opened.withLock { $0.first })
        let expected = 1 + 1 + 1 + QwenRealtimeProvider.endSilenceFrames / QwenRealtimeProvider.framesPerAppend
        await waitSent(socket, expected)
        let appends = socket.messages.dropFirst().filter { $0["type"] == "input_audio_buffer.append" }
        #expect(appends.count == expected - 1)
        #expect(appends.first?["audio"]?.stringValue.flatMap { Data(base64Encoded: $0) }?.count == 4 * PCMFrame16k.byteCount)
        #expect(appends.dropFirst().first?["audio"]?.stringValue.flatMap { Data(base64Encoded: $0) }?.count == PCMFrame16k.byteCount)
        await p.close()
    }

    @Test("T-016q F-05 row 12: a refused upgrade (401) fails AUTH; a drop fails retryable")
    func socketFailures() async {
        let refused = FakeQwenServer(frames: [], closeAfter: WebSocketClosed(code: 1006, reason: "", httpStatus: 401))
        let p = provider(refused)
        await p.connect(config(), resume: nil, connection: Generation(1))
        let refusedEvents = await collect(p) { _ in true }
        #expect(refusedEvents == [RealtimeEvent.failed(RealtimeError(.auth))])
        let dropped = FakeQwenServer(frames: [#"{"type":"session.updated"}"#], closeAfter: WebSocketClosed(code: 1006, reason: ""))
        let q = provider(dropped)
        await q.connect(config(), resume: nil, connection: Generation(1))
        let events = await collect(q) { if case .failed = $0 { true } else { false } }
        #expect(events.last == .failed(RealtimeError(.connectionClosed)))
        #expect(RealtimeError(.connectionClosed).isRetryable)
    }
}
