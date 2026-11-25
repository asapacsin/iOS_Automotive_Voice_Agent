import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

/// F-18 §45 (T-046zh): a Qiniu call that failed every §43 try goes to the same job on the Qwen API (千问 key).

private final class Sent: Sendable {
    let urls = Mutex<[String]>([])
    let reply: @Sendable (URLRequest) -> (Int, String)
    init(_ reply: @escaping @Sendable (URLRequest) -> (Int, String)) { self.reply = reply }
    var send: QiniuClient.Send {
        { [self] r in
            urls.withLock { $0.append(r.url?.absoluteString ?? "") }
            let (s, b) = reply(r)
            return (s, Data(b.utf8))
        }
    }
    var all: [String] { urls.withLock { $0 } }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private let noWait: QiniuClient.Sleep = { _ in }
private let okSearch = #"{"success":true,"data":{"results":[{"title":"t","url":"https://a.example/1","content":"c","date":"2026-11-20","source":""}]}}"#

/// §41's live client stand-in: answers, or has no 千问 key.
private final class Live: WebSearchService, Sendable {
    let calls = Mutex<[String]>([])
    let configured: Bool
    init(configured: Bool = true) { self.configured = configured }
    func search(_ query: String, attempt: Int) async throws -> WebSearchReply {
        guard configured else { throw WebSearchError.notConfigured }
        calls.withLock { $0.append(query) }
        return WebSearchReply(answer: "qwen", sources: [WebSearchSource(title: "", host: "")])
    }
}

private final class Ground: TripGrounder, Sendable {
    let calls = Mutex(0)
    func ground(_ request: TripGroundRequest) async throws -> TripGroundAnswer {
        calls.withLock { $0 += 1 }
        return TripGroundAnswer(places: [TripGroundPlace(name: "圆明新园", english: "Yuanming", minutes: 60, importance: 3)], hotels: [], area: "珠海")
    }
}

private final class EventsQwen: EventWebSearcher, Sendable {
    let calls = Mutex<[String]>([])
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        calls.withLock { $0.append(query) }
        return EventSearchAnswer(text: "AIE电子展12月3日至5日在珠海国际会展中心", sources: [
            EventSearchHit(title: "", url: "https://q.example/aie", site: ""), EventSearchHit(title: "", url: "https://q.example/2", site: ""),
        ], tokens: 3000, searches: 2)
    }
}

private final class ExtractQwen: EventExtractor, Sendable {
    let calls = Mutex<[(String, String)]>([])
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        calls.withLock { $0.append((system, user)) }
        return EventModelReply(content: #"{"events":[]}"#, tokens: 7)
    }
}

@Suite("T-046zh F-18 §45 Qiniu failed every try: the Qwen API")
struct QiniuQwenFallbackTests {
    @Test("T-046zh F-18 §45 row 100: live model call fails 3 times (5xx): §41 answers with the same message; record fallback provider=qwen")
    func row100() async throws {
        let wire = Sent { r in r.url?.absoluteString == QiniuRoute.searchEndpoint ? (200, okSearch) : (503, "{}") }
        let lines = Lines(), live = Live()
        let reply = try await QiniuWebSearchClient(key: { "k" }, fallback: live, client: QiniuClient(send: wire.send, sleep: noWait),
                                                   onLine: lines.add).search("question: 珠海天气\nanswer: ", attempt: 1)
        #expect(reply.answer == "qwen" && live.calls.withLock { $0 } == ["question: 珠海天气\nanswer: "])
        #expect(wire.all.filter { $0 == QiniuRoute.chatEndpoint }.count == 3)
        #expect(lines.all.last == "fallback provider=qwen job=live after=http status=503")
    }

