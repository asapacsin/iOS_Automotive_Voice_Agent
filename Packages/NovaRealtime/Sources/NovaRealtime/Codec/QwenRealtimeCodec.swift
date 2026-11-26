import Foundation
import NovaKit
import NovaPorts

/// F-05 §15 items 3-4 (T-016q): the Qwen-Audio realtime wire format (Alibaba Model Studio WebSocket API, the client and
/// server events the spec copies). Client messages are built as `JSONValue` and encoded canonically.
public enum QwenRealtimeCodec {
    /// Vendor default voice of the 3.1 models (first `session.update` only).
    public static let defaultVoice = "longanqian_v3.1"
    /// Item 3: the most turns the server keeps (1–50).
    public static let maxHistoryTurns = 50

    // MARK: Client → server

    /// Item 3: the first `session.update`: the app's instruction, the declared tools in the OpenAI function shape,
    /// `smart_turn_v2`, 50 history turns, the default voice, text and audio out.
    public static func sessionUpdate(_ config: SessionConfig) -> JSONValue {
        var session: [String: JSONValue] = [
            "instructions": .string(config.systemInstruction),
            "voice": .string(defaultVoice),
            "turn_detection": ["type": "smart_turn_v2"],
            "max_history_turns": .int(Int64(maxHistoryTurns)),
            "modalities": ["text", "audio"],
        ]
        if !config.tools.isEmpty { session["tools"] = .array(config.tools.map(tool)) }
        return ["type": "session.update", "session": .object(session)]
    }

    /// One declared tool as `{"type":"function","function":{name, description, parameters}}`, the same schema.
    public static func tool(_ declaration: ToolDeclaration) -> JSONValue {
        ["type": "function", "function": [
            "name": .string(declaration.name),
            "description": .string(declaration.description),
            "parameters": declaration.parametersJSONSchema,
        ]]
    }

    /// 16 kHz mono PCM16, little-endian, base64.
    public static func append(_ frames: [PCMFrame16k]) -> JSONValue {
        var bytes = Data(capacity: frames.count * PCMFrame16k.byteCount)
        for frame in frames {
            for sample in frame.samples { withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) } }
        }
        return ["type": "input_audio_buffer.append", "audio": .string(bytes.base64EncodedString())]
    }

    /// Item 3: one `function_call_output` item per result; the output is the result JSON the model reads.
    public static func functionOutput(_ response: ToolResponse) -> JSONValue {
        let output = (try? encode(GeminiCodec.payload(response.result))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": .string(response.id.rawValue), "output": .string(output),
        ]]
    }

    /// Item 3: a text turn as a user `message` item with `input_text`.
    public static func message(_ turn: TextTurn) -> JSONValue {
        ["type": "conversation.item.create", "item": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": .string(turn.text)]],
        ]]
    }

    public static var responseCreate: JSONValue { ["type": "response.create"] }
    public static var responseCancel: JSONValue { ["type": "response.cancel"] }

    public static func encode(_ message: JSONValue) throws -> Data {
        try JSONValue.canonicalEncoder().encode(message)
    }

    // MARK: Server → client

    /// Token counts of one `response.done` (item 6, numbers only).
    public struct Usage: Sendable, Hashable {
        public var inAudio = 0, inText = 0, outAudio = 0, outText = 0
        public init(inAudio: Int = 0, inText: Int = 0, outAudio: Int = 0, outText: Int = 0) {
            self.inAudio = inAudio
            self.inText = inText
            self.outAudio = outAudio
            self.outText = outText
        }

        public var logLine: String { "qwen usage in=\(inAudio),\(inText) out=\(outAudio),\(outText)" }
    }

    /// One server event, as much of it as the provider reads.
    public enum ServerEvent: Sendable, Hashable {
        case sessionUpdated
        case inputTranscriptDelta(String)
        case inputTranscriptCompleted(String)
        case speechStarted
        case responseCreated
        case transcriptDelta(String)
        case audioDelta(PCMBuffer)
        case audioDone
        case functionCall(ToolCall)
        /// `status` completed or not; `turnDetected`: cancelled by the server's turn detection.
        case responseDone(completed: Bool, turnDetected: Bool, usage: Usage?)
        case error(type: String, code: String)
        case other
    }

    /// nil when the frame is not a JSON object with a `type`.
    public static func decode(_ frame: Data) -> ServerEvent? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame), case .object(let msg) = value,
              let type = msg["type"]?.stringValue else { return nil }
        switch type {
        case "session.updated": return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .inputTranscriptDelta(msg["delta"]?.stringValue ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptCompleted(msg["transcript"]?.stringValue ?? "")
        case "input_audio_buffer.speech_started": return .speechStarted
        case "response.created": return .responseCreated
        case "response.audio_transcript.delta": return .transcriptDelta(msg["delta"]?.stringValue ?? "")
        case "response.audio.delta":
            guard let pcm = msg["delta"]?.stringValue.flatMap(GeminiCodec.pcm24k(base64:)) else { return .other }
            return .audioDelta(pcm)
        case "response.audio.done": return .audioDone
        case "response.function_call_arguments.done":
            guard let id = msg["call_id"]?.stringValue.flatMap(CallID.init), let name = msg["name"]?.stringValue else {
                return .other
            }
            let raw = msg["arguments"]?.stringValue ?? "{}"
            let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .object([:])
            return .functionCall(ToolCall(id: id, name: name, arguments: arguments))
        case "response.done":
            let response = msg["response"]
            let status = response?["status"]?.stringValue ?? "completed"
            let reason = response?["status_details"]?["reason"]?.stringValue
            return .responseDone(completed: status == "completed", turnDetected: status == "cancelled" && reason == "turn_detected",
                                 usage: response?["usage"].map(usage))
        case "error":
            let error = msg["error"]
            return .error(type: error?["type"]?.stringValue ?? "", code: error?["code"]?.stringValue ?? "")
        default: return .other
        }
    }

    static func usage(_ value: JSONValue) -> Usage {
        func n(_ v: JSONValue?) -> Int { Int(v?.intValue ?? 0) }
        return Usage(inAudio: n(value["input_token_details"]?["audio_tokens"]), inText: n(value["input_token_details"]?["text_tokens"]),
                     outAudio: n(value["output_token_details"]?["audio_tokens"]), outText: n(value["output_token_details"]?["text_tokens"]))
    }

    /// Item 4: a server `error` code or close text → the session's code (401/403 auth, quota or Arrearage quota,
    /// 429 rate limited, else connection closed).
    public static func classify(_ text: String) -> RealtimeErrorCode {
        let t = text.lowercased()
        if t.contains("arrearage") || t.contains("quota") { return .quota }
        if t.contains("401") || t.contains("403") || t.contains("invalidapikey") || t.contains("unauthorized")
            || t.contains("access denied") || t.contains("accessdenied") { return .auth }
        if t.contains("429") || t.contains("throttl") || t.contains("ratelimit") || t.contains("rate limit") { return .rateLimited }
        return .connectionClosed
    }

    /// Item 4: a refused upgrade by its HTTP status.
    public static func classify(handshakeStatus status: Int) -> RealtimeErrorCode {
        switch status {
        case 401, 403: .auth
        case 429: .rateLimited
        default: .connectionClosed
        }
    }
}

