import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

enum TestKey {
    // Built from parts so no key-like literal is in the repo.
    static let value = ["test", "only", "value"].joined(separator: "-")
}

@Suite("T-046e F-18 §17 search model client")
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

    @Test("Row 2: URL, headers and body as §17 item 3; injected date; key only in the header; no Google tool")
    func request() async throws {
        let sent = Mutex<URLRequest?>(nil)
        let date = Date(timeIntervalSince1970: 1_793_750_400)  // 2026-11-04 08:00 Asia/Shanghai
        let client = QwenWebSearchClient(key: { TestKey.value }, send: { request in
            sent.withLock { $0 = request }
            return (200, Data(Self.stream.utf8))
        }, now: { date }, zone: { TimeZone(identifier: "Asia/Shanghai")! })
        _ = try await client.search("上海后天天气怎么样")
        let request = try #require(sent.withLock { $0 })
        #expect(request.url?.absoluteString == "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKey.value)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-DashScope-SSE") == "enable")
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        #expect(body["model"] == "qwen3.7-flash")
        #expect(body["parameters"] == ["result_format": "message", "incremental_output": true, "enable_thinking": false,
                                       "enable_search": true,
                                       "search_options": ["search_strategy": "agent", "enable_source": true]])
        guard case .array(let messages)? = body["input"]?["messages"] else { Issue.record("no messages"); return }
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system" && messages[1]["role"] == "user")
        #expect(messages[0]["content"] == [["text": .string("今天是2026年11月4日，星期三，时区Asia/Shanghai。必须联网搜索，不要凭记忆回答。用一两句中文回答，给出具体的数字、地点和日期。查不到就说查不到。")]])
        #expect(messages[1]["content"] == [["text": "上海后天天气怎么样"]])
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!text.contains(TestKey.value) && !(request.url?.absoluteString.contains(TestKey.value) ?? true))
        #expect(!text.contains("google"))
        #expect(QwenWebSearchClient.model == "qwen3.7-flash")
    }

    static let stream = """
    :keep-alive
    id:1
    event:result
    data:{"output":{"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"想一想"}}]}}

    data:not json
    data:{"output":{"choices":[{"message":{"role":"assistant","content":[{"text":"上海后天"}]}}],"search_info":{"search_results":[{"index":1,"title":"上海天气","url":"https://www.weather.com.cn/x"},{"index":2,"title":"b","url":"https://b.example.org/y"}]}}}
    data:{"output":{"choices":[{"message":{"role":"assistant","content":"小雨，16到21度。"}}],"search_info":{"search_results":[]}},"usage":{"plugins":{"search":{"count":1}}}}
    """

    @Test("Row 3: both content shapes joined in order, reasoning left out, non-JSON ignored, sources as hosts")
    func parse() {
        let parsed = QwenWebSearchClient.parse(Data(Self.stream.utf8))
        #expect(parsed.code == nil)
        #expect(parsed.reply == WebSearchReply(answer: "上海后天小雨，16到21度。",
                                               sources: [WebSearchSource(title: "上海天气", host: "www.weather.com.cn"),
                                                         WebSearchSource(title: "b", host: "b.example.org")]))
        // A search count alone gives no sources.
        let countOnly = #"data:{"output":{"choices":[{"message":{"content":"晴"}}]},"usage":{"plugins":{"search":{"count":2}}}}"#
        #expect(QwenWebSearchClient.parse(Data(countOnly.utf8)).reply.sources.isEmpty)
        #expect(QwenWebSearchClient.parse(Data("{}".utf8)).reply == WebSearchReply(answer: "", sources: []))
    }

    @Test("Row 5: HTTP status with its code, an error code in a 200 stream, network, timeout, no key")
    func errors() async {
        let errorBody = Data(#"{"code":"AllocationQuota.FreeTierOnly","message":"secret words","request_id":"r"}"#.utf8)
        let http = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (403, errorBody) })
        await #expect(throws: WebSearchError.http(403, code: "AllocationQuota.FreeTierOnly")) { try await http.search("q") }
        let bare = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (503, Data()) })
        await #expect(throws: WebSearchError.http(503, code: nil)) { try await bare.search("q") }
        let chunk = Data("data:{\"output\":{}}\ndata:{\"code\":\"InternalError\",\"message\":\"m\"}\n".utf8)
        let api = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, chunk) })
        await #expect(throws: WebSearchError.api("InternalError")) { try await api.search("q") }
        let down = QwenWebSearchClient(key: { TestKey.value }, send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: WebSearchError.network) { try await down.search("q") }
        let slow = QwenWebSearchClient(key: { TestKey.value }, send: { _ in throw URLError(.timedOut) })
        await #expect(throws: WebSearchError.timeout) { try await slow.search("q") }
        let calls = Mutex(0)
        for missing in [nil, ""] as [String?] {
            let none = QwenWebSearchClient(key: { missing }, send: { _ in calls.withLock { $0 += 1 }; return (200, Data()) })
            await #expect(throws: WebSearchError.notConfigured) { try await none.search("q") }
        }
        #expect(calls.withLock { $0 } == 0)
    }
}
