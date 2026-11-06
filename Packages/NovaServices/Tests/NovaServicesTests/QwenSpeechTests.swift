import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
@testable import NovaServices
import Testing

/// Hands back a scripted status and body chunks per request; records every request.
final class StubStream: StreamingHTTPTransport, @unchecked Sendable {
    var responses: [(Int, [Data])] = []
    var hang = false
    private(set) var requests: [URLRequest] = []

    func stream(_ request: URLRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, any Error>) {
        requests.append(request)
        if hang { try await Task.sleep(for: .seconds(60)) }
        let (status, chunks) = responses.isEmpty ? (200, []) : responses.removeFirst()
        return (status, AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        })
    }
}

private func event(_ json: String) -> String { "data:\(json)\n\n" }
private func synthesis(_ bytes: [UInt8]) -> String {
    event(#"{"output":{"type":"sentence-synthesis","audio":{"data":"\#(Data(bytes).base64EncodedString())"}}}"#)
}

@Suite("T-020a F-07 §14 Qwen-Audio TTS client")
struct QwenSpeechTests {
    let host = "ws-x.ap-southeast-1.maas.aliyuncs.com"
    var config: QwenSpeechConfig { QwenSpeechConfig(key: "sk-test", host: host, voice: "longanhuan_v3.1") }

    @Test("T-020a row 2: the request has the host, three headers and exactly the item 3 body, no instruction")
    func request() throws {
        let client = QwenSpeechClient(config: config, transport: StubStream())
        let r = client.request("现在是下午五点。")
        #expect(r.url?.absoluteString == "https://\(host)/api/v1/services/audio/tts/SpeechSynthesizer")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "X-DashScope-SSE") == "enable")
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(body == #"{"model":"qwen-audio-3.1-tts-flash","input":{"text":"现在是下午五点。","voice":"longanhuan_v3.1","format":"pcm","sample_rate":24000}}"#)
        #expect(!body.contains("instruction"))
        #expect(!String(describing: config).contains("sk-test"))
    }

    @Test("T-020a row 2: style gentle still sends no instruction")
    func gentle() async throws {
        let t = StubStream()
        t.responses = [(200, [Data(synthesis([1, 0]).utf8)])]
        _ = try await QwenSpeechClient(config: config, transport: t).synthesize("现在是下午五点。", style: .gentle, deadline: .seconds(5))
        #expect(!String(decoding: t.requests[0].httpBody!, as: UTF8.self).contains("instruction"))
    }

    @Test("T-020a row 3: begin, three synthesis parts (one data line split across reads), end, final url → one 24 kHz buffer")
    func stream() async throws {
        let t = StubStream()
        let second = synthesis([3, 0, 4, 0])
        let cut = second.index(second.startIndex, offsetBy: 30)
        t.responses = [(200, [
            Data(event(#"{"output":{"type":"sentence-begin"}}"#).utf8),
            Data(synthesis([1, 0, 2, 0]).utf8),
            Data(second[..<cut].utf8), Data(second[cut...].utf8),
            Data((synthesis([5, 0]) + event(#"{"output":{"type":"sentence-end"}}"#)).utf8),
            Data(event(#"{"output":{"finish_reason":"stop","audio":{"url":"https://example.invalid/a.wav"}}}"#).utf8),
        ])]
        let pcm = try await QwenSpeechClient(config: config, transport: t).synthesize("好", style: .default, deadline: .seconds(5))
        #expect(pcm.sampleRate == 24_000 && pcm.samples == [1, 2, 3, 4, 5])
        #expect(t.requests.count == 1)
    }

    @Test("T-020a row 3: the parser joins multi-line data and handles CRLF")
    func parser() {
        var p = QwenSSEParser()
        #expect(p.feed(Data("id:1\r\ndata:{\"a\":\r\n".utf8)).isEmpty)
        #expect(p.feed(Data("data:1}\r\n\r\n".utf8)) == [QwenSSEEvent(data: "{\"a\":\n1}")])
        #expect(p.feed(Data("data: x".utf8)).isEmpty && p.finish() == [QwenSSEEvent(data: "x")])
    }

    func failure(_ status: Int, _ chunks: [String]) async -> String? {
        let t = StubStream()
        t.responses = [(status, chunks.map { Data($0.utf8) })]
        do {
            _ = try await QwenSpeechClient(config: config, transport: t).synthesize("好", style: .default, deadline: .seconds(5))
            return nil
        } catch let e as SpeechSynthesisError { return e.code } catch { return "other" }
    }

    @Test("T-020a row 4: statuses, voice errors, empty audio and an error event map to codes")
    func codes() async {
        #expect(await failure(401, [#"{"code":"InvalidApiKey"}"#]) == "QWEN_TTS_AUTH")
        #expect(await failure(429, []) == "QWEN_TTS_RATE")
        #expect(await failure(500, []) == "QWEN_TTS_HTTP_500")
        #expect(await failure(400, [#"{"code":"InvalidParameter","message":"voice"}"#]) == "QWEN_TTS_VOICE")
        #expect(await failure(400, [#"{"code":"InternalError","message":"[cosyvoice:]Engine error [411]"}"#]) == "QWEN_TTS_VOICE")
        #expect(await failure(200, [event(#"{"output":{"type":"sentence-end"}}"#)]) == "QWEN_TTS_EMPTY")
        #expect(await failure(200, [event(#"{"code":"InternalError","message":"x"}"#)]) == "QWEN_TTS_BAD_STREAM")
        #expect(await failure(200, ["data:not json\n\n"]) == "QWEN_TTS_BAD_STREAM")
    }

    @Test("T-020a row 4: a stalled request fails with QWEN_TTS_TIMEOUT at the clause deadline")
    func timeout() async {
        let t = StubStream()
        t.hang = true
        let clock = ManualClock()
        let client = QwenSpeechClient(config: config, transport: t, clock: clock)
        let task = Task { try await client.synthesize("好", style: .default, deadline: .milliseconds(4400)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .milliseconds(4400))
        await #expect(throws: SpeechSynthesisError("QWEN_TTS_TIMEOUT")) { try await task.value }
    }

    @Test("T-020a row 5: a clause of 2.2 × the limit is three requests within the limit, cut at punctuation, joined in order")
    func cutting() async throws {
        let limit = 10
        let text = "一二三四五六七，八九十" + "一二三四五，六七八九十" + "甲乙"   // 22 = 2.2 × 10
        let pieces = QwenTextCutter.pieces(text, limit: limit)
        #expect(pieces == ["一二三四五六七，", "八九十一二三四五，", "六七八九十甲乙"])
        #expect(pieces.allSatisfy { $0.count <= limit } && pieces.joined() == text)
        #expect(QwenTextCutter.pieces("一二三四五六七八九十一二", limit: 10) == ["一二三四五六七八九十", "一二"])

        let t = StubStream()
        t.responses = [(200, [Data(synthesis([1, 0]).utf8)]), (200, [Data(synthesis([2, 0]).utf8)]),
                       (200, [Data(synthesis([3, 0]).utf8)])]
        let client = QwenSpeechClient(config: QwenSpeechConfig(key: "k", host: host, voice: "longanhuan_v3.1", pieceLimit: limit),
                                      transport: t)
        let pcm = try await client.synthesize(text, style: .default, deadline: .seconds(5))
        #expect(pcm.samples == [1, 2, 3] && t.requests.count == 3)
        let sent = t.requests.map { r -> String in
            let o = try! JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
            return (o["input"] as! [String: Any])["text"] as! String
        }
        #expect(sent == pieces)
        #expect(QwenSpeechConfig.defaultPieceLimit == 600)
    }

    @Test("T-020a item 3: warm-up sends 嗯 at most every 15 s")
    func warmUp() async {
        let t = StubStream()
        let clock = ManualClock()
        let client = QwenSpeechClient(config: config, transport: t, clock: clock)
        await client.warmUp()
        await client.warmUp()
        #expect(t.requests.count == 1)
        clock.advance(by: .seconds(15))
        await client.warmUp()
        #expect(t.requests.count == 2)
    }
}
