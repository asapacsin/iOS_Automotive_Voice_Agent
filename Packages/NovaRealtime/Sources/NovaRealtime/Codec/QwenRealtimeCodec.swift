import Foundation
import NovaKit
import NovaPorts

/// F-05 §15 items 3-4 (T-016q): the Qwen-Audio realtime WebSocket messages (Alibaba Model Studio, client and server
/// events, read 2026-11-26). Client messages are built here; server events become `RealtimeEvent`s in
/// `QwenEventMapper`. Pure.
public enum QwenRealtimeCodec {
    /// `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=<model>`; the host is the 百炼
    /// workspace API Host saved in 设置.
    public static func url(host: String, model: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/api-ws/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url
    }

    /// The 3.1 models' default voice (first `session.update` only).
    public static let defaultVoice = "longanqian_v3.1"
    /// Item 3: the server keeps at most 50 turns; the app asks for all of them.
    public static let maxHistoryTurns = 50
    /// Item 3: the recommended turn detection.
    public static let turnDetection = "smart_turn_v2"

    /// Item 3 `connect`: the first `session.update` with the app's instruction and every declared tool.
    public static func sessionUpdate(_ config: SessionConfig) -> JSONValue {
        let tools: [JSONValue] = config.tools.map { tool in
            ["type": "function", "function": [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parametersJSONSchema,
            ]]
        }
        return ["type": "session.update", "session": [
            "instructions": .string(config.systemInstruction),
            "voice": .string(defaultVoice),
            "modalities": ["text", "audio"],
            "turn_detection": ["type": .string(turnDetection)],
            "max_history_turns": .int(Int64(maxHistoryTurns)),
            "tools": .array(tools),
        ]]
    }

    /// Item 3 `sendAudio`: 16 kHz mono 16-bit PCM, little-endian, base64.
    public static func audio(_ frames: [PCMFrame16k]) -> JSONValue {
        var bytes = Data(capacity: frames.count * PCMFrame16k.byteCount)
        for frame in frames {
            for sample in frame.samples { withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) } }
        }
        return ["type": "input_audio_buffer.append", "audio": .string(bytes.base64EncodedString())]
    }

    /// Item 3 `sendToolResponses`: one `function_call_output` per result, then one `response.create`.
    public static func toolResponses(_ responses: [ToolResponse]) -> [JSONValue] {
        guard !responses.isEmpty else { return [] }
        let outputs: [JSONValue] = responses.map { r in
            let output = (try? GeminiCodec.encode(GeminiCodec.payload(r.result))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ["type": "conversation.item.create", "item": [
                "type": "function_call_output", "call_id": .string(r.id.rawValue), "output": .string(output),
            ]]
        }
        return outputs + [responseCreate]
    }

    /// Item 3 `sendText`: each turn as a user `message` with `input_text`; `response.create` when `turnComplete`.
    public static func text(_ turns: [TextTurn], turnComplete: Bool) -> [JSONValue] {
        let items: [JSONValue] = turns.map { turn in
            ["type": "conversation.item.create", "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": .string(turn.text)]],
            ]]
        }
        return items + (turnComplete ? [responseCreate] : [])
    }

    public static var responseCreate: JSONValue { ["type": "response.create"] }
    /// The stop phrase cuts her reply (F-08 §15 item 1's empty activity on Gemini). PROPOSED: the realtime API's
    /// `response.cancel`.
    public static var responseCancel: JSONValue { ["type": "response.cancel"] }

    /// Server frames are JSON objects with a `type`; anything else is nil.
    public static func decode(_ frame: Data) -> (type: String, body: JSONValue)? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame), let type = value["type"]?.stringValue else {
            return nil
        }
        return (type, value)
    }

    /// Item 4: `error` codes and socket statuses as `RealtimeErrorCode` (401/403 → auth, quota or `Arrearage` → quota,
    /// 429 → rateLimited, else connectionClosed).
    public static func classify(code: String?, status: Int?) -> RealtimeErrorCode {
        let text = (code ?? "").lowercased()
        if status == 401 || status == 403 || text.contains("401") || text.contains("403") || text.contains("invalidapikey")
            || text.contains("accessdenied") || text.contains("unauthorized") {
            return .auth
        }
        if text.contains("quota") || text.contains("arrearage") { return .quota }
        if status == 429 || text.contains("429") || text.contains("throttl") || text.contains("ratelimit") { return .rateLimited }
        return .connectionClosed
    }
}

