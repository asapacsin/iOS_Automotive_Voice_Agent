import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

/// A scripted Qwen-Audio realtime server: its frames flow after the client's first message (`session.update`).
private final class FakeQwenServer: WebSocketConnector, @unchecked Sendable {
    let frames: [String]
    let closeAfter: WebSocketClosed?
    let opened = Mutex<[FakeQwenSocket]>([])

    init(_ frames: [String], closeAfter: WebSocketClosed? = nil) {
        self.frames = frames
        self.closeAfter = closeAfter
    }

    func open(_ request: URLRequest) async throws -> any WebSocketConnection {
        let socket = FakeQwenSocket(request: request, frames: frames, closeAfter: closeAfter)
        opened.withLock { $0.append(socket) }
        return socket
    }
}

private final class FakeQwenSocket: WebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    let sent = Mutex<[String]>([])
    private let inbox = FakeInbox()
    private let frames: [String]
    private let closeAfter: WebSocketClosed?

    init(request: URLRequest, frames: [String], closeAfter: WebSocketClosed?) {
        self.request = request
        self.frames = frames
        self.closeAfter = closeAfter
    }

    func send(_ text: String) async throws {
        let first = sent.withLock { s -> Bool in s.append(text); return s.count == 1 }
        guard first else { return }
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
        let inbox = inbox
        Task { await inbox.finish() }
    }

    func messages() -> [JSONValue] {
        sent.withLock { $0 }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}

private func provider(_ server: FakeQwenServer, usage: (@Sendable (QwenUsage) -> Void)? = nil) -> QwenRealtimeProvider {
    QwenRealtimeProvider(key: { "test-key" }, model: "qwen-audio-3.1-realtime-flash",
                         connector: server, onUsage: usage)
}

private func collect(_ p: QwenRealtimeProvider, until last: (RealtimeEvent) -> Bool) async -> [RealtimeEvent] {
    var out: [RealtimeEvent] = []
    for await e in p.events {
        out.append(e.event)
        if last(e.event) { break }
    }
    return out
}