/// F-05 §15 item 4 (T-016q): server events → `RealtimeEvent`s. One per socket; the reader task owns it. Never emits
/// `resumptionHandle`, `goAway` or `toolCallCancellation`.
public struct QwenRealtimeAssembler: Sendable {
    private var nextTurn = TurnID.initial
    private var openTurn: TurnID?
    private var calls: [ToolCall] = []
    private var interrupted = false
    private var setupDone = false
    /// Responses done on this socket (`qwen history turns=<n>`, item 5).
    public private(set) var turns = 0

    public init() {}

    /// The events, a record line for the usage and history of a finished response, and a terminal failure.
    public mutating func consume(_ event: QwenRealtimeCodec.ServerEvent) -> (events: [RealtimeEvent], lines: [String], failure: RealtimeErrorCode?) {
        switch event {
        case .sessionUpdated:
            guard !setupDone else { return ([], [], nil) }
            setupDone = true
            return ([.setupComplete], [], nil)
        case .inputTranscriptDelta(let text):
            return (text.isEmpty ? [] : [.userTranscript(text, isFinal: false)], [], nil)
        case .inputTranscriptCompleted(let text):
            return ([.userTranscript(text, isFinal: true)], [], nil)
        case .speechStarted:
            guard let turn = openTurn, !interrupted else { return ([], [], nil) }
            interrupted = true
            return ([.interrupted(turn, reason: .serverVAD)], [], nil)
        case .responseCreated:
            nextTurn = nextTurn.next()
            openTurn = nextTurn
            calls = []
            interrupted = false
            return ([.responseStarted(nextTurn)], [], nil)
        case .transcriptDelta(let text):
            guard let turn = openTurn, !text.isEmpty else { return ([], [], nil) }
            return ([.replyText(turn, text)], [], nil)
        case .audioDelta(let pcm):
            guard let turn = openTurn else { return ([], [], nil) }
            return ([.replyAudio(turn, pcm)], [], nil)
        case .audioDone:
            guard let turn = openTurn else { return ([], [], nil) }
            return ([.audioDone(turn)], [], nil)
        case .functionCall(let call):
            calls.append(call)
            return ([], [], nil)
        case .responseDone(let completed, let turnDetected, let usage):
            guard let turn = openTurn else { return ([], [], nil) }
            var events: [RealtimeEvent] = []
            if !calls.isEmpty { events.append(.toolCalls(turn, calls)) }
            if turnDetected, !interrupted { events.append(.interrupted(turn, reason: .serverVAD)) }
            events.append(.responseDone(turn, outcome: completed ? .completed : .cancelled))
            openTurn = nil
            calls = []
            interrupted = false
            turns += 1
            var lines: [String] = []
            if let usage { lines.append(usage.logLine) }
            lines.append("qwen history turns=\(turns)")
            return (events, lines, nil)
        case .error(let type, let code):
            guard type == "server_error" else { return ([], [], nil) }
            return ([], [], QwenRealtimeCodec.classify(code))
        case .other:
            return ([], [], nil)
        }
    }
}