/// F-05 §15 item 6 (T-016q): tokens of one `response.done` (numbers only, I-8).
public struct QwenUsage: Sendable, Hashable {
    public let inAudio: Int
    public let inText: Int
    public let outAudio: Int
    public let outText: Int

    public init(inAudio: Int, inText: Int, outAudio: Int, outText: Int) {
        self.inAudio = inAudio
        self.inText = inText
        self.outAudio = outAudio
        self.outText = outText
    }

    public var logLine: String { "qwen usage in=\(inAudio),\(inText) out=\(outAudio),\(outText)" }

    static func parse(_ usage: JSONValue?) -> QwenUsage? {
        guard let usage, case .object = usage else { return nil }
        func n(_ details: String, _ key: String) -> Int { Int(usage[details]?[key]?.intValue ?? 0) }
        return QwenUsage(inAudio: n("input_token_details", "audio_tokens"), inText: n("input_token_details", "text_tokens"),
                         outAudio: n("output_token_details", "audio_tokens"), outText: n("output_token_details", "text_tokens"))
    }
}

/// Item 4: server events → `RealtimeEvent`s, in order. One mapper per socket; the reader owns it.
public struct QwenEventMapper: Sendable {
    private var nextTurn = TurnID.initial
    private var openTurn: TurnID?
    private var interruptedTurn = false
    private var calls: [ToolCall] = []
    private var setupDone = false

    public init() {}

    /// The events of one server frame, and the usage when it was a `response.done` that carried one.
    public mutating func consume(type: String, body: JSONValue) -> (events: [RealtimeEvent], usage: QwenUsage?) {
        switch type {
        case "session.updated":
            guard !setupDone else { return ([], nil) }
            setupDone = true
            return ([.setupComplete], nil)
        case "conversation.item.input_audio_transcription.delta":
            guard let text = (body["delta"] ?? body["text"])?.stringValue, !text.isEmpty else { return ([], nil) }
            return ([.userTranscript(text, isFinal: false)], nil)
        case "conversation.item.input_audio_transcription.completed":
            guard let text = body["transcript"]?.stringValue else { return ([], nil) }
            return ([.userTranscript(text, isFinal: true)], nil)
        case "response.created":
            nextTurn = nextTurn.next()
            openTurn = nextTurn
            interruptedTurn = false
            calls = []
            return ([.responseStarted(nextTurn)], nil)
        case "response.audio_transcript.delta":
            guard let turn = openTurn, let text = body["delta"]?.stringValue, !text.isEmpty else { return ([], nil) }
            return ([.replyText(turn, text)], nil)
        case "response.audio.delta":
            guard let turn = openTurn, let base64 = body["delta"]?.stringValue, let pcm = GeminiCodec.pcm24k(base64: base64) else {
                return ([], nil)
            }
            return ([.replyAudio(turn, pcm)], nil)
        case "response.function_call_arguments.done":
            guard openTurn != nil, let id = body["call_id"]?.stringValue.flatMap(CallID.init),
                  let name = body["name"]?.stringValue else { return ([], nil) }
            let raw = body["arguments"]?.stringValue ?? "{}"
            let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .object([:])
            calls.append(ToolCall(id: id, name: name, arguments: arguments))
            return ([], nil)
        case "response.audio.done":
            guard let turn = openTurn else { return ([], nil) }
            return ([.audioDone(turn)], nil)
        case "input_audio_buffer.speech_started":
            guard let turn = openTurn, !interruptedTurn else { return ([], nil) }
            interruptedTurn = true
            return ([.interrupted(turn, reason: .serverVAD)], nil)
        case "response.done":
            let response = body["response"]
            let usage = QwenUsage.parse(response?["usage"])
            guard let turn = openTurn else { return ([], usage) }
            var events: [RealtimeEvent] = []
            // All function calls of one response → one `toolCalls`.
            if !calls.isEmpty { events.append(.toolCalls(turn, calls)) }
            let status = response?["status"]?.stringValue ?? "completed"
            let reason = response?["status_details"]?["reason"]?.stringValue
            if status == "cancelled", reason == "turn_detected", !interruptedTurn {
                events.append(.interrupted(turn, reason: .serverVAD))
            }
            events.append(.responseDone(turn, outcome: status == "completed" ? .completed : .cancelled))
            openTurn = nil
            calls = []
            interruptedTurn = false
            return (events, usage)
        case "error":
            let error = body["error"]
            guard error?["type"]?.stringValue == "server_error" else { return ([], nil) }
            return ([.failed(RealtimeError(QwenRealtimeCodec.classify(code: error?["code"]?.stringValue, status: nil)))], nil)
        default:
            return ([], nil)
        }
    }
}
