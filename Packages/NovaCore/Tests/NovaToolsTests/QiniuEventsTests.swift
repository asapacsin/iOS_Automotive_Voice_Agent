import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §42 item 4 (T-046ze): the Qiniu events path in NovaCore (queries, extraction message, numbered sources, store marks).

private let noon = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24T04:00:00Z

private func day(_ s: String) -> EventDay { EventDay(s)! }
private func request(_ cities: [String] = ["珠海", "澳门"], from: String = "2026-11-25", to: String = "2026-12-31",
                     kinds: String = "") -> EventRequest {
    EventRequest(cities: cities, from: day(from), to: day(to), kinds: kinds, today: day("2026-11-24"))
}

private final class QSearches: EventWebSearcher, Sendable {
    private let asked = Mutex<[String]>([])
    let failing: Set<String>
    let answer: @Sendable (String) -> EventSearchAnswer
    init(failing: Set<String> = [], _ answer: @escaping @Sendable (String) -> EventSearchAnswer) {
        self.failing = failing
        self.answer = answer
    }
    var queries: [String] { asked.withLock { $0 } }
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        asked.withLock { $0.append(query) }
        if failing.contains(query) { throw WebSearchError.http(429, code: nil) }
        return answer(query)
    }
}

private final class QExtract: EventExtractor, Sendable {
    private let seen = Mutex<[(String, String, NovaDuration)]>([])
    let json: String
    init(_ json: String) { self.json = json }
    var calls: [(String, String, NovaDuration)] { seen.withLock { $0 } }
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        seen.withLock { $0.append((system, user, timeout)) }
        return EventModelReply(content: json, tokens: 16500)
    }
}

private final class QLines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private let vac = EventSearchHit(title: "VAC 2026 澳门动漫节", url: "https://m.example.com/vac", site: "m.example.com",
                                 snippet: "12月12日至14日在澳门威尼斯人举行", date: "2026-11-20")
private let air = EventSearchHit(title: "珠海航展", url: "https://z.example.com/air", site: "z.example.com",
                                 snippet: String(repeating: "航", count: 400), date: "2026-11-17")

@Suite("T-046ze F-18 §42 events on Qiniu (NovaCore)")
struct QiniuEventsTests {
    @Test("T-046ze F-18 §42 row 68: 珠海+澳门, no kinds: 3 queries naming both cities, the kind groups, no English query")
    func row68() {
        let q = EventSearchRun.qiniuQueries(request())
        #expect(q.map(\.text) == ["珠海 澳门 2026年11月 12月 展览展会 科技展", "珠海 澳门 2026年11月 12月 演唱会 演出",
                                  "珠海 澳门 2026年11月 12月 漫展 节庆 嘉年华"])
        #expect(q.allSatisfy { $0.cities == ["珠海", "澳门"] && !$0.text.contains("Macau") })
        // The groups cover every default kind once, so the store's city × kind marks stay complete.
        #expect(Set(q.flatMap(\.covers)) == Set(EventSearchRun.defaultKinds) && q.flatMap(\.covers).count == 5)
    }

    @Test("T-046ze F-18 §42 row 69: kinds 「漫展、音乐」, 澳门: 2 queries; kinds 4-5 appended to queries 1-2")
    func row69() {
        let q = EventSearchRun.qiniuQueries(request(["澳门"], from: "2026-11-25", to: "2026-11-30", kinds: "漫展、音乐"))
        #expect(q.map(\.text) == ["澳门 2026年11月 漫展", "澳门 2026年11月 音乐"])
        let five = EventSearchRun.qiniuQueries(request(["澳门"], from: "2026-11-25", to: "2026-11-30", kinds: "漫展、音乐，AI,美食 灯会"))
        #expect(five.map(\.text) == ["澳门 2026年11月 漫展 美食", "澳门 2026年11月 音乐 灯会", "澳门 2026年11月 AI"])
        #expect(five[0].covers == ["漫展", "美食"])
    }

    @Test("T-046ze F-18 §42 row 70 (NovaCore part): results deduplicated by url, numbered, `[n] <date> <title> — <content 300> (<url>)`")
    func row70() {
        let q1 = EventSearchRun.qiniuQueries(request())[0], q2 = EventSearchRun.qiniuQueries(request())[1]
        let user = EventSearchRun.qiniuUser([(q1, EventSearchAnswer(text: "", sources: [vac, air])),
                                             (q2, EventSearchAnswer(text: "", sources: [air]))])
        let lines = user.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "[1] 2026-11-20 VAC 2026 澳门动漫节 — 12月12日至14日在澳门威尼斯人举行 (https://m.example.com/vac)")
        #expect(lines[1] == "[2] 2026-11-17 珠海航展 — \(String(repeating: "航", count: 300)) (https://z.example.com/air)")
    }

    @Test("T-046ze F-18 §42 rows 68, 71: three queries at once, one 429 failed and not retried, the others used; source_url by result number; 60 s extraction; store marks every city × kind")
    func run() async throws {
        let qs = EventSearchRun.qiniuQueries(request())
        let searcher = QSearches(failing: [qs[2].text]) { q in
            q == qs[0].text ? EventSearchAnswer(text: "", sources: [air], tokens: 0, searches: 1)
                            : EventSearchAnswer(text: "", sources: [vac], tokens: 0, searches: 1)
        }
        let json = #"""
        {"events": [
          {"name": "珠海航展", "start": "2026-11-26", "end": "2026-11-29", "dates_text": "", "venue": "", "city": "珠海", "source_url": "1"},
          {"name": "VAC 2026", "start": "2026-12-12", "end": "2026-12-14", "dates_text": "", "venue": "", "city": "澳门", "source_url": "[2]"}
        ]}
        """#
        let extractor = QExtract(json)
        let lines = QLines()
        let out = try await EventSearchRun(searcher: searcher, extractor: extractor, clock: ManualClock(), mode: .qiniu,
                                           now: { noon }, onLine: lines.add).run(request())
        #expect(Set(searcher.queries) == Set(qs.map(\.text)) && searcher.queries.count == 3)
        #expect(out.queries == 3 && out.failed == 1 && out.cut == 0)
        #expect(out.kept.map(\.sourceURL) == ["https://z.example.com/air", "https://m.example.com/vac"])
        let call = try #require(extractor.calls.first)
        #expect(call.0 == EventSearchRun.system(request(), qiniu: true) && call.2 == .seconds(60) && call.1.hasPrefix("[1] 2026-11-17 珠海航展"))
        #expect(lines.all.first == "events provider=qiniu queries=3")
        #expect(lines.all.contains { $0.hasPrefix("events query 3/3 ") && $0.contains("ok=no") })
        // The two queries that ran mark both cities × their kinds; the failed group's kinds are not marked.
        let marked = Set(out.searched.map { "\($0.city)|\($0.kind)" })
        #expect(marked == Set(["珠海|展览展会", "澳门|展览展会", "珠海|AI 科技展", "澳门|AI 科技展", "珠海|演唱会 演出", "澳门|演唱会 演出"]))
        #expect(out.searched.first { $0.city == "珠海" && $0.kind == "展览展会" }?.kept == 1)
    }
}
