import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// F-07 §14 item 3 (T-020a): the Qwen-Audio TTS configuration. The key never appears in `description`.
public struct QwenSpeechConfig: Sendable, Hashable, CustomStringConvertible {
    public static let model = "qwen-audio-3.1-tts-flash"
    /// Item 3 "Long clauses": item 1 (b) found no limit yet, so 600.
    public static let defaultPieceLimit = 600

    public let key: String
    public let host: String
    public let voice: String
    public let pieceLimit: Int

    public init(key: String, host: String, voice: String, pieceLimit: Int = QwenSpeechConfig.defaultPieceLimit) {
        self.key = key
        self.host = host
        self.voice = voice
        self.pieceLimit = pieceLimit
    }

    public var description: String { "QwenSpeechConfig(host=\(host), voice=\(voice))" }
}

/// A streamed HTTP exchange, read in the calling task: `onChunk` gets the status and the body bytes as they
/// arrive (at least once, possibly with empty data). Returns the status.
public protocol StreamingHTTPTransport: Sendable {
    func stream(_ request: URLRequest, onChunk: (_ status: Int, _ chunk: Data) throws -> Void) async throws -> Int
}

/// Item 3 "One connection": one `URLSession` per session, kept open so later requests reuse the connection.
public final class URLSessionStreamingTransport: StreamingHTTPTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func stream(_ request: URLRequest, onChunk: (_ status: Int, _ chunk: Data) throws -> Void) async throws -> Int {
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try onChunk(status, data)
        return status
        #else
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var chunk = Data()
        var last: UInt8 = 0
        for try await byte in bytes {
            chunk.append(byte)
            // A blank line ends an event: hand the bytes on so first audio is not held back.
            if byte == 0x0A, last == 0x0A || last == 0x0D || chunk.count > 4096 {
                try onChunk(status, chunk)
                chunk = Data()
            }
            if byte != 0x0D { last = byte }
        }
        try Task.checkCancellation()
        try onChunk(status, chunk)
        return status
        #endif
    }
}

/// F-07 §14 item 3: one clause in the chosen 龙安 voice from `qwen-audio-3.1-tts-flash`, as 24 kHz mono PCM16LE.
/// No `instruction` is sent (item 4; F-07 §17 item 5: no style reaches synthesis). Codes only, never text (I-8). No fallback voice.
public final class QwenSpeechClient: FirstAudioTimedSynthesizer {
    static let warmText = "嗯"
    static let warmUpInterval = NovaDuration.seconds(15)

    private let config: QwenSpeechConfig
    private let transport: any StreamingHTTPTransport
    private let clock: any NovaClock
    private let lastWarm = Mutex<NovaInstant?>(nil)

    public init(config: QwenSpeechConfig, transport: any StreamingHTTPTransport = URLSessionStreamingTransport(),
                clock: any NovaClock = SystemClock()) {
        self.config = config
        self.transport = transport
        self.clock = clock
    }

    public func synthesize(_ text: String, deadline: NovaDuration) async throws -> PCMBuffer {
        try await synthesizeTimed(text, deadline: deadline).pcm
    }

    public func synthesizeTimed(_ text: String, deadline: NovaDuration) async throws
        -> (pcm: PCMBuffer, firstMs: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: []), 0)
        }
        let start = clock.now
        let pieces = QwenTextCutter.pieces(text, limit: config.pieceLimit)
        // Item 3 "Deadline": the §9 clause deadline covers the whole request, all pieces included.
        let (bytes, first) = try await withDeadline(deadline) { [self] in
            var all = Data()
            var first: NovaInstant?
            for piece in pieces {
                let (data, f) = try await self.fetch(piece)
                if first == nil { first = f }
                all.append(data)
            }
            return (all, first)
        }
        guard !bytes.isEmpty else { throw SpeechSynthesisError("QWEN_TTS_EMPTY") }
        let firstMs = Int(((first ?? clock.now) - start).milliseconds)
        return (PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: Self.samples(bytes)), firstMs)
    }

    public func warmUp() async {
        let now = clock.now
        let due = lastWarm.withLock { last -> Bool in
            if let last, now - last < Self.warmUpInterval { return false }
            last = now
            return true
        }
        guard due else { return }
        _ = try? await fetch(Self.warmText)
    }

    /// One request: the piece's audio bytes in order, and when the first ones arrived.
    func fetch(_ text: String) async throws -> (Data, NovaInstant?) {
        let request = request(text)
        let clock = clock
        var parser = QwenSSEParser()
        var raw = Data()
        var audio = Data()
        var first: NovaInstant?
        func take(_ events: [QwenSSEEvent]) throws {
            for event in events {
                switch QwenTTSEventDecoder.decode(event) {
                case .audio(let bytes):
                    if first == nil, !bytes.isEmpty { first = clock.now }
                    audio.append(bytes)
                case .other: break
                case .bad: throw SpeechSynthesisError("QWEN_TTS_BAD_STREAM")
                }
            }
        }
        let status: Int
        do {
            status = try await transport.stream(request) { status, chunk in
                if (200..<300).contains(status) { try take(parser.feed(chunk)) } else { raw.append(chunk) }
            }
        } catch let error as SpeechSynthesisError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(status) else { throw SpeechSynthesisError(Self.code(status: status, body: raw)) }
        try take(parser.finish())
        return (audio, first)
    }

    func request(_ text: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://\(config.host)/api/v1/services/audio/tts/SpeechSynthesizer")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        r.httpBody = Self.body(text, voice: config.voice)
        return r
    }

    /// Exactly the item 3 body; key order fixed so the bytes are stable.
    static func body(_ text: String, voice: String) -> Data {
        func json(_ s: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return Data(("{\"model\":\(json(QwenSpeechConfig.model)),\"input\":{\"text\":\(json(text)),"
            + "\"voice\":\(json(voice)),\"format\":\"pcm\",\"sample_rate\":24000}}").utf8)
    }

    static func code(status: Int, body: Data) -> String {
        // The error may come as plain JSON or framed as SSE (`event:error` / `data:{…}`).
        var parser = QwenSSEParser()
        let framed = (parser.feed(body) + parser.finish()).first.map { Data($0.data.utf8) }
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            ?? framed.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = object?["code"] as? String ?? ""
        let message = object?["message"] as? String ?? String(decoding: body, as: UTF8.self)
        if code == "InvalidParameter" { return "QWEN_TTS_VOICE" }
        switch status {
        case 401, 403: return "QWEN_TTS_AUTH"
        case 429: return "QWEN_TTS_RATE"
        case 400 where message.contains("Engine error"): return "QWEN_TTS_VOICE"
        default: return "QWEN_TTS_HTTP_\(status)"
        }
    }

    static func transportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let e = error as? URLError {
            if e.code == .cancelled { return CancellationError() }
            if e.code == .timedOut { return SpeechSynthesisError("QWEN_TTS_TIMEOUT") }
        }
        return SpeechSynthesisError("QWEN_TTS_NETWORK")
    }

    /// Whole little-endian 16-bit samples; an odd trailing byte is dropped.
    static func samples(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }

    private func withDeadline<T: Sendable>(_ deadline: NovaDuration,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let clock = clock
        let end = clock.now + deadline
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await clock.sleep(until: end)
                throw SpeechSynthesisError("QWEN_TTS_TIMEOUT")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
