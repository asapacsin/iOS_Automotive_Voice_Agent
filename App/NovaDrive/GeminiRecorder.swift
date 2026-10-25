import Foundation
import NovaPorts
import NovaServices

/// T-003 on the phone: records Gemini Live server messages for the six contract fixtures
/// (api-contracts.md, Gemini) and writes them as sanitised `.jsonl` into Documents/fixtures.
/// Every driver turn is scripted text, so the fixtures hold no real person's voice or words.
final class GeminiRecorder: @unchecked Sendable {
    static let endpoint = URL(string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
    static let model = "models/gemini-3.8-live"

    struct Failure: Error, CustomStringConvertible { let description: String }

    private let key: String
    private let log: @Sendable (String) -> Void
    private let dir: URL

    init(log: @escaping @Sendable (String) -> Void) throws {
        guard let key = try KeychainCredentialStore().value(for: .geminiAPIKey), !key.isEmpty else {
            throw Failure(description: "没有 Gemini key，请先在设置里保存")
        }
        self.key = key
        self.log = log
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Runs one scenario by name; `goaway` waits up to 16 minutes for the server's goAway.
    func record(_ scenario: String) async throws {
        let file = Fixture(url: dir.appendingPathComponent("\(scenario).jsonl"))
        log("▶ \(scenario)")
        switch scenario {
        case "plain":
            let s = try await open(file, resumption: nil)
            try await s.send(Self.text("你好，用一句话介绍一下你自己。"))
            try await s.until(file) { Self.turnComplete($0) }
            s.close()
        case "tool":
            let s = try await open(file, resumption: nil)
            try await s.send(Self.text("帮我把空调打开。"))
            try await s.until(file) { msg in
                if let calls = (msg["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
                    let responses = calls.map { call -> [String: Any] in
                        ["id": call["id"] ?? "", "name": call["name"] ?? "",
                         "response": ["status": "ok", "power_on": true, "temperature_c": 24]]
                    }
                    Task { try? await s.send(["toolResponse": ["functionResponses": responses]]) }
                }
                return Self.turnComplete(msg) && file.sawToolCall
            }
            s.close()
        case "interrupted":
            let s = try await open(file, resumption: nil)
            try await s.send(Self.text("给我讲一个很长的关于星空的故事，至少讲两分钟。"))
            var interrupting = false
            try await s.until(file) { msg in
                if !interrupting, Self.hasModelAudio(msg) {
                    interrupting = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        try? await s.send(Self.text("停一下，换个话题：今天天气怎么样？"))
                    }
                }
                return interrupting && file.sawInterrupted && Self.turnComplete(msg)
            }
            s.close()
        case "resumption":
            let first = try await open(file, resumption: [:])
            try await first.send(Self.text("记住这个数字：七。"))
            try await first.until(file) { Self.turnComplete($0) && file.lastHandle != nil }
            first.close()
            guard let handle = file.lastHandle else { throw Failure(description: "no resumption handle") }
            file.note("reconnect with handle")
            let second = try await open(file, resumption: ["handle": handle])
            try await second.send(Self.text("我刚才让你记住的数字是多少？"))
            try await second.until(file) { Self.turnComplete($0) }
            second.close()
        case "close1007":
            let s = try await open(file, resumption: ["handle": "invalid-resumption-handle"], expectSetup: false)
            try await s.until(file) { _ in false }
        case "goaway":
            let s = try await open(file, resumption: [:])
            try await s.until(file, timeout: .seconds(16 * 60)) { $0["goAway"] != nil }
            s.close()
        default:
            throw Failure(description: "unknown scenario \(scenario)")
        }
        try file.save()
        log("✓ \(scenario): \(file.count) 条")
    }

    private func open(_ file: Fixture, resumption: [String: Any]?, expectSetup: Bool = true) async throws -> Socket {
        var request = URLRequest(url: Self.endpoint)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let socket = Socket(task: URLSession.shared.webSocketTask(with: request), file: file)
        socket.task.resume()
        var setup: [String: Any] = [
            "model": Self.model,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["languageCode": "zh-CN",
                                 "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Leda"]]],
            ],
            "systemInstruction": ["parts": [["text": "你是车载语音助手 Nova，回答简短。需要操作车辆时先调用工具。"]]],
            "tools": [["functionDeclarations": [[
                "name": "control_climate",
                "description": "打开或关闭空调，或设置温度",
                "parametersJsonSchema": [
                    "type": "object",
                    "properties": ["action": ["type": "string", "enum": ["on", "off", "set_temperature"]],
                                   "temperature_c": ["type": "number"]],
                    "required": ["action"],
                ],
            ]]]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
        ]
        if let resumption { setup["sessionResumption"] = resumption }
        try await socket.send(["setup": setup])
        if expectSetup {
            try await socket.until(file, timeout: .seconds(10)) { $0["setupComplete"] != nil }
        }
        return socket
    }

