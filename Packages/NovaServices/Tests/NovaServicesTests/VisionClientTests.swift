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

    func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func reply(_ text: String) -> Data {
        json(["candidates": [["content": ["parts": [["text": text]]]]]])
    }

    func choice(_ text: String) -> Data {
        json(["choices": [["message": ["content": text]]]])
    }

    @Test("Gemini request: model path, key header, system text, image and question")
    func geminiRequest() async throws {
        let t = StubTransport()
        t.body = reply(" 前面是红灯。 ")
        let answer = await GeminiVisionClient(key: { "k" }, transport: t).ask("前面是什么", image: image)
        #expect(answer == .answer("前面是红灯。"))
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        let raw = try #require(r.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        #expect((parts[0]["inline_data"] as? [String: Any])?["data"] as? String == Data(image.data).base64EncodedString())
        #expect(parts[1]["text"] as? String == "前面是什么")
        let system = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"]
        #expect(system as? String == GeminiVisionClient.systemText)
    }

    @Test("Gemini failures: no key sends nothing; 403 and bad key are AuthFailed; 5xx is Busy; empty is Failed")
    func geminiFailures() async {
        let t = StubTransport()
        #expect(await GeminiVisionClient(key: { nil }, transport: t).ask("q", image: image) == .notConfigured)
        #expect(t.requests.isEmpty)
        let client = GeminiVisionClient(key: { "k" }, transport: t)
        t.status = 403
        #expect(await client.ask("q", image: image) == .authFailed)
        t.status = 400
        t.body = json(["error": ["message": "API key not valid."]])
        #expect(await client.ask("q", image: image) == .authFailed)
        t.status = 500
        #expect(await client.ask("q", image: image) == .busy)
        t.status = 404
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

    @Test("F-20a §14 row 9: Gemini pinned to a GA model; 503 and 429 are Busy")
    func geminiPinned() async {
        #expect(GeminiVisionClient.defaultModel == "gemini-3.5-flash-lite")
        #expect(!GeminiVisionClient.defaultModel.contains("latest"))
        let t = StubTransport()
        let client = GeminiVisionClient(key: { "k" }, transport: t)
        t.status = 503
        #expect(await client.reply("q", image: image) == VisionReply(.busy, status: "503"))
        t.status = 429
        #expect(await client.ask("q", image: image) == .busy)
    }

    @Test("F-20a §14 row 8: GLM request: URL, Bearer, model, thinking off, image before text, same system text")
    func glmRequest() async throws {
        let t = StubTransport()
        t.body = choice("<|begin_of_box|> 前面是绿灯。 <|end_of_box|>")
        let answer = await GLMVisionClient(key: { "z" }, transport: t).ask("前面是什么灯", image: image)
        #expect(answer == .answer("前面是绿灯。"))
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer z")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let raw = try #require(r.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(body["model"] as? String == "glm-4.6v-flash")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == GeminiVisionClient.systemText)
        let user = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(user[0]["type"] as? String == "image_url")
        #expect((user[0]["image_url"] as? [String: Any])?["url"] as? String == Data(image.data).base64EncodedString())
        #expect(user[1]["type"] as? String == "text")
        #expect(user[1]["text"] as? String == "前面是什么灯")
    }

    @Test("F-20a §14 item 2: GLM status mapping; empty content is Failed; no key sends nothing")
    func glmFailures() async {
        let t = StubTransport()
        #expect(await GLMVisionClient(key: { "" }, transport: t).ask("q", image: image) == .notConfigured)
        #expect(t.requests.isEmpty)
        let client = GLMVisionClient(key: { "z" }, transport: t)
        t.body = choice(" <|begin_of_box|><|end_of_box|> ")
        #expect(await client.ask("q", image: image) == .failed)
        for (status, expected) in [(401, VisionAnswer.authFailed), (403, .authFailed), (429, .busy), (500, .busy),
                                   (503, .busy), (400, .failed)] {
            t.status = status
            #expect(await client.reply("q", image: image) == VisionReply(expected, status: "\(status)"))
        }
        let broken = ThrowingTransport(error: URLError(.timedOut))
        #expect(await GLMVisionClient(key: { "z" }, transport: broken).reply("q", image: image)
                == VisionReply(.busy, status: "timeout"))
        let offline = ThrowingTransport(error: URLError(.notConnectedToInternet))
        #expect(await QianfanVisionClient(key: { "q" }, model: "m", transport: offline).reply("q", image: image)
                == VisionReply(.busy, status: "network"))
    }
}

private struct ThrowingTransport: HTTPTransport {
    let error: URLError
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) { throw error }
}
