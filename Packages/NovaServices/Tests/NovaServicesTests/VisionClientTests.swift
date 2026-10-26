import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

@Suite("T-071c F-20a vision clients")
struct VisionClientTests {
    let image = JPEGImage(data: [0xFF, 0xD8, 0xFF])

    func reply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
    }

    func choice(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }

    @Test("Gemini request: model path, key header, system text, image and question")
    func geminiRequest() async throws {
        let t = StubTransport()
        t.body = reply(" 前面是红灯。 ")
        let answer = await GeminiVisionClient(key: { "k" }, transport: t).ask("前面是什么", image: image)
        #expect(answer == .answer("前面是红灯。"))
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent")
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        let raw = try #require(r.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        #expect((parts[0]["inline_data"] as? [String: Any])?["data"] as? String == Data(image.data).base64EncodedString())
        #expect(parts[1]["text"] as? String == "前面是什么")
        let system = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"]
        #expect(system as? String == GeminiVisionClient.systemText)
    }

    @Test("Gemini failures: no key sends nothing; 403 and bad key are AuthFailed; 500 and empty are Failed")
    func geminiFailures() async {
        let t = StubTransport()
        #expect(await GeminiVisionClient(key: { nil }, transport: t).ask("q", image: image) == .notConfigured)
        #expect(t.requests.isEmpty)
        let client = GeminiVisionClient(key: { "k" }, transport: t)
        t.status = 403
        #expect(await client.ask("q", image: image) == .authFailed)
        t.status = 400
        t.body = try! JSONSerialization.data(withJSONObject: ["error": ["message": "API key not valid."]])
        #expect(await client.ask("q", image: image) == .authFailed)
        t.status = 500
        #expect(await client.ask("q", image: image) == .failed)
        t.status = 200
        t.body = reply("  ")
        #expect(await client.ask("q", image: image) == .failed)
    }

    @Test("Qianfan request: bearer token, data URL; answer from the first choice")
    func qianfan() async throws {
        let t = StubTransport()
        t.body = choice("一辆公交车")
        let answer = await QianfanVisionClient(key: { "q" }, model: "m", transport: t).ask("这是什么车", image: image)
        #expect(answer == .answer("一辆公交车"))
        let r = try #require(t.requests.first)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer q")
        let raw = try #require(r.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let user = try #require((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        let url = (user[0]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/jpeg;base64," + Data(image.data).base64EncodedString())
    }

    @Test("OQ-CAM-1: Gemini is used when its key exists, else Qianfan, else NotConfigured")
    func preference() async {
        let g = StubTransport()
        g.body = reply("gemini")
        let q = StubTransport()
        q.body = choice("qianfan")
        let gemini = GeminiVisionClient(key: { "k" }, transport: g)
        let qianfan = QianfanVisionClient(key: { "q" }, model: "m", transport: q)
        let both = PreferredVision(gemini: gemini, qianfan: qianfan, hasGeminiKey: { true })
        let fallback = PreferredVision(gemini: gemini, qianfan: qianfan, hasGeminiKey: { false })
        let none = PreferredVision(gemini: gemini, qianfan: nil, hasGeminiKey: { false })
        #expect(await both.ask("x", image: image) == .answer("gemini"))
        #expect(await fallback.ask("x", image: image) == .answer("qianfan"))
        #expect(await none.ask("x", image: image) == .notConfigured)
    }
}
