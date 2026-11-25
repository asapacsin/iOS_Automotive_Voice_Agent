import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

/// F-18 §42 item 2: a Qiniu `/v1/search/web` reply (the shape seen on the PC, 2026-11-25).
let qiniuSearchFixture = #"""
{"success":true,"data":{"query":"珠海 澳门 2026年11月 12月 展览展会 科技展","results":[
{"title":"AIE电子展","url":"https://a.example.com/aie","content":"11月18日至20日在珠海国际会展中心","date":"2026-11-17","source":"例子网","score":0.9},
{"title":"澳门11月宝藏展览合集","url":"https://b.example.com/mo","content":"澳门展览","date":"","source":"","score":0.8},
{"title":"无链接","url":"","content":"x","date":"","source":"","score":0.1}
],"total":3}}
"""#

private let chatReply = #"{"choices":[{"message":{"role":"assistant","content":"珠海今天多云，18到24度。"}}],"usage":{"prompt_tokens":3000,"completion_tokens":200,"completion_tokens_details":{"reasoning_tokens":150},"total_tokens":3200}}"#

/// Records every request; answers by URL.
private final class Wire: Sendable {
    let sent = Mutex<[URLRequest]>([])
    let reply: @Sendable (URLRequest) -> (Int, String)
    init(_ reply: @escaping @Sendable (URLRequest) -> (Int, String)) { self.reply = reply }
    var send: QwenWebSearchClient.Send {
        { [self] request in
            sent.withLock { $0.append(request) }
            let (s, b) = reply(request)
            return (s, Data(b.utf8))
        }
    }
    var urls: [String] { sent.withLock { $0.map { $0.url?.absoluteString ?? "" } } }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private final class FakeLive: WebSearchService, Sendable {
    let calls = Mutex(0)
    func search(_ query: String, attempt: Int) async throws -> WebSearchReply {
        calls.withLock { $0 += 1 }
        return WebSearchReply(answer: "qwen", sources: [])
    }
}

private final class FakeExtractor: EventExtractor, Sendable {
    let calls = Mutex(0)
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        calls.withLock { $0 += 1 }
        return EventModelReply(content: #"{"events":[]}"#, tokens: 1)
    }
}

private let tokyo = TimeZone(identifier: "Asia/Shanghai")!
private let fixed = Date(timeIntervalSince1970: 1_795_579_200)  // 2026-11-25 Asia/Shanghai

@Suite("T-046ze F-18 §42 Qiniu search and model")
struct QiniuSearchTests {
    @Test("T-046ze F-18 §42 row 66: with a 七牛云 key every search job POSTs /v1/search/web, Bearer 七牛云 key, body as item 2; never the 千问 key")
    func row66() async throws {
        let wire = Wire { r in r.url?.absoluteString == QiniuRoute.searchEndpoint ? (200, qiniuSearchFixture) : (200, chatReply) }
        let client = QiniuClient(send: wire.send)
        let live = FakeLive()
        _ = try await QiniuWebSearchClient(key: { "sk-qiniu" }, fallback: live, client: client, now: { fixed }, zone: { tokyo })
            .search("今天珠海天气怎么样", attempt: 1)
        _ = try await QiniuEventSearcher(key: { "sk-qiniu" }, client: client).search("珠海 澳门 2026年11月 展览展会 科技展", timeout: .seconds(45))
        let ground = TripGroundRequest(city: "珠海", days: 1, places: [TripGroundPlace(name: "圆明新园", minutes: 60, importance: 3)],
                                       wishes: nil, start: nil, end: nil, hotelNear: nil)
        _ = try? await QiniuTripGrounder(key: { "sk-qiniu" }, fallback: QwenTripGrounder(key: { "qwen" }), client: client).ground(ground)
        let searches = wire.sent.withLock { $0 }.filter { $0.url?.absoluteString == QiniuRoute.searchEndpoint }
        #expect(searches.count == 3)
        for r in wire.sent.withLock({ $0 }) {
            #expect(r.httpMethod == "POST" && r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-qiniu")
            #expect(!String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("qwen"))
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: searches[0].httpBody ?? Data())
        #expect(body == ["query": "今天珠海天气怎么样", "max_results": 20, "search_type": "web"])
        #expect(searches[0].timeoutInterval == 15)
        #expect(live.calls.withLock { $0 } == 0)
        // The model call: Qiniu chat completions, the model, not streamed.
        let chat = try #require(wire.sent.withLock { $0 }.first { $0.url?.absoluteString == QiniuRoute.chatEndpoint })
        let c = try JSONDecoder().decode(JSONValue.self, from: chat.httpBody ?? Data())
        #expect(c["model"] == "deepseek/deepseek-v4-flash-20260731" && c["stream"] == false)
    }

    @Test("T-046ze F-18 §42 row 67: no 七牛云 key: the §41 clients answer and nothing goes to Qiniu")
    func row67() async throws {
        let wire = Wire { _ in (200, "{}") }
        let live = FakeLive()
        let reply = try await QiniuWebSearchClient(key: { nil }, fallback: live, client: QiniuClient(send: wire.send)).search("q", attempt: 1)
        #expect(reply.answer == "qwen" && live.calls.withLock { $0 } == 1 && wire.urls.isEmpty)
        let extractor = FakeExtractor()
        _ = try await QiniuEventExtractor(key: { "" }, fallback: extractor, client: QiniuClient(send: wire.send))
            .extract(system: "s", user: "u", timeout: .seconds(60))
        #expect(extractor.calls.withLock { $0 } == 1 && wire.urls.isEmpty)
    }

    @Test("T-046ze F-18 §42 row 70: the fixture parsed into title, url, content, date, source; results without a url dropped")
    func row70() async throws {
        let results = try #require(QiniuClient.results(Data(qiniuSearchFixture.utf8)))
        #expect(results == [
            QiniuResult(title: "AIE电子展", url: "https://a.example.com/aie", content: "11月18日至20日在珠海国际会展中心",
                        date: "2026-11-17", source: "例子网"),
            QiniuResult(title: "澳门11月宝藏展览合集", url: "https://b.example.com/mo", content: "澳门展览", date: "", source: ""),
        ])
        #expect(QiniuClient.results(Data(#"{"success":false,"data":{"results":[]}}"#.utf8)) == nil)
        let answer = try await QiniuEventSearcher(key: { "k" }, client: QiniuClient(send: Wire { _ in (200, qiniuSearchFixture) }.send))
            .search("q", timeout: .seconds(45))
        #expect(answer.sources.map(\.snippet) == ["11月18日至20日在珠海国际会展中心", "澳门展览"])
        #expect(answer.sources.map(\.date) == ["2026-11-17", ""] && answer.sources.map(\.site) == ["例子网", "b.example.com"])
    }

    @Test("T-046ze F-18 §42 row 71: a 429 search is failed with reason=rate_limit, one request, not retried, no fallback")
    func row71() async {
        let wire = Wire { _ in (429, #"{"error":{"message":"rate limit reached for RPM","type":"rate_limit"}}"#) }
        let lines = Lines()
        await #expect(throws: QiniuFailure(reason: "rate_limit", status: 429)) {
            _ = try await QiniuEventSearcher(key: { "k" }, client: QiniuClient(send: wire.send), onLine: lines.add)
                .search("q", timeout: .seconds(45))
        }
        #expect(wire.urls.count == 1)
        #expect(lines.all.count == 1 && lines.all[0].hasPrefix("search provider=qiniu job=events ms=")
                && lines.all[0].hasSuffix("results=0 failed=yes reason=rate_limit status=429"))
    }

    @Test("T-046ze F-18 §42 row 72: a failed Qiniu chat call falls back to the same job on §41 (千问 key); the record says so")
    func row72() async throws {
        let wire = Wire { r in r.url?.absoluteString == QiniuRoute.searchEndpoint ? (200, qiniuSearchFixture) : (500, "{}") }
        let lines = Lines()
        let live = FakeLive()
        let reply = try await QiniuWebSearchClient(key: { "k" }, fallback: live, client: QiniuClient(send: wire.send), onLine: lines.add)
            .search("q", attempt: 1)
        #expect(reply.answer == "qwen" && live.calls.withLock { $0 } == 1)
        #expect(lines.all.last?.contains("model provider=qiniu job=live") == true && lines.all.last?.hasSuffix("fallback=qwen") == true)
        let extractor = FakeExtractor()
        let x = try await QiniuEventExtractor(key: { "k" }, fallback: extractor, client: QiniuClient(send: wire.send), onLine: lines.add)
            .extract(system: "s", user: "u", timeout: .seconds(60))
        #expect(x.tokens == 1 && extractor.calls.withLock { $0 } == 1 && lines.all.last?.hasSuffix("fallback=qwen") == true)
        // A failed search on live also falls back (no key path untouched).
        let down = Wire { _ in (503, "{}") }
        _ = try await QiniuWebSearchClient(key: { "k" }, fallback: live, client: QiniuClient(send: down.send)).search("q", attempt: 1)
        #expect(live.calls.withLock { $0 } == 2)
    }

    @Test("T-046ze F-18 §42 item 5: FreshPrompt messages with the top results as the evidence block before the question; answer and tokens recorded")
    func live() async throws {
        let wire = Wire { r in r.url?.absoluteString == QiniuRoute.searchEndpoint ? (200, qiniuSearchFixture) : (200, chatReply) }
        let lines = Lines()
        let client = QiniuWebSearchClient(key: { "k" }, fallback: FakeLive(), client: QiniuClient(send: wire.send),
                                          now: { fixed }, zone: { tokyo }, onLine: lines.add)
        let reply = try await client.search("query: 珠海今天天气\n\nquestion: 今天珠海天气怎么样\nanswer: ", attempt: 1)
        #expect(reply.answer == "珠海今天多云，18到24度。" && reply.sources.count == 2)
        let chat = try #require(wire.sent.withLock { $0 }.first { $0.url?.absoluteString == QiniuRoute.chatEndpoint })
        let body = try JSONDecoder().decode(JSONValue.self, from: chat.httpBody ?? Data())
        guard case .array(let m)? = body["messages"], m.count == 4 else { Issue.record("messages"); return }
        #expect(m[0]["content"] == .string(QwenWebSearchClient.instruction(now: fixed, zone: tokyo)))
        #expect(m[3]["content"] == .string("query: 珠海今天天气"
            // A date that does not parse sorts first (FreshPrompt's na_position='first'); no source: the url's host.
            + "\n\nsource: b.example.com"
            + "\ndate: \ntitle: 澳门11月宝藏展览合集\nsnippet: 澳门展览\nhighlight: "
            + "\n\nsource: a.example.com\ndate: Nov 17, 2026\ntitle: AIE电子展\nsnippet: 11月18日至20日在珠海国际会展中心\nhighlight: "
            + "\n\nquestion: 今天珠海天气怎么样\nanswer: "))
        #expect(lines.all.last?.hasPrefix("model provider=qiniu job=live model=deepseek/deepseek-v4-flash-20260731 ms=") == true
                && lines.all.last?.hasSuffix("tokens=3000,200,150") == true)
        // The search got her query, not the FreshPrompt message (review 2026-11-25).
        let search = try #require(wire.sent.withLock { $0 }.first { $0.url?.absoluteString == QiniuRoute.searchEndpoint })
        #expect(try JSONDecoder().decode(JSONValue.self, from: search.httpBody ?? Data())["query"] == "珠海今天天气")
    }

    @Test("T-046ze F-18 §42 item 5: with no driver words (`question: Q\nanswer: `) the search gets Q and the message is the notebook frame, no doubled labels")
    func liveNoWords() async throws {
        let wire = Wire { r in r.url?.absoluteString == QiniuRoute.searchEndpoint ? (200, qiniuSearchFixture) : (200, chatReply) }
        let client = QiniuWebSearchClient(key: { "k" }, fallback: FakeLive(), client: QiniuClient(send: wire.send),
                                          now: { fixed }, zone: { tokyo })
        _ = try await client.search("question: 珠海天气\nanswer: ", attempt: 1)
        let sent = wire.sent.withLock { $0 }
        #expect(try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())["query"] == "珠海天气")
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody ?? Data())
        guard case .array(let m)? = body["messages"], let text = m[3]["content"]?.stringValue else { Issue.record("messages"); return }
        #expect(text.hasPrefix("query: 珠海天气\n\nsource: ") && text.hasSuffix("\nhighlight: \n\nquestion: 珠海天气\nanswer: "))
        #expect(FreshPromptEvidence.displayDate("2026-11-05") == "Nov 05, 2026")
        #expect(text.components(separatedBy: "question: ").count == 2 && text.components(separatedBy: "answer: ").count == 2)
    }

    @Test("T-046ze F-18 §42 item 5: a live search with no results is not grounded: §41 answers, no model call")
    func liveNoResults() async throws {
        let wire = Wire { _ in (200, #"{"success":true,"data":{"results":[],"total":0}}"#) }
        let live = FakeLive()
        let reply = try await QiniuWebSearchClient(key: { "k" }, fallback: live, client: QiniuClient(send: wire.send)).search("q", attempt: 1)
        #expect(reply.answer == "qwen" && wire.urls == [QiniuRoute.searchEndpoint])
    }
}
