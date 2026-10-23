import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

final class StubTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var body = Data([1, 0, 2, 0, 9])
    var hang = false
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        if hang { try await Task.sleep(for: .seconds(60)) }
        return (status, body)
    }
}

@Suite("T-020 F-07 Azure REST client")
struct AzureSpeechTests {
    let config = AzureSpeechConfig(key: "k", region: "EastAsia", voice: "zh-CN-XiaoxiaoNeural")

    @Test("F-07 request: host, headers, SSML with the style table, odd byte dropped")
    func request() async throws {
        let t = StubTransport()
        let client = AzureSpeechClient(config: config, transport: t)
        let pcm = try await client.synthesize("你好<&>", style: .sweet, deadline: .seconds(5))
        #expect(pcm.samples == [1, 2] && pcm.sampleRate == 24_000)
        let r = t.requests[0]
        #expect(r.url?.absoluteString == "https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1")
        #expect(r.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "raw-24khz-16bit-mono-pcm")
        #expect(r.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "k")
        let ssml = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(ssml.contains(#"<mstts:express-as style="affectionate" styledegree="1.2">你好&lt;&amp;&gt;</mstts:express-as>"#))
        #expect(AzureSpeechConfig(key: "k", region: "chinaeast2", voice: "v").host == "chinaeast2.tts.speech.azure.cn")
        #expect(!config.description.contains("k,") && !String(describing: config).contains("key"))
    }

    @Test("F-07 Azure 401 is AZURE_TTS_AUTH; other statuses map to codes")
    func status() async {
        let t = StubTransport()
        t.status = 401
        let client = AzureSpeechClient(config: config, transport: t)
        await #expect(throws: SpeechSynthesisError("AZURE_TTS_AUTH")) {
            try await client.synthesize("好", style: .default, deadline: .seconds(5))
        }
        #expect(AzureSpeechClient.code(for: 429) == "AZURE_TTS_THROTTLED")
        #expect(AzureSpeechClient.code(for: 500) == "AZURE_TTS_HTTP_500")
    }

    @Test("F-07 a stalled request fails with AZURE_TTS_TIMEOUT at the clause deadline")
    func timeout() async {
        let t = StubTransport()
        t.hang = true
        let clock = ManualClock()
        let client = AzureSpeechClient(config: config, transport: t, clock: clock)
        let task = Task { try await client.synthesize("好", style: .default, deadline: .milliseconds(4400)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .milliseconds(4400))
        await #expect(throws: SpeechSynthesisError("AZURE_TTS_TIMEOUT")) { try await task.value }
    }

    @Test("F-07 warm-up at most once per 15 s")
    func warm() async {
        let t = StubTransport()
        let clock = ManualClock()
        let client = AzureSpeechClient(config: config, transport: t, clock: clock)
        await client.warmUp(); await client.warmUp()
        clock.advance(by: .seconds(15))
        await client.warmUp()
        #expect(t.requests.count == 2)
    }
}
