import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

struct TestKey: RealtimeCredentialSource {
    // Built from parts so no key-like literal is in the repo.
    static let value = ["test", "only", "value"].joined(separator: "-")
    func credential() async throws -> RealtimeCredential { .apiKey(Self.value) }
}

@Suite("T-046d F-18 §16 search model client")
struct WebSearchClientTests {
    @Test("Rows 1-2: the live setup never sends googleSearch")
    func liveSetup() {
        let config = SessionConfig(systemInstruction: "x", tools: [ToolDeclaration(name: "web_search", description: "d",
                                                                                     parametersJSONSchema: ["type": "object"])])
        let setup = GeminiCodec.setup(config, resume: nil)
        let text = String(decoding: try! JSONValue.canonicalEncoder().encode(setup), as: UTF8.self)
        #expect(!text.contains("googleSearch") && !text.contains("google_search"))
        if case .array(let tools)? = setup["setup"]?["tools"] { #expect(tools.count == 1) } else { Issue.record("no tools") }
    }

    @Test("Row 4: URL names gemini-2.5-flash-lite; body has google_search and the injected date; key only in the header")
    func request() async throws {
        let sent = Mutex<URLRequest?>(nil)
        let date = Date(timeIntervalSince1970: 1_793_750_400)  // 2026-11-04 08:00 Asia/Shanghai
        let client = GeminiWebSearchClient(credentials: TestKey(), send: { request in
            sent.withLock { $0 = request }
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"text":"后天小雨。"}]},"groundingMetadata":{"webSearchQueries":["上海 后天 天气"],"groundingChunks":[{"web":{"uri":"https://vertexaisearch.cloud.google.com/x","title":"weather.com.cn","domain":"weather.com.cn"}}],"searchEntryPoint":{"renderedContent":"<div>chip</div>"}}}]}"#.utf8))
        }, now: { date }, zone: { TimeZone(identifier: "Asia/Shanghai")! })
        let reply = try await client.search("上海后天天气怎么样")
        let request = try #require(sent.withLock { $0 })
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == TestKey.value)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""google_search":{}"#))
        #expect(body.contains("今天是2026年11月4日，星期三，时区Asia/Shanghai。必须用 Google 搜索查，不要凭记忆回答。"))
        #expect(body.contains("上海后天天气怎么样"))
        #expect(!body.contains(TestKey.value) && !(request.url?.absoluteString.contains(TestKey.value) ?? true))
        #expect(reply == WebSearchReply(answer: "后天小雨。", queries: ["上海 后天 天气"],
                                        sources: [WebSearchSource(title: "weather.com.cn", host: "weather.com.cn")],
                                        suggestionHTML: "<div>chip</div>"))
    }

    @Test("Errors: HTTP status, network and no candidates")
    func errors() async {
        let http = GeminiWebSearchClient(credentials: TestKey(), send: { _ in (429, Data()) })
        await #expect(throws: WebSearchError.http(429)) { try await http.search("q") }
        let down = GeminiWebSearchClient(credentials: TestKey(), send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: WebSearchError.network) { try await down.search("q") }
        let slow = GeminiWebSearchClient(credentials: TestKey(), send: { _ in throw URLError(.timedOut) })
        await #expect(throws: WebSearchError.timeout) { try await slow.search("q") }
        #expect(GeminiWebSearchClient.parse(Data("{}".utf8)) == WebSearchReply(answer: "", queries: [], sources: [], suggestionHTML: nil))
    }
}