    @Test("T-046zh F-18 §45 row 101: ground search fails 3 times (network): §41 grounds the same request")
    func row101() async throws {
        let client = QiniuClient(send: { _ in throw URLError(.notConnectedToInternet) }, sleep: noWait)
        let ground = Ground(), lines = Lines()
        let r = TripGroundRequest(city: "珠海", days: 1, places: [TripGroundPlace(name: "圆明新园", minutes: 60, importance: 3)],
                                  wishes: nil, start: nil, end: nil, hotelNear: nil)
        let answer = try await QiniuTripGrounder(key: { "k" }, fallback: ground, client: client, onLine: lines.add).ground(r)
        #expect(answer.places.first?.name == "圆明新园" && ground.calls.withLock { $0 } == 1)
        #expect(lines.all.last == "fallback provider=qwen job=ground after=network")
    }

    @Test("T-046zh F-18 §45 row 102: one events query fails 3 times (429): that query once on QwenEventSearcher; its sources are the query's results, the answer text the first one's snippet")
    func row102() async throws {
        let wire = Sent { _ in (429, #"{"error":{"message":"rate limit reached for RPM"}}"#) }
        let qwen = EventsQwen(), lines = Lines()
        let a = try await QiniuEventSearcher(key: { "k" }, client: QiniuClient(send: wire.send, sleep: noWait), fallback: qwen,
                                             onLine: lines.add).search("珠海 澳门 2026年11月 12月 展览展会 科技展", timeout: .seconds(45))
        #expect(wire.all.count == 3 && qwen.calls.withLock { $0 } == ["珠海 澳门 2026年11月 12月 展览展会 科技展"])
        #expect(a.sources.map(\.url) == ["https://q.example/aie", "https://q.example/2"])
        #expect(a.sources.first?.snippet == "AIE电子展12月3日至5日在珠海国际会展中心" && a.sources.last?.snippet == "")
        #expect(a.sources.map(\.site) == ["q.example", "q.example"] && a.tokens == 3000)
        #expect(lines.all.last == "fallback provider=qwen job=events after=rate_limit status=429")
    }

    @Test("T-046zh F-18 §45 row 103: Qiniu extraction answers 400: no retry; QwenEventExtractor gets the same system and user text")
    func row103() async throws {
        let wire = Sent { _ in (400, #"{"error":{"message":"bad"}}"#) }
        let qwen = ExtractQwen(), lines = Lines()
        let reply = try await QiniuEventExtractor(key: { "k" }, fallback: qwen, client: QiniuClient(send: wire.send, sleep: noWait),
                                                  onLine: lines.add).extract(system: "S", user: "U", timeout: .seconds(60))
        #expect(wire.all.count == 1 && reply.tokens == 7)
        #expect(qwen.calls.withLock { $0 }.map { "\($0.0)|\($0.1)" } == ["S|U"])
        #expect(lines.all.last == "fallback provider=qwen job=events_extract after=http status=400")
    }

    @Test("T-046zh F-18 §45 row 104: no 千问 key: live fails as §43 (no request to dashscope)")
    func row104() async {
        let wire = Sent { _ in (503, "{}") }
        await #expect(throws: WebSearchError.self) {
            _ = try await QiniuWebSearchClient(key: { "k" }, fallback: Live(configured: false),
                                               client: QiniuClient(send: wire.send, sleep: noWait)).search("q", attempt: 1)
        }
        #expect(wire.all.allSatisfy { $0.hasPrefix("https://api.qnaigc.com/") } && wire.all.count == 3)
    }

    @Test("T-046zh F-18 §45 row 105: the §44 item 2 search and extraction (no fallback configured) fail without a Qwen call")
    func row105() async {
        let wire = Sent { _ in (503, "{}") }
        let qwen = ExtractQwen()
        await #expect(throws: QiniuFailure.self) {
            _ = try await QiniuEventSearcher(key: { "k" }, client: QiniuClient(send: wire.send, sleep: noWait))
                .search("横琴马拉松 2026 时间 地点", timeout: .seconds(45))
        }
        await #expect(throws: QiniuFailure.self) {
            _ = try await QiniuEventExtractor(key: { "k" }, fallback: qwen, client: QiniuClient(send: wire.send, sleep: noWait),
                                              useFallback: false).extract(system: "S", user: "U", timeout: .seconds(60))
        }
        #expect(qwen.calls.withLock { $0 }.isEmpty)
    }
}
