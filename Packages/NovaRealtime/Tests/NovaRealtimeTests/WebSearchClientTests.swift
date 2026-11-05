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
        _ = try await client.search("上海后天天气怎么样", attempt: 1)
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
                                       "search_options": ["search_strategy": "turbo", "enable_source": true,
                                                          "forced_search": true]])
        guard case .array(let messages)? = body["input"]?["messages"] else { Issue.record("no messages"); return }
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system" && messages[1]["role"] == "user")
        #expect(messages[0]["content"] == [["text": .string("今天是2026年11月4日，星期三，时区Asia/Shanghai。必须联网搜索，不要凭记忆回答。用一两句中文回答，给出具体的数字、地点和日期。查不到就说查不到。回答要写明是哪一天（几月几号）。问题里写了日期就只回答那一天；找不到那一天的信息就说查不到。")]])
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
        await #expect(throws: WebSearchError.http(403, code: "AllocationQuota.FreeTierOnly")) { try await http.search("q", attempt: 1) }
        let bare = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (503, Data()) })
        await #expect(throws: WebSearchError.http(503, code: nil)) { try await bare.search("q", attempt: 1) }
        let chunk = Data("data:{\"output\":{}}\ndata:{\"code\":\"InternalError\",\"message\":\"m\"}\n".utf8)
        let api = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, chunk) })
        await #expect(throws: WebSearchError.api("InternalError")) { try await api.search("q", attempt: 1) }
        let down = QwenWebSearchClient(key: { TestKey.value }, send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: WebSearchError.network) { try await down.search("q", attempt: 1) }
        let slow = QwenWebSearchClient(key: { TestKey.value }, send: { _ in throw URLError(.timedOut) })
        await #expect(throws: WebSearchError.timeout) { try await slow.search("q", attempt: 1) }
        let calls = Mutex(0)
        for missing in [nil, ""] as [String?] {
            let none = QwenWebSearchClient(key: { missing }, send: { _ in calls.withLock { $0 += 1 }; return (200, Data()) })
            await #expect(throws: WebSearchError.notConfigured) { try await none.search("q", attempt: 1) }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("§18 rows 1, 5, 7: one exchange per request with its attempt, body and counts; errors; never the key")
    func exchanges() async throws {
        let seen = Mutex<[WebSearchExchange]>([])
        let client = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, Data(Self.stream.utf8)) },
                                         onExchange: { x in seen.withLock { $0.append(x) } })
        _ = try await client.search("上海后天天气", attempt: 2)
        let x = try #require(seen.withLock { $0 }.first)
        #expect(seen.withLock { $0 }.count == 1)
        #expect(x.attempt == 2 && x.status == 200 && x.error == nil && x.bytes == Self.stream.utf8.count)
        #expect(x.responseBody == Self.stream)
        #expect(x.requestBody.contains("上海后天天气") && x.requestBody.contains(#""forced_search":true"#) && x.requestBody.contains(#""search_strategy":"turbo""#))
        #expect(!x.requestBody.contains(TestKey.value) && !"\(x)".contains(TestKey.value) && !"\(x)".contains("Bearer"))
        #expect(x.chunks == 3 && x.answerChars == "上海后天小雨，16到21度。".count && x.sources == 2 && x.searchCount == 1)
        let forbidden = Data(#"{"code":"AllocationQuota.FreeTierOnly","message":"m"}"#.utf8)
        for (send, error, url) in [
            ({ @Sendable (_: URLRequest) async throws -> (status: Int, body: Data) in throw URLError(.timedOut) }, "timeout", -1001),
            ({ @Sendable (_: URLRequest) async throws -> (status: Int, body: Data) in throw URLError(.notConnectedToInternet) }, "network", -1009),
        ] {
            let got = Mutex<[WebSearchExchange]>([])
            let c = QwenWebSearchClient(key: { TestKey.value }, send: send, onExchange: { x in got.withLock { $0.append(x) } })
            _ = try? await c.search("q", attempt: 1)
            let e = try #require(got.withLock { $0 }.first)
            #expect(e.error == error && e.urlError == url && e.status == nil && e.responseBody == nil)
        }
        let got = Mutex<[WebSearchExchange]>([])
        let c = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (403, forbidden) }, onExchange: { x in got.withLock { $0.append(x) } })
        _ = try? await c.search("q", attempt: 1)
        #expect(got.withLock { $0 }.first?.status == 403 && got.withLock { $0 }.first?.responseBody?.contains("FreeTierOnly") == true)
        // No key: no request, so no exchange.
        let none = Mutex(0)
        let noKey = QwenWebSearchClient(key: { nil }, send: { _ in (200, Data()) }, onExchange: { _ in none.withLock { $0 += 1 } })
        _ = try? await noKey.search("q", attempt: 1)
        #expect(none.withLock { $0 } == 0)
    }

    @Test("§18 rows 6, 8-9: counts use the whole body; with no listener the reply is the same")
    func wholeBody() async throws {
        let pad = String(repeating: "x", count: 100_000)
        let big = "data:{\"pad\":\"\(pad)\"}\n" + Self.stream
        let seen = Mutex<[WebSearchExchange]>([])
        let on = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, Data(big.utf8)) },
                                     onExchange: { x in seen.withLock { $0.append(x) } })
        let off = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, Data(big.utf8)) })
        let a = try await on.search("q", attempt: 1)
        let b = try await off.search("q", attempt: 1)
        #expect(a == b && a.sources.count == 2)
        #expect(seen.withLock { $0 }.first?.sources == 2 && seen.withLock { $0 }.first?.chunks == 4)
    }

    @Test("§19 item 3, §20 row 1: the date sentence and forced_search are in every request")
    func forced() {
        #expect(QwenWebSearchClient.forcedSearch && QwenWebSearchClient.searchStrategy == "turbo" && QwenWebSearchClient.enableSource)
        let client = QwenWebSearchClient(key: { TestKey.value })
        let one = client.request("上海后天（2026年11月6日）天气", key: "k").httpBody
        let two = client.request("上海后天（2026年11月6日）天气", key: "k").httpBody
        let body = String(decoding: one ?? Data(), as: UTF8.self)
        #expect(body.contains(#""forced_search":true"#) && body.contains("上海后天（2026年11月6日）天气"))
        #expect(body.contains("回答要写明是哪一天（几月几号）。问题里写了日期就只回答那一天；找不到那一天的信息就说查不到。"))
        #expect(one == two)
    }

    @Test("§22 rows 1-2: turbo on first attempt and retry; HTTP 400 with a code is one request, no other strategy")
    func turbo() async {
        let bodies = Mutex<[String]>([])
        let client = QwenWebSearchClient(key: { TestKey.value }, send: { request in
            bodies.withLock { $0.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
            return (400, Data(#"{"code":"InvalidParameter","message":"m"}"#.utf8))
        })
        for attempt in 1...2 {
            await #expect(throws: WebSearchError.http(400, code: "InvalidParameter")) {
                _ = try await client.search("横琴后天天气", attempt: attempt)
            }
        }
        let sent = bodies.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.contains(#""search_strategy":"turbo""#) && $0.contains(#""forced_search":true"#)
            && $0.contains(#""enable_source":true"#) && !$0.contains("agent") })
    }
}
