import Foundation
import NovaKit
import NovaPorts

/// Gemini Live wire format (contracts/api-contracts.md, Gemini). Client messages are built as
/// `JSONValue` and encoded canonically; server frames decode into `GeminiServerPart`s in field order.
public enum GeminiCodec {
    // MARK: Client → server

    public static func setup(_ config: SessionConfig, resume handle: String?) -> JSONValue {
        var generation: [String: JSONValue] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": [
                "languageCode": .string(config.languageCode),
                "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(config.voiceName)]],
            ],
        ]
        if let level = config.thinkingLevel { generation["thinkingConfig"] = ["thinkingLevel": .string(level)] }
        var detection: [String: JSONValue] = [
            "startOfSpeechSensitivity": .string(sensitivity(config.activityDetection.startSensitivity, start: true)),
            "endOfSpeechSensitivity": .string(sensitivity(config.activityDetection.endSensitivity, start: false)),
        ]
        if let silence = config.activityDetection.silenceDuration {
            detection["silenceDurationMs"] = .int(min(max(silence.milliseconds, 100), 3000))
        }
        if config.activityDetection.manual { detection = ["disabled": true] }
        var setup: [String: JSONValue] = [
            "model": .string(config.model.hasPrefix("models/") ? config.model : "models/\(config.model)"),
            "generationConfig": .object(generation),
            "systemInstruction": ["parts": [["text": .string(config.systemInstruction)]]],
            "realtimeInputConfig": ["automaticActivityDetection": .object(detection)],
            "sessionResumption": handle.map { ["handle": .string($0)] } ?? [:],
            // Lets the session outlive the server's context limit; resumption then extends it.
            "contextWindowCompression": ["slidingWindow": [:]],
        ]
        if !config.tools.isEmpty {
            setup["tools"] = [["functionDeclarations": .array(config.tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description),
                 "parametersJsonSchema": tool.parametersJSONSchema]
            })]]
        }
        if config.inputTranscription { setup["inputAudioTranscription"] = [:] }
        if config.outputTranscription { setup["outputAudioTranscription"] = [:] }
        return ["setup": .object(setup)]
    }

    /// 16 kHz mono PCM, little-endian, base64.
    public static func audio(_ frames: [PCMFrame16k]) -> JSONValue {
        var bytes = Data(capacity: frames.count * PCMFrame16k.byteCount)
        for frame in frames {
            for sample in frame.samples { withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) } }
        }
        return ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": .string(bytes.base64EncodedString())]]]
    }

    public static var audioStreamEnd: JSONValue { ["realtimeInput": ["audioStreamEnd": true]] }

    /// Manual activity detection: the driver started / stopped speaking.
    public static var activityStart: JSONValue { ["realtimeInput": ["activityStart": [:]]] }
    public static var activityEnd: JSONValue { ["realtimeInput": ["activityEnd": [:]]] }

    public static func text(_ turns: [TextTurn], turnComplete: Bool) -> JSONValue {
        ["clientContent": [
            "turns": .array(turns.map { ["role": .string($0.role.rawValue), "parts": [["text": .string($0.text)]]] }),
            "turnComplete": .bool(turnComplete),
        ]]
    }

    public static func toolResponses(_ responses: [ToolResponse]) -> JSONValue {
        ["toolResponse": ["functionResponses": .array(responses.map { r in
            ["id": .string(r.id.rawValue), "name": .string(r.name), "response": payload(r.result)]
        })]]
    }

    public static func encode(_ message: JSONValue) throws -> Data {
        try JSONValue.canonicalEncoder().encode(message)
    }

    static func payload(_ result: ToolResult) -> JSONValue {
        var object = result.data
        object["ok"] = .bool(result.ok)
        if let code = result.code { object["code"] = .string(code.rawValue) }
        if let advice = result.advice { object["advice"] = .string(advice) }
        return .object(object)
    }

    private static func sensitivity(_ s: ActivityDetectionConfig.Sensitivity, start: Bool) -> String {
        "\(start ? "START" : "END")_SENSITIVITY_\(s == .low ? "LOW" : "HIGH")"
    }

    // MARK: Server → client

    /// Parts of one server frame in the order the turn assembler must see them. A frame that is not
    /// a JSON object yields nil; an empty object (the server sends `{}`) yields no parts.
    public static func decode(_ frame: Data) -> [GeminiServerPart]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame), case .object(let msg) = value else {
            return nil
        }
        var parts: [GeminiServerPart] = []
        if msg["setupComplete"] != nil { parts.append(.setupComplete) }
        if let update = msg["sessionResumptionUpdate"] {
            parts.append(.resumption(handle: update["newHandle"]?.stringValue,
                                     resumable: update["resumable"]?.boolValue ?? false))
        }
        if let content = msg["serverContent"] {
            if let text = content["inputTranscription"]?["text"]?.stringValue { parts.append(.inputTranscript(text)) }
            if case .array(let modelParts)? = content["modelTurn"]?["parts"] {
                for part in modelParts {
                    if let data = part["inlineData"]?["data"]?.stringValue, let pcm = pcm24k(base64: data) {
                        parts.append(.modelAudio(pcm))
                    } else if let text = part["text"]?.stringValue, part["thought"]?.boolValue != true {
                        parts.append(.modelText(text))
                    }
                }
            }
            if let text = content["outputTranscription"]?["text"]?.stringValue { parts.append(.outputTranscript(text)) }
            if content["generationComplete"]?.boolValue == true { parts.append(.generationComplete) }
            if content["interrupted"]?.boolValue == true { parts.append(.interrupted) }
            if content["turnComplete"]?.boolValue == true { parts.append(.turnComplete) }
        }
        if case .array(let calls)? = msg["toolCall"]?["functionCalls"] {
            parts.append(.toolCalls(calls.compactMap { call in
                guard let id = call["id"]?.stringValue.flatMap(CallID.init), let name = call["name"]?.stringValue else {
                    return nil
                }
                return ToolCall(id: id, name: name, arguments: call["args"] ?? [:])
            }))
        }
        if case .array(let ids)? = msg["toolCallCancellation"]?["ids"] {
            parts.append(.toolCallCancellation(ids.compactMap { $0.stringValue.flatMap(CallID.init) }))
        }
        if let goAway = msg["goAway"] {
            parts.append(.goAway(timeLeft: goAway["timeLeft"]?.stringValue.flatMap(duration)))
        }
        return parts
    }

    /// Protobuf JSON duration: "12s", "0.5s".
    static func duration(_ text: String) -> NovaDuration? {
        guard text.hasSuffix("s"), let seconds = Double(text.dropLast()) else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    static func pcm24k(base64: String) -> PCMBuffer? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let samples = stride(from: 0, to: data.count - 1, by: 2).map { i in
            Int16(bitPattern: UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8)
        }
        return PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: samples)
    }
}

public enum GeminiServerPart: Sendable, Hashable {
    case setupComplete
    case resumption(handle: String?, resumable: Bool)
    case inputTranscript(String)
    case outputTranscript(String)
    case modelAudio(PCMBuffer)
    case modelText(String)
    case generationComplete
    case interrupted
    case turnComplete
    case toolCalls([ToolCall])
    case toolCallCancellation([CallID])
    case goAway(timeLeft: NovaDuration?)
}
