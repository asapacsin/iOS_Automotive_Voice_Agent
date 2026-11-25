import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §35 (T-046x) and §39 (T-046zb): find_events, the keyword searches, the extraction, the checks and the store.

/// Fixed `now`: 2026-11-24 12:00 Asia/Shanghai.
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let noon = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24T04:00:00Z

private func day(_ s: String) -> EventDay { EventDay(s)! }

/// Answers by query text; a query in `failing` throws a timeout.
private final class Searches: EventWebSearcher, Sendable {
    private let asked = Mutex<[String]>([])
    let answer: @Sendable (String) -> EventSearchAnswer
    let failing: Set<String>
    init(failing: Set<String> = [], _ answer: @escaping @Sendable (String) -> EventSearchAnswer = { _ in EventSearchAnswer(text: "", sources: []) }) {
        self.answer = answer
        self.failing = failing
    }
    var queries: [String] { asked.withLock { $0 } }
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        asked.withLock { $0.append(query) }
        if failing.contains(query) { throw WebSearchError.timeout }
        return answer(query)
    }
}

private final class Extract: EventExtractor, Sendable {
    private let calls = Mutex<[String]>([])
    let json: String
    init(_ json: String) { self.json = json }
    var systems: [String] { calls.withLock { $0 } }
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        calls.withLock { $0.append(system) }
        return EventModelReply(content: json, tokens: 900)
    }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private func request(_ cities: [String] = ["珠海", "澳门"], from: String = "2026-11-25", to: String = "2026-12-31",
                     kinds: String = "") -> EventRequest {
    EventRequest(cities: cities, from: day(from), to: day(to), kinds: kinds, today: day("2026-11-24"))
}

private func finder(_ store: EventStore, _ searcher: Searches, _ extractor: Extract, lines: Lines = Lines(),
                    work: WorkProgressBoard? = nil, steps: Lines? = nil) -> EventFinder {
    EventFinder(store: store, work: work, onLine: lines.add) { onProgress in
        EventSearchRun(searcher: searcher, extractor: extractor, clock: ManualClock(), now: { noon },
                       onProgress: { n, m in
                           steps?.add(FindEventsExecutor.stepProgress(done: n, of: m))
                           onProgress(n, m)
                       }, onLine: lines.add)
    }
}

private func findCall(_ args: JSONValue) -> ToolCall { ToolCall(id: CallID("e1")!, name: "find_events", arguments: args) }

private let acgSource = EventSearchHit(title: "起源ACG动漫展", url: "https://zh.example.com/acg", site: "zh.example.com")

@Suite("T-046zb F-18 §39 events from short searches and one extraction")
struct FindEventsTests {
    @Test("T-046zb F-18 §39 row 48: 珠海+澳门, no kinds: 11 queries (5 kinds × 2 cities, then the Macau English one); 3 cities: past 12 cut and counted")
    func row48() {
        let (q, cut) = EventSearchRun.queries(request())
        #expect(q.count == 11 && cut == 0)
        #expect(q[1].text == "珠海 漫展 ACG 2026年11月 12月")
        #expect(q.prefix(5).map(\.text) == EventSearchRun.defaultKinds.map { "珠海 \($0) 2026年11月 12月" })
        #expect(q[5].text == "澳门 展览展会 2026年11月 12月")
        #expect(q.last == EventQuery(text: "Macau events exhibition concert November 2026", city: "澳门", kind: nil))
        let (q3, cut3) = EventSearchRun.queries(request(["珠海", "澳门", "广州"]))
        #expect(q3.count == 12 && cut3 == 4 && q3.allSatisfy { $0.kind != nil })
        #expect(q3.last?.text == "广州 漫展 ACG 2026年11月 12月")
        // The driver's kinds, split on 、，, and spaces, at most 5; a window of 4 months names only 3.
        let k = EventSearchRun.queries(request(["珠海"], from: "2026-11-25", to: "2027-01-20", kinds: "漫展、音乐，AI,cosplay 美食 灯会")).queries
        #expect(k.map(\.kind) == ["漫展", "音乐", "AI", "cosplay", "美食"])
        #expect(k[0].text == "珠海 漫展 2026年11月 12月 1月")
    }

