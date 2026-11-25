import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

/// F-18 §41 (T-046zd): a recorded Responses API `web_search` reply (the shape seen on the PC, 2026-11-25).
let webSearchFixture = #"""
{"id":"resp_1","object":"response","status":"completed","output":[
{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"珠海 天气","sources":[{"type":"url","url":"https://a.example.com/1"},{"type":"url","url":"https://b.example.com/2"}]}},
{"type":"web_search_call","id":"ws_2","status":"completed","action":{"type":"search","query":"珠海 今日 天气","sources":[{"type":"url","url":"https://b.example.com/2"},{"type":"url","url":"https://c.example.com/3"}]}},
{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"珠海今天多云，","annotations":[]},{"type":"output_text","text":"18到24度。","annotations":[]}]}
],"usage":{"input_tokens":2400,"output_tokens":200,"total_tokens":2600,"x_tools":{"web_search":{"count":2}}}}
"""#

private let noSearchReply = #"""
{"id":"resp_2","object":"response","status":"completed","output":[
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"places\":[{\"name\":\"浅草寺\",\"english\":\"Senso-ji\",\"minutes\":60,\"importance\":3}],\"hotels\":[],\"area\":\"Tokyo\"}"}]}
],"usage":{"total_tokens":300}}
"""#

@Suite("T-046zd F-18 §41 Responses API web_search")
struct QwenResponsesTests {
    @Test("T-046zd F-18 §41 row 61: live, ground, eventsSearch send to /compatible-mode/v1/responses with tools web_search, thinking off, no enable_search/search_options")
    func row61() throws {
        let ground = TripGroundRequest(city: "Tokyo, Japan", days: 1, places: [TripGroundPlace(name: "浅草寺", minutes: 60, importance: 3)],
                                       wishes: nil, start: nil, end: nil, hotelNear: nil)
        let requests = [
            QwenWebSearchClient(key: { "k" }).request("q", key: "k"),
            QwenTripGrounder(key: { "k" }).request(ground, key: "k"),
            QwenEventSearcher(key: { "k" }).request("q", key: "k"),
        ]
        #expect(QwenRoute.responsesEndpoint == "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")
        for r in requests {
            #expect(r.url?.absoluteString == QwenRoute.responsesEndpoint && r.httpMethod == "POST")
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k" && r.value(forHTTPHeaderField: "X-DashScope-SSE") == nil)
            let body = try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data())
            #expect(body["tools"] == [["type": "web_search"]] && body["enable_thinking"] == false)
            #expect(body["model"] == "deepseek-v4.1-flash" && body["stream"] == nil)
            let text = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
            #expect(!text.contains("enable_search") && !text.contains("search_options") && !text.contains("web_extractor"))
        }
        for route in [QwenRoute.live, .ground, .eventsSearch] { #expect(route.usesResponses && !route.stream) }
        for route in [QwenRoute.picker, .planner, .eventsExtract] { #expect(!route.usesResponses) }
    }

    @Test("T-046zd F-18 §41 row 62: fixture parsed into answer, deduplicated source urls, total_tokens and searches")
    func row62() async throws {
        let r = try #require(QwenWebSearchClient.responses(Data(webSearchFixture.utf8)))
        #expect(r.answer == "珠海今天多云，18到24度。")
        #expect(r.sources == ["https://a.example.com/1", "https://b.example.com/2", "https://c.example.com/3"])
        #expect(r.tokens == 2600 && r.searches == 2)
        let live = QwenWebSearchClient.parse(Data(webSearchFixture.utf8))
        #expect(live.code == nil && live.reply.answer == r.answer && live.reply.sources.count == 3)
        let answer = try await QwenEventSearcher(key: { "k" }, send: { _ in (200, Data(webSearchFixture.utf8)) }, fallback: QwenFallback())
            .search("q", timeout: .seconds(45))
        #expect(answer.sources.map(\.url) == r.sources && answer.sources.allSatisfy { $0.title.isEmpty && $0.site.isEmpty })
        #expect(answer.tokens == 2600 && answer.searches == 2 && answer.text == r.answer)
        #expect(QwenWebSearchClient.counts(Data(webSearchFixture.utf8)).searchCount == 2)
    }

    @Test("T-046zd F-18 §41 row 63: QwenTripGrounder grounded with sources; a reply without web_search_call is not grounded")
    func row63() throws {
        let grounded = Data(webSearchFixture.replacingOccurrences(of: "珠海今天多云，", with: "")
            .replacingOccurrences(of: "18到24度。", with: #"{\"places\":[{\"name\":\"浅草寺\",\"english\":\"Senso-ji\",\"minutes\":60,\"importance\":3}],\"hotels\":[],\"area\":\"Tokyo\"}"#).utf8)
        #expect(try QwenTripGrounder.answer(grounded).places.first?.name == "浅草寺")
        #expect(throws: TripGroundError.noSearch) { try QwenTripGrounder.answer(Data(noSearchReply.utf8)) }
    }

    @Test("T-046zd F-18 §41: a Responses error body gives its code; a quota error moves to the next model")
    func errors() {
        let body = Data(#"{"error":{"code":"AllocationQuota.FreeTierOnly","message":"The free tier of the model has been exhausted."}}"#.utf8)
        #expect(QwenWebSearchClient.errorCode(body) == "AllocationQuota.FreeTierOnly")
        #expect(QwenWebSearchClient.responses(body) == nil && QwenFallback.quotaError(status: 403, body: body))
    }
}
