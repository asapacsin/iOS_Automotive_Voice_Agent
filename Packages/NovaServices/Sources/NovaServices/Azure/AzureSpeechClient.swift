import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// Azure Speech configuration (`AzureSpeechConfig`). The key never appears in `description`.
public struct AzureSpeechConfig: Sendable, Hashable, CustomStringConvertible {
    public let key: String
    public let region: String
    public let voice: String

    public init(key: String, region: String, voice: String) {
        self.key = key
        self.region = region
        self.voice = voice
    }

    /// Azure China regions (`chinaeast2`, …) live under azure.cn.
    public var host: String {
        let r = region.trimmingCharacters(in: .whitespaces).lowercased()
        return r.hasPrefix("china") ? "\(r).tts.speech.azure.cn" : "\(r).tts.speech.microsoft.com"
    }

    public var description: String { "AzureSpeechConfig(region=\(region), voice=\(voice))" }
}

/// One HTTP exchange. Production: `URLSessionTransport`; tests: a recording stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(connectTimeout: NovaDuration = AzureSpeechTuning().connectTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Double(connectTimeout.milliseconds) / 1000
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// `A/voice/AzureSpeechVoice.kt`: one clause of judged text in the configured voice, as raw 24 kHz
/// mono PCM16LE. Logs codes and timings only, never text (I-8). No fallback voice (ADR-016 §6).
public final class AzureSpeechClient: SpeechSynthesizer {
    static let warmText = "嗯"

    private let config: AzureSpeechConfig
    private let transport: any HTTPTransport
    private let clock: any NovaClock
    private let tuning: AzureSpeechTuning
    private let lastWarm = Mutex<NovaInstant?>(nil)

    public init(config: AzureSpeechConfig, transport: any HTTPTransport = URLSessionTransport(),
                clock: any NovaClock = SystemClock(), tuning: AzureSpeechTuning = AzureSpeechTuning()) {
        self.config = config
        self.transport = transport
        self.clock = clock
        self.tuning = tuning
    }

    public func synthesize(_ text: String, style: SpeakingStyle, deadline: NovaDuration) async throws -> PCMBuffer {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: [])
        }
        var built = self.request(text, style)
        built.timeoutInterval = Double(deadline.milliseconds) / 1000
        let request = built
        let response: (status: Int, body: Data)
        do {
            response = try await withDeadline(deadline) { try await self.transport.send(request) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechSynthesisError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw SpeechSynthesisError("AZURE_TTS_TIMEOUT")
        } catch {
            throw SpeechSynthesisError("AZURE_TTS_NETWORK")
        }
        guard (200..<300).contains(response.status) else { throw SpeechSynthesisError(Self.code(for: response.status)) }
        guard !response.body.isEmpty else { throw SpeechSynthesisError("AZURE_TTS_EMPTY") }
        return PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: Self.samples(response.body))
    }

    public func warmUp() async {
        let now = clock.now
        let due = lastWarm.withLock { last -> Bool in
            if let last, now - last < tuning.warmUpInterval { return false }
            last = now
            return true
        }
        guard due else { return }
        _ = try? await transport.send(request(Self.warmText, .default))
    }

    func request(_ text: String, _ style: SpeakingStyle) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://\(config.host)/cognitiveservices/v1")!)
        r.httpMethod = "POST"
        r.setValue(config.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        r.setValue("raw-24khz-16bit-mono-pcm", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        r.setValue("NovaDrive", forHTTPHeaderField: "User-Agent")
        r.setValue("application/ssml+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(Self.ssml(text, voice: config.voice, style: style).utf8)
        return r
    }

    static func code(for status: Int) -> String {
        switch status {
        case 401, 403: "AZURE_TTS_AUTH"
        case 429: "AZURE_TTS_THROTTLED"
        case 400: "AZURE_TTS_BAD_REQUEST"
        default: "AZURE_TTS_HTTP_\(status)"
        }
    }

    /// Whole little-endian 16-bit samples; an odd trailing byte is dropped.
    static func samples(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }

    /// ADR-016 style table: Azure `express-as` style and styledegree, or nil for no wrapper.
    static func azureStyle(_ style: SpeakingStyle) -> (String, String)? {
        switch style {
        case .default: nil
        case .sweet: ("affectionate", "1.2")
        case .tsundere: ("disgruntled", "0.6")
        case .gentle: ("gentle", "1.0")
        case .lively: ("cheerful", "1.2")
        }
    }

    static func ssml(_ text: String, voice: String, style: SpeakingStyle) -> String {
        let escaped = xmlEscape(text)
        let body = azureStyle(style).map { "<mstts:express-as style=\"\($0.0)\" styledegree=\"\($0.1)\">\(escaped)</mstts:express-as>" }
            ?? escaped
        return "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" "
            + "xmlns:mstts=\"https://www.w3.org/2001/mstts\" xml:lang=\"zh-CN\">"
            + "<voice name=\"\(xmlEscape(voice))\">\(body)</voice></speak>"
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Whole-clause deadline: the request is abandoned at `deadline`, whatever the transport does.
    private func withDeadline<T: Sendable>(_ deadline: NovaDuration,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let clock = clock
        let end = clock.now + deadline
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await clock.sleep(until: end)
                throw SpeechSynthesisError("AZURE_TTS_TIMEOUT")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