    @Test("T-046zb F-18 §39 row 49 (unit, NovaCore part): the extraction's system text is the Structured Outputs line, the shape, today and the window; the user message holds each answer and its numbered sources")
    func row49() {
        let r = request()
        #expect(EventSearchRun.system(r) == "Extract the event information. Answer in JSON.\n" + EventSearchRun.shape
                + "\ntoday: 2026-11-24\nfrom: 2026-11-25\nto: 2026-12-31")
        let q = EventQuery(text: "珠海 漫展 ACG 2026年11月 12月", city: "珠海", kind: "漫展 ACG")
        let user = EventSearchRun.user([(q, EventSearchAnswer(text: "起源ACG动漫展12月5日至6日。", sources: [acgSource]))])
        #expect(user == "## 1. 珠海 漫展 ACG 2026年11月 12月\n起源ACG动漫展12月5日至6日。\n[1] 起源ACG动漫展 https://zh.example.com/acg")
    }

    @Test("T-046zb F-18 §39 row 50: an invented URL takes the naming query's first source; outside the window dropped; a duplicate kept once; dropped counted")
    func row50() async throws {
        let searcher = Searches { q in
            q.hasPrefix("珠海 漫展")
                ? EventSearchAnswer(text: "起源ACG动漫展12月5日至6日在珠海香山文化艺术中心。", sources: [acgSource], tokens: 1500)
                : EventSearchAnswer(text: "", sources: [], tokens: 1200)
        }
        let json = #"""
        {"events": [
          {"name": "起源ACG动漫展", "start": "2026-12-05", "end": "2026-12-06", "dates_text": "12月5日至6日", "venue": "珠海香山文化艺术中心", "city": "珠海", "source_url": "https://invented.example/x"},
          {"name": "起源ACG动漫展", "start": "2026-12-05", "end": "2026-12-06", "dates_text": "12月5-6日", "venue": "", "city": "珠海市", "source_url": "https://zh.example.com/acg"},
          {"name": "去年的展", "start": "2025-12-05", "end": "2025-12-06", "dates_text": "", "venue": "", "city": "珠海", "source_url": "https://zh.example.com/acg"},
          {"name": "广州的展", "start": "2026-12-05", "end": "2026-12-06", "dates_text": "", "venue": "", "city": "广州", "source_url": "https://zh.example.com/acg"},
          {"name": "没人提过", "start": "2026-12-05", "end": "2026-12-06", "dates_text": "", "venue": "", "city": "珠海", "source_url": "https://invented.example/y"}
        ]}
        """#
        let lines = Lines()
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let tool = FindEventsExecutor(finder: finder(store, searcher, Extract(json), lines: lines))
        let r = await tool.execute(findCall(["cities": ["珠海", "澳门"], "from": "2026-11-25", "to": "2026-12-31"]))
        #expect(r.ok && r.data["source"] == "search" && r.data["dropped"] == 4, "\(r)")
        guard case .array(let list)? = r.data["events"] else { Issue.record("no events"); return }
        #expect(list.count == 1 && list.first?["source_url"] == "https://zh.example.com/acg")
        #expect(r.data["next"]?.stringValue == FindEventsExecutor.searchNext)
        #expect(r.data["sites"] == JSONValue.array([.string("zh.example.com")]))
        // Item 8's lines.
        let all = lines.all
        #expect(all.first == "events store miss cities=2 kinds=5 window=2026-11-25..2026-12-31")
        #expect(all.contains("events query 2/11 ms=0 ok=yes sources=1 searches=0 tokens=1500 q=珠海 漫展 ACG 2026年11月 12月"))
        #expect(all.contains("events extract ms=0 tokens=900 found=5"))
        #expect(all.last == "events search done ms=0 queries=11 failed=0 kept=1 dropped=4 tokens=\(1500 + 10 * 1200 + 900)")
    }

    @Test("T-046zb F-18 §39 row 51: 珠海 展览展会 searched 2 h ago; a call for 漫展 ACG misses and searches 漫展 only")
    func row51() async throws {
        let at = Mutex(noon.addingTimeInterval(-2 * 3600))
        let store = EventStore(storage: MemoryEventStorage(), now: { at.withLock { $0 } }, zone: { shanghai })
        let e = EventEntry(name: "水产前沿国际展", start: "2026-12-03", end: "2026-12-05", datesText: "", venue: "", city: "珠海",
                           sourceURL: "https://a.example/s", sourceSite: "a.example", fetchedAt: noon)
        await store.record([e], searched: [SearchedPair(city: "珠海", kind: "展览展会", kept: 1)], from: "2026-11-25", to: "2026-12-31")
        at.withLock { $0 = noon }
        let searcher = Searches()
        let f = finder(store, searcher, Extract(#"{"events": []}"#))
        guard case .store = await f.find(request(["珠海"], kinds: "展览展会"), onMiss: { _ in }) else { Issue.record("not a hit"); return }
        #expect(searcher.queries.isEmpty)
        guard case .searched = await f.find(request(["珠海"], kinds: "漫展 ACG"), onMiss: { _ in }) else { Issue.record("not searched"); return }
        #expect(Set(searcher.queries) == ["珠海 漫展 2026年11月 12月", "珠海 ACG 2026年11月 12月"])
    }

    @Test("T-046zb F-18 §39 rows 52-53: a search that kept nothing answers from the store 10 min later (searched_minutes_ago, 「这是10分钟前查到的」, source store), not 40 min later")
    func rows52and53() async throws {
        let at = Mutex(noon)
        let store = EventStore(storage: MemoryEventStorage(), now: { at.withLock { $0 } }, zone: { shanghai })
        let searcher = Searches()
        let said = Mutex<[String]>([])
        let tool = FindEventsExecutor(finder: finder(store, searcher, Extract(#"{"events": []}"#)),
                                      onHandoff: { l in said.withLock { $0.append(l) } })
        let args: JSONValue = ["cities": ["澳门"], "from": "2026-11-25", "to": "2026-11-29", "kinds": "免费展览"]
        let first = await tool.execute(findCall(args))
        #expect(first.ok && first.data["source"] == "search" && searcher.queries.count == 2)
        at.withLock { $0 = noon.addingTimeInterval(10 * 60) }
        let second = await tool.execute(findCall(args))
        #expect(second.ok && second.data["source"] == "store" && second.data["searched_minutes_ago"] == 10)
        #expect(second.data["next"]?.stringValue == "这是10分钟前查到的，" + FindEventsExecutor.searchNext)
        #expect(searcher.queries.count == 2 && said.withLock { $0 } == [FindEventsExecutor.handoffLine])
        at.withLock { $0 = noon.addingTimeInterval(40 * 60) }
        let third = await tool.execute(findCall(args))
        #expect(third.data["source"] == "search" && searcher.queries.count == 4)
    }

    @Test("T-046zb F-18 §39 row 54: 3 of 10 queries time out: the others are used, failed=3, ok; spinner counts 已查n/m; all failed is EVENTS_FAILED")
    func row54() async throws {
        let all = EventSearchRun.queries(request(["珠海", "广州"])).queries.map(\.text)
        #expect(all.count == 10)
        let searcher = Searches(failing: Set(all.prefix(3))) { q in
            EventSearchAnswer(text: q.hasPrefix("珠海 漫展") ? "起源ACG动漫展12月5日至6日。" : "", sources: [acgSource])
        }
        let json = #"{"events": [{"name": "起源ACG动漫展", "start": "2026-12-05", "end": "2026-12-06", "city": "珠海", "source_url": "https://zh.example.com/acg"}]}"#
        let lines = Lines()
        let steps = Lines()
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let tool = FindEventsExecutor(finder: finder(store, searcher, Extract(json), lines: lines, steps: steps))
        let r = await tool.execute(findCall(["cities": ["珠海", "广州"], "from": "2026-11-25", "to": "2026-12-31"]))
        #expect(r.ok && r.data["source"] == "search", "\(r)")
        #expect(lines.all.last?.contains("queries=10 failed=3 kept=1") == true, "\(lines.all)")
        #expect(steps.all.sorted() == (1...10).map { "已查\($0)/10" }.sorted())
        // The failed pairs are not marked: the same call searches them again.
        #expect(await !store.covers(cities: ["珠海"], kinds: EventSearchRun.defaultKinds, from: "2026-11-25", to: "2026-12-31"))

        let none = Searches(failing: Set(all))
        let failed = await FindEventsExecutor(finder: finder(EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai }),
                                                             none, Extract("{}")))
            .execute(findCall(["cities": ["珠海", "广州"], "from": "2026-11-25", "to": "2026-12-31"]))
        #expect(!failed.ok && failed.data["next"]?.stringValue == FindEventsExecutor.failedNext)
    }

    @Test("T-046zb F-18 §39 item 3 (amended 2026-11-25): the system text names JSON; an HTTP 400 at extraction records status and the first 300 chars of the body, EVENTS_FAILED")
    func extractHTTP400() async throws {
        #expect(EventSearchRun.instruction == "Extract the event information. Answer in JSON.")
        struct Refuses: EventExtractor {
            func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
                throw EventExtractError.http(status: 400, body: #"{"code":"InvalidParameter","message":"'messages' must contain the word 'json'"}"# + String(repeating: "x", count: 400))
            }
        }
        let lines = Lines()
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let f = EventFinder(store: store, work: nil, onLine: lines.add) { _ in
            EventSearchRun(searcher: Searches { _ in EventSearchAnswer(text: "a", sources: [acgSource]) }, extractor: Refuses(),
                           clock: ManualClock(), now: { noon }, onLine: lines.add)
        }
        let r = await FindEventsExecutor(finder: f).execute(findCall(["cities": ["珠海"], "from": "2026-11-25", "to": "2026-11-29"]))
        #expect(!r.ok && r.data["next"]?.stringValue == FindEventsExecutor.failedNext)
        let line = lines.all.first { $0.hasPrefix("events extract failed ") } ?? ""
        #expect(line.hasPrefix(#"events extract failed status=400 body={"code":"InvalidParameter""#))
        #expect(line.count == "events extract failed status=400 body=".count + 300)
    }

    @Test("T-046x F-18 §35 row 29: from yesterday, to 90 days out, a province: each refused naming the field")
    func row29() {
        let today = day("2026-11-24")
        #expect(FindEventsExecutor.refusal(["cities": ["珠海"], "from": "2026-11-23", "to": "2026-11-29"], today: today) == "from")
        #expect(FindEventsExecutor.refusal(["cities": ["珠海"], "from": "2026-11-25", "to": "2027-02-22"], today: today) == "to")
        #expect(FindEventsExecutor.refusal(["cities": ["广东省"], "from": "2026-11-25", "to": "2026-11-29"], today: today) == "cities")
        #expect(FindEventsExecutor.refusal(["cities": ["广东"], "from": "2026-11-25", "to": "2026-11-29"], today: today) == "cities")
        #expect(FindEventsExecutor.refusal(["cities": ["珠海", "澳门"], "from": "2026-11-25", "to": "2026-11-29"], today: today) == nil)
    }

    @Test("T-046zb F-18 §39 items 5, 7: a store file without kinds never answers; the handoff line and spinner texts")
    func storeAndTexts() async throws {
        let old = #"{"version":1,"events":[],"windows":[{"city":"珠海","from":"2026-11-24","to":"2026-12-24","at":"2026-11-24T03:00:00Z"}]}"#
        let store = EventStore(storage: MemoryEventStorage(Data(old.utf8)), now: { noon }, zone: { shanghai })
        #expect(await store.stale(["珠海"]) == ["珠海"])
        #expect(FindEventsExecutor.handoffLine == "好，我查一下这几天的活动，半分钟左右。")
        #expect(FindEventsExecutor.stepStart == "正在查活动" && FindEventsExecutor.stepProgress(done: 3, of: 11) == "已查3/11")
    }

    @Test("T-046x F-18 §35 item 1: declared only with search on; NON_BLOCKING; EventCity reads a regeo address")
    func catalog() {
        #expect(!ToolCatalog.declarations(webSearch: false).contains { $0.name == "find_events" })
        let d = ToolCatalog.declarations(webSearch: true).first { $0.name == "find_events" }
        #expect(d?.parametersJSONSchema["required"] == ["cities", "from", "to"])
        #expect(AsyncTool(name: "find_events") == .findEvents)
        #expect(ToolCatalog.validate(ToolCall(id: CallID("v")!, name: "find_events", arguments: ["cities": ["珠海"]])) == .invalidFields)
        #expect(EventCity.from(address: "广东省珠海市香洲区情侣中路") == "珠海")
        #expect(EventCity.from(address: "澳门特别行政区") == "澳门")
        #expect(EventCity.from(address: "广东省") == nil)
    }
}