private func waitSent(_ socket: FakeQwenSocket, count: Int) async {
    for _ in 0..<200 where socket.sent.withLock({ $0.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
}

private let tool = ToolDeclaration(name: "navigate_to", description: "导航",
                                   parametersJSONSchema: ["type": "object", "properties": ["destination": ["type": "string"]]])

@Suite("T-016q F-05 §15 QwenRealtimeProvider")
struct QwenRealtimeProviderTests {
    @Test("T-016q F-05 row 11: connect sends session.update first (instructions, tools converted, smart_turn_v2, 50 turns); setupComplete on session.updated")
    func row11() async throws {
        let server = FakeQwenServer([#"{"type":"session.created"}"#, #"{"type":"session.updated"}"#, #"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(SessionConfig(systemInstruction: "你是小诺", tools: [tool]), resume: nil, connection: Generation(1))
        let events = await collect(p) { $0 == .setupComplete }
        #expect(events == [.setupComplete])
        let socket = try #require(server.opened.withLock { $0.first })
        // T-016r: the fixed Beijing public endpoint (the PC handshake accepted it with the Beijing key).
        #expect(socket.request.url?.absoluteString
            == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.1-realtime-flash")
        #expect(socket.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let first = try #require(socket.messages().first)
        #expect(first["type"] == "session.update")
        let session = try #require(first["session"])
        #expect(session["instructions"] == "你是小诺")
        #expect(session["turn_detection"] == ["type": "smart_turn_v2"])
        #expect(session["max_history_turns"] == 50)
        #expect(session["voice"] == "longanqian_v3.1")
        #expect(session["modalities"] == ["text", "audio"])
        #expect(session["tools"] == [["type": "function", "function": [
            "name": "navigate_to", "description": "导航", "parameters": tool.parametersJSONSchema]]])
        #expect(p.capabilities.resumption == false && p.capabilities.backgroundTools == false)
        await p.close()
    }

    @Test("T-016q F-05 row 12: server events map to item 4's RealtimeEvents in order; two calls in one toolCalls")
    func row12() async throws {
        let audio = Data([1, 0, 2, 0]).base64EncodedString()
        let usage = Mutex<[QwenUsage]>([])
        let server = FakeQwenServer([
            #"{"type":"session.updated"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"导航"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"导航去珠海站"}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"response.audio_transcript.delta","delta":"好的"}"#,
            "{\"type\":\"response.audio.delta\",\"delta\":\"\(audio)\"}",
            #"{"type":"response.function_call_arguments.done","call_id":"call_1","name":"navigate_to","arguments":"{\"destination\":\"珠海站\"}"}"#,
            #"{"type":"response.function_call_arguments.done","call_id":"call_2","name":"find_events","arguments":"{\"cities\":[\"珠海\"]}"}"#,
            #"{"type":"response.audio.done"}"#,
            #"{"type":"response.done","response":{"status":"completed","usage":{"input_token_details":{"audio_tokens":120,"text_tokens":30},"output_token_details":{"audio_tokens":400,"text_tokens":25}}}}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"input_audio_buffer.speech_started"}"#,
            #"{"type":"response.done","response":{"status":"cancelled","status_details":{"reason":"turn_detected"}}}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"response.done","response":{"status":"cancelled","status_details":{"reason":"turn_detected"}}}"#,
            #"{"type":"error","error":{"type":"invalid_request_error","code":"x"}}"#,
            #"{"type":"error","error":{"type":"server_error","code":"Arrearage"}}"#,
        ])
        let p = provider(server) { u in usage.withLock { $0.append(u) } }
        await p.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        let events = await collect(p) { if case .failed = $0 { true } else { false } }
        let t1 = TurnID.initial.next(), t2 = t1.next(), t3 = t2.next()
        #expect(events == [
            .setupComplete,
            .userTranscript("导航", isFinal: false),
            .userTranscript("导航去珠海站", isFinal: true),
            .responseStarted(t1),
            .replyText(t1, "好的"),
            .replyAudio(t1, PCMBuffer(sampleRate: 24_000, samples: [1, 2])),
            .audioDone(t1),
            .toolCalls(t1, [ToolCall(id: CallID("call_1")!, name: "navigate_to", arguments: ["destination": "珠海站"]),
                            ToolCall(id: CallID("call_2")!, name: "find_events", arguments: ["cities": ["珠海"]])]),
            .responseDone(t1, outcome: .completed),
            .responseStarted(t2),
            .interrupted(t2, reason: .serverVAD),
            .responseDone(t2, outcome: .cancelled),
            .responseStarted(t3),
            .interrupted(t3, reason: .serverVAD),
            .responseDone(t3, outcome: .cancelled),
            .failed(RealtimeError(.quota)),
        ])
        #expect(usage.withLock { $0 } == [QwenUsage(inAudio: 120, inText: 30, outAudio: 400, outText: 25)])
        #expect(usage.withLock { $0 }.first?.logLine == "qwen usage in=120,30 out=400,25")
    }

    @Test("T-016q F-05 row 12: error and socket codes (401/403 auth, quota or Arrearage quota, 429 rate, else closed); socket end closed")
    func classify() async {
        #expect(QwenRealtimeCodec.classify(code: nil, status: 401) == .auth)
        #expect(QwenRealtimeCodec.classify(code: nil, status: 403) == .auth)
        #expect(QwenRealtimeCodec.classify(code: "InvalidApiKey", status: nil) == .auth)
        #expect(QwenRealtimeCodec.classify(code: "AllocationQuota.FreeTierOnly", status: nil) == .quota)
        #expect(QwenRealtimeCodec.classify(code: "Arrearage", status: nil) == .quota)
        #expect(QwenRealtimeCodec.classify(code: nil, status: 429) == .rateLimited)
        #expect(QwenRealtimeCodec.classify(code: "InternalError", status: nil) == .connectionClosed)
        let refused = FakeQwenServer([], closeAfter: WebSocketClosed(code: 1006, reason: "", httpStatus: 401))
        let p = provider(refused)
        await p.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        #expect(await collect(p) { _ in true } == [.failed(RealtimeError(.auth))])
        let ended = FakeQwenServer([#"{"type":"session.updated"}"#], closeAfter: WebSocketClosed(code: 1000, reason: "bye"))
        let q = provider(ended)
        await q.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        #expect(await collect(q) { $0 == .closed } == [.setupComplete, .closed])
    }

    @Test("T-016q F-05 row 13: sendToolResponses with two results: two function_call_output items, one response.create")
    func row13() async throws {
        let server = FakeQwenServer([#"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        _ = await collect(p) { $0 == .setupComplete }
        await p.sendToolResponses([
            ToolResponse(id: CallID("call_1")!, name: "navigate_to", result: .success(["started": true])),
            ToolResponse(id: CallID("call_2")!, name: "find_events", result: .success(["status": "running"])),
        ])
        let socket = try #require(server.opened.withLock { $0.first })
        await waitSent(socket, count: 4)
        let sent = Array(socket.messages().dropFirst())
        #expect(sent.map { $0["type"] } == ["conversation.item.create", "conversation.item.create", "response.create"])
        #expect(sent[0]["item"]?["type"] == "function_call_output" && sent[0]["item"]?["call_id"] == "call_1")
        #expect(sent[1]["item"]?["call_id"] == "call_2")
        let output = try #require(sent[0]["item"]?["output"]?.stringValue)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) == ["ok": true, "started": true])
        await p.close()
    }

    @Test("T-016q F-05 §15 item 3: sendText as user input_text messages, response.create only with turnComplete; audio as input_audio_buffer.append")
    func textAndAudio() async throws {
        let server = FakeQwenServer([#"{"type":"session.updated"}"#])
        let p = provider(server)
        await p.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        _ = await collect(p) { $0 == .setupComplete }
        await p.sendText([TextTurn(role: .user, text: "[系统] 现在的导航目的地是「珠海站」。")], turnComplete: false)
        await p.sendText([TextTurn(role: .user, text: "导航去珠海站")], turnComplete: true)
        let frame = PCMFrame16k(samples: [Int16](repeating: 1, count: PCMFrame16k.samplesPerFrame))!
        for _ in 0..<QwenRealtimeProvider.framesPerMessage { p.sendAudio(frame) }
        let socket = try #require(server.opened.withLock { $0.first })
        await waitSent(socket, count: 5)
        let sent = Array(socket.messages().dropFirst())
        #expect(sent.map { $0["type"] } == ["conversation.item.create", "conversation.item.create", "response.create",
                                            "input_audio_buffer.append"])
        #expect(sent[1]["item"] == ["type": "message", "role": "user", "content": [["type": "input_text", "text": "导航去珠海站"]]])
        let audio = try #require(sent[3]["audio"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        #expect(audio.count == QwenRealtimeProvider.framesPerMessage * PCMFrame16k.byteCount)
        await p.close()
    }
}

@Suite("T-016r F-05 §15 Qwen voice endpoint")
struct QwenEndpointTests {
    @Test("T-016r F-05 §15 vendor facts: Qwen connects to the fixed wss://dashscope.aliyuncs.com endpoint, never a saved workspace host")
    func fixedEndpoint() {
        #expect(QwenRealtimeCodec.host == "dashscope.aliyuncs.com")
        #expect(QwenRealtimeCodec.url(model: "qwen-audio-3.1-realtime-plus")?.absoluteString
            == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.1-realtime-plus")
    }
}
