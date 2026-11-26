import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

// F-18 §46 items 1-5 (T-046zi): the Tavily client and the qwen3.5-omni-flash reader.

private func json(_ r: URLRequest) -> JSONValue? {
    r.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
}

private final class Sent: Sendable {
    private let list = Mutex<[URLRequest]>([])
    let answers: Mutex<[(Int, Data)]>
    init(_ answers: [(Int, Data)]) { self.answers = Mutex(answers) }
    var all: [URLRequest] { list.withLock { $0 } }
    var send: QwenWebSearchClient.Send {
        { r in
            self.list.withLock { $0.append(r) }
            return self.answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }
}

@Suite("F-18 §46 Tavily and omni clients")
struct TavilyClientTests {
    @Test("T-046zi F-18 §46 row 107: Tavily key in Keychain `tavily_api_key`; no 七牛云 key and no api.qnaigc.com in the app source")
    func row107() throws {
        #expect(CredentialKey.tavilyAPIKey.rawValue == "tavily_api_key")
        #expect(CredentialKey(rawValue: "qiniu_api_key") == nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..")
        for dir in ["Packages/NovaRealtime/Sources", "Packages/NovaCore/Sources", "App/NovaDrive"] {
            let base = root.appendingPathComponent(dir)
            for case let f as String in FileManager.default.enumerator(atPath: base.path) ?? .init() where f.hasSuffix(".swift") {
                let text = try String(contentsOf: base.appendingPathComponent(f), encoding: .utf8)
                #expect(!text.contains("api.qnaigc.com"), "\(dir)/\(f)")
                #expect(!text.contains("七牛云 key"), "\(dir)/\(f)")
            }
        }
    }

    @Test("T-046zi F-18 §46 row 108: search body as item 2, Bearer Tavily key; picture search as item 5; Extract as item 4")
    func row108() async throws {
        let body = Data(#"{"results": [{"title": "T", "url": "https://a.example/1", "content": "C", "published_date": "2026-11-01"}], "images": ["https://i.example/1.jpg", {"url": "https://i.example/2.jpg", "description": "d"}]}"#.utf8)
        let sent = Sent([(200, body)])
        let client = TavilyClient(key: { "tvly-k" }, send: sent.send)
        let r = try await client.search("珠海 横琴 澳门 2026年11月 12月 展览展会 AI 科技展 航展", images: false)
        #expect(r.hits.first?.snippet == "C" && r.hits.first?.date == "2026-11-01" && r.attempts == 1)
        #expect(r.images == ["https://i.example/1.jpg", "https://i.example/2.jpg"])
        let req = sent.all[0]
        #expect(req.url?.absoluteString == "https://api.tavily.com/search")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-k")
        #expect(json(req) == ["query": "珠海 横琴 澳门 2026年11月 12月 展览展会 AI 科技展 航展", "max_results": 20, "search_depth": "basic"])
        _ = try await client.search("张敬轩 海报", images: true)
        #expect(json(sent.all[1]) == ["query": "张敬轩 海报", "max_results": 5, "include_images": true, "include_image_descriptions": true])
        #expect(json(TavilyClient.extractRequest(["u"], key: "k")) == ["urls": ["u"], "include_images": true, "extract_depth": "basic", "format": "markdown"])
        #expect(TavilyClient.downloadRequest("https://i.example/1.jpg")?.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")
    }

    @Test("T-046zi F-18 §46 item 2: a 5xx is tried 3 times (1 s, 3 s), then once on §41's search")
    func retryThenQwen() async throws {
        struct Qwen: EventWebSearcher {
            func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
                EventSearchAnswer(text: "answer", sources: [EventSearchHit(title: "", url: "https://q.example/1", site: "")])
            }
        }
        let sent = Sent([(503, Data())])
        let waits = Mutex<[Int64]>([])
        let client = TavilyClient(key: { "k" }, send: sent.send, fallback: Qwen(), sleep: { d in waits.withLock { $0.append(d.milliseconds) } })
        let r = try await client.search("q", images: false)
        #expect(sent.all.count == 3 && waits.withLock { $0 } == [1000, 3000])
        #expect(r.hits.first?.snippet == "answer" && r.attempts == 3)
        await #expect(throws: (any Error).self) { try await TavilyClient(key: { nil }).search("q", images: false) }
    }

    @Test("T-046zi F-18 §46 row 115: qwen3.5-omni-flash allowed; requests streamed with modalities text; the picture alone with the prompt")
    func row115() async throws {
        #expect(QwenRoute.allowedModels.contains("qwen3.5-omni-flash"))
        let sse = Data("data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"text\\\": \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"\\\"盛乐\\\"}\"}}]}\n\ndata: [DONE]\n".utf8)
        let sent = Sent([(429, Data()), (200, sse)])
        let waits = Mutex<[Int64]>([])
        let reader = QwenOmniReader(key: { "k" }, send: sent.send, sleep: { d in waits.withLock { $0.append(d.milliseconds) } })
        let text = try await reader.picture("data:image/png;base64,AAAA", prompt: "P")
        #expect(text == #"{"text": "盛乐"}"#)
        #expect(waits.withLock { $0 } == [5000])
        let body = json(sent.all[1])
        #expect(body?["model"] == "qwen3.5-omni-flash" && body?["stream"] == true && body?["modalities"] == ["text"])
        #expect(body?["stream_options"] == ["include_usage": true])
        #expect(body?["messages"] == [["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
                                                                   ["type": "text", "text": "P"]]]])
        #expect(sent.all[1].url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }
}