    static func text(_ s: String) -> [String: Any] {
        ["clientContent": ["turns": [["role": "user", "parts": [["text": s]]]], "turnComplete": true]]
    }

    static func turnComplete(_ msg: [String: Any]) -> Bool {
        (msg["serverContent"] as? [String: Any])?["turnComplete"] as? Bool == true
    }

    static func hasModelAudio(_ msg: [String: Any]) -> Bool {
        (((msg["serverContent"] as? [String: Any])?["modelTurn"] as? [String: Any])?["parts"] as? [Any])?.isEmpty == false
    }
}

/// One fixture file: server messages in arrival order, audio payloads cut short.
final class Fixture: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var lines: [String] = []
    private let start = Date()
    private(set) var lastHandle: String?
    private(set) var sawToolCall = false
    private(set) var sawInterrupted = false

    init(url: URL) { self.url = url }

    var count: Int { lock.withLock { lines.count } }

    func add(_ msg: [String: Any]) {
        if let update = msg["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true, let handle = update["newHandle"] as? String {
            lock.withLock { lastHandle = handle }
        }
        if msg["toolCall"] != nil { lock.withLock { sawToolCall = true } }
        if (msg["serverContent"] as? [String: Any])?["interrupted"] as? Bool == true { lock.withLock { sawInterrupted = true } }
        write(["dir": "server", "message": Self.sanitise(msg)])
    }

    func closed(code: Int, reason: String) { write(["dir": "close", "code": code, "reason": reason]) }

    func note(_ text: String) { write(["dir": "note", "text": text]) }

    func save() throws {
        let body = lock.withLock { lines.joined(separator: "\n") + "\n" }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(_ entry: [String: Any]) {
        var entry = entry
        entry["t_ms"] = Int(Date().timeIntervalSince(start) * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.withLock { lines.append(line) }
    }

    /// Keeps the first 64 base64 characters of each audio payload (still valid base64) and its original length.
    static func sanitise(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            if let data = dict["data"] as? String, dict["mimeType"] != nil {
                dict["data"] = String(data.prefix(64))
                dict["originalBase64Length"] = data.count
                return dict
            }
            for (k, v) in dict { dict[k] = sanitise(v) }
            return dict
        }
        if let array = value as? [Any] { return array.map(sanitise) }
        return value
    }
}

final class Socket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let file: Fixture

    init(task: URLSessionWebSocketTask, file: Fixture) { self.task = task; self.file = file }

    func send(_ json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Reads and records messages until `done` holds; a close is recorded and ends the wait.
    func until(_ file: Fixture, timeout: Duration = .seconds(120), _ done: @escaping ([String: Any]) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                file.closed(code: task.closeCode.rawValue,
                            reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "\(error.localizedDescription)")
                return
            }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let msg = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            file.add(msg)
            if done(msg) { return }
        }
        throw GeminiRecorder.Failure(description: "timeout")
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
