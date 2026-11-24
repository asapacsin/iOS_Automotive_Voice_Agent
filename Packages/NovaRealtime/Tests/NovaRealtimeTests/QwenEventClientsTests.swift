import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

private func first(_ v: JSONValue?) -> JSONValue? {
    if case .array(let a)? = v { return a.first }
    return nil
}

@Suite("T-046zb F-18 §39 events search and extraction clients")
struct QwenEventClientsTests {
    @Test("T-046zb F-18 §39 row 49: search body is qwen3.8-flash, forced, max, sources, thinking off, the query the only message, no system; answer text and sources kept")
    func row49() async throws {
        let s = QwenEventSearcher(key: { "k" })
        let body = try JSONDecoder().decode(JSONValue.self, from: s.request("珠海 漫展 ACG 2026年11月 12月", key: "k").httpBody!)
        #expect(body["model"] == "qwen3.8-flash")
        guard case .array(let m)? = body["input"]?["messages"] else { Issue.record("no messages"); return }
        #expect(m.count == 1 && m[0]["role"] == "user" && first(m[0]["content"])?["text"] == "珠海 漫展 ACG 2026年11月 12月")
        let p = body["parameters"]
        #expect(p?["enable_search"] == true && p?["enable_thinking"] == false)
        #expect(p?["search_options"]?["forced_search"] == true && p?["search_options"]?["search_strategy"] == "max"
                && p?["search_options"]?["enable_source"] == true)

        let reply = """
        data: {"output":{"choices":[{"message":{"content":"起源ACG动漫展"}}],"search_info":{"search_results":[{"title":"起源ACG","url":"https://zh.example.com/acg","site_name":"例子"}]}}}
        data: {"output":{"choices":[{"message":{"content":"12月5日至6日。"}}]},"usage":{"total_tokens":1500}}
        """
        let answer = try await QwenEventSearcher(key: { "k" }, send: { _ in (200, Data(reply.utf8)) }, fallback: QwenFallback())
            .search("q", timeout: .seconds(45))
        #expect(answer == EventSearchAnswer(text: "起源ACG动漫展12月5日至6日。",
                                            sources: [EventSearchHit(title: "起源ACG", url: "https://zh.example.com/acg", site: "例子")],
                                            tokens: 1500))
    }

    @Test("T-046zb F-18 §39 item 3: extraction body is qwen3.8-flash on the compatible endpoint, json_object, thinking off, not streamed; content and tokens returned")
    func extraction() async throws {
        let e = QwenEventExtractor(key: { "k" })
        let req = e.request(system: "Extract the event information.", user: "U", key: "k")
        #expect(req.url?.absoluteString == QwenRoute.plannerEndpoint)
        let body = try JSONDecoder().decode(JSONValue.self, from: req.httpBody!)
        #expect(body["model"] == "qwen3.8-flash" && body["enable_thinking"] == false && body["stream"] == false)
        #expect(body["response_format"]?["type"] == "json_object")
        #expect(first(body["messages"])?["role"] == "system" && first(body["messages"])?["content"] == "Extract the event information.")
        let answer = #"{"choices":[{"message":{"content":"{\"events\":[]}"}}],"usage":{"total_tokens":900}}"#
        let r = try await QwenEventExtractor(key: { "k" }, send: { _ in (200, Data(answer.utf8)) }, fallback: QwenFallback())
            .extract(system: "S", user: "U", timeout: .seconds(30))
        #expect(r == EventModelReply(content: #"{"events":[]}"#, tokens: 900))
    }
}
