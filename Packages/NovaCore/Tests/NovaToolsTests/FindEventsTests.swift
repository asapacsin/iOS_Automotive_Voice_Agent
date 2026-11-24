import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §35 (T-046x): find_events, the browse loop, the page excerpt, the date check and the event store.

private let bendibao = """
<html><head><title>2026横琴人工智能大赛AI嘉年华时间+地点 - 珠海本地宝</title><script>var x="11月1日";</script></head><body>
<h1>2026横琴人工智能大赛AI嘉年华</h1>
<p>导语：一起来玩</p>
<p>➤活动时间：11月28日-29日 ➤活动地点：珠海国际会展中心7-8号馆</p>
<p>门票：免费</p>
<p>交通：公交</p>
<a href="https://zh.bendibao.com/news/ai.shtm">更多活动</a>
</body></html>
"""

/// Fixed `now`: 2026-11-24 12:00 Asia/Shanghai.
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let noon = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24T04:00:00Z

private func day(_ s: String) -> EventDay { EventDay(s)! }

private final class Script: EventChatModel, @unchecked Sendable {
    var replies: [EventChatReply]
    var turns = 0
    var lastMessages: [EventChatMessage] = []
    var history: [[EventChatMessage]] = []
    init(_ replies: [EventChatReply]) { self.replies = replies }
    func turn(_ messages: [EventChatMessage], tools: Bool, timeout: NovaDuration) async throws -> EventChatReply {
        turns += 1
        lastMessages = messages
        history.append(messages)
        guard !replies.isEmpty else { return EventChatReply(content: "") }
        return replies.removeFirst()
    }
}

private struct Hits: EventSearcher {
    func search(_ query: String) async throws -> [EventSearchHit] {
        [EventSearchHit(title: "AI嘉年华", url: "https://zh.bendibao.com/a.shtm", site: "zh.bendibao.com")]
    }
}

private final class Pages: EventPageFetcher, @unchecked Sendable {
    let pages: [String: String]
    var opened = 0
    init(_ pages: [String: String]) { self.pages = pages }
    func open(_ url: String) async throws -> String {
        opened += 1
        guard let p = pages[url] else { throw URLError(.badServerResponse) }
        return p
    }
}

private func call(_ name: String, _ args: String, id: String = "c1") -> EventToolCall {
    EventToolCall(id: id, name: name, arguments: args)
}

private func request(_ cities: [String] = ["珠海", "澳门"], from: String = "2026-11-25", to: String = "2026-11-29") -> EventBrowseRequest {
    EventBrowseRequest(cities: cities, from: day(from), to: day(to), kinds: "AI、漫展", today: day("2026-11-24"))
}

private let finalJSON = #"""
{"events":[{"name":"2026横琴人工智能大赛AI嘉年华","start":"2026-11-28","end":"2026-11-29","dates_text":"11月28日-29日","venue":"珠海国际会展中心7-8号馆","city":"珠海","source_url":"https://zh.bendibao.com/a.shtm"},
{"name":"珠海·AS动漫游园会SP","start":"2026-11-28","end":"2026-11-28","dates_text":"11月28日","venue":"","city":"珠海","source_url":"https://www.douyin.com/x"}],"note":""}
"""#

@Suite("T-046x F-18 §35 find_events")
struct FindEventsTests {
    @Test("T-046x F-18 §35 row 24: an event whose opened page states its dates is kept; one without is dropped")
    func row24() async throws {
        let model = Script([
            EventChatReply(content: "", toolCalls: [call("search", #"{"query":"珠海 AI 活动 11月"}"#)], tokens: 1000),
            EventChatReply(content: "", toolCalls: [call("open_page", #"{"url":"https://zh.bendibao.com/a.shtm"}"#, id: "c2")], tokens: 2000),
            EventChatReply(content: finalJSON, tokens: 3000),
        ])
        let pages = Pages(["https://zh.bendibao.com/a.shtm": bendibao])
        let lines = Mutex<[String]>([])
        let loop = EventBrowseLoop(model: model, searcher: Hits(), fetcher: pages, clock: ManualClock(), now: { noon },
                                   onLine: { l in lines.withLock { $0.append(l) } })
        let out = try await loop.run(request())
        #expect(out.kept.count == 1)
        #expect(out.kept.first?.start == "2026-11-28" && out.kept.first?.end == "2026-11-29")
        #expect(out.kept.first?.city == "珠海" && out.kept.first?.sourceSite == "zh.bendibao.com")
        #expect(out.dropped == 1)
        #expect(out.tokens == 6000 && out.steps == 2)
        #expect(lines.withLock { $0 }.contains("events browse done steps=2 ms=0 tokens=6000 found=2 kept=1 dropped=1"))
    }

    @Test("T-046x F-18 §35 row 25: the parser reads each item 6 form, with and without a year on the page")
    func row25() {
        let cases: [(String, String, String)] = [
            ("2026年11月28日", "2026-11-28", "2026-11-28"),
            ("11月28日", "2026-11-28", "2026-11-28"),
            ("11月28日-29日", "2026-11-28", "2026-11-29"),
            ("11月28日至12月12日", "2026-11-28", "2026-12-12"),
            ("11.28-29", "2026-11-28", "2026-11-29"),
            ("2026-11-28", "2026-11-28", "2026-11-28"),
            ("11/28", "2026-11-28", "2026-11-28"),
        ]
        for (text, start, end) in cases {
            #expect(EventDates.ranges(in: "活动时间：\(text)", defaultYear: 2026).contains(.init(start: day(start), end: day(end))), "\(text)")
        }
        // The page's own year wins over the window's.
        #expect(EventDates.onPage("发布于2027年1月2日\n活动时间：11月28日", start: day("2027-11-28"), end: day("2027-11-28"), windowYear: 2026))
        #expect(!EventDates.onPage("活动时间：11月28日", start: day("2026-11-27"), end: day("2026-11-28"), windowYear: 2026))
    }

    @Test("T-046x F-18 §35 row 26: a fresh store answers at once: source store, no network, no handoff line")
    func row26() async throws {
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let entry = EventEntry(name: "AI嘉年华", start: "2026-11-28", end: "2026-11-29", datesText: "11月28日-29日", venue: "会展中心",
                               city: "珠海", sourceURL: "https://zh.bendibao.com/a.shtm", sourceSite: "zh.bendibao.com", fetchedAt: noon)
        await store.replace(city: "珠海", from: "2026-11-24", to: "2026-12-24", with: [entry])
        let model = Script([])
        let browser = EventBrowser(store: store, work: nil) { _ in
            EventBrowseLoop(model: model, searcher: Hits(), fetcher: Pages([:]), clock: ManualClock())
        }
        let said = Mutex<[String]>([])
        let tool = FindEventsExecutor(browser: browser, onHandoff: { l in said.withLock { $0.append(l) } })
        let r = await tool.execute(ToolCall(id: CallID("e1")!, name: "find_events",
                                            arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"]))
        #expect(r.ok && r.data["source"] == "store")
        guard case .array(let list)? = r.data["events"] else { Issue.record("no events"); return }
        #expect(list.first?["name"] == "AI嘉年华")
        #expect(model.turns == 0 && said.withLock { $0 }.isEmpty)
    }

    @Test("T-046x F-18 §35 row 27: a browse 30 h old runs the loop; spinner steps change; the store is updated")
    func row27() async throws {
        let at = Mutex(noon.addingTimeInterval(-30 * 3600))
        let store = EventStore(storage: MemoryEventStorage(), now: { at.withLock { $0 } }, zone: { shanghai })
        await store.replace(city: "珠海", from: "2026-11-23", to: "2026-12-23", with: [])
        at.withLock { $0 = noon }
        let model = Script([
            EventChatReply(content: "", toolCalls: [call("search", #"{"query":"珠海 活动"}"#)]),
            EventChatReply(content: "", toolCalls: [call("open_page", #"{"url":"https://zh.bendibao.com/a.shtm"}"#, id: "c2")]),
            EventChatReply(content: finalJSON),
        ])
        let steps = Mutex<[String]>([])
        let board = WorkProgressBoard(clock: ManualClock())
        let browser = EventBrowser(store: store, work: board) { onStep in
            EventBrowseLoop(model: model, searcher: Hits(), fetcher: Pages(["https://zh.bendibao.com/a.shtm": bendibao]),
                            clock: ManualClock(), now: { noon }, onStep: { s, p in
                                steps.withLock { $0.append(FindEventsExecutor.stepProgress(searches: s, pages: p)) }
                                onStep(s, p)
                            })
        }
        let said = Mutex<[String]>([])
        let tool = FindEventsExecutor(browser: browser, onHandoff: { l in said.withLock { $0.append(l) } })
        let r = await tool.execute(ToolCall(id: CallID("e2")!, name: "find_events",
                                            arguments: ["cities": ["珠海"], "from": "2026-11-28", "to": "2026-11-29"]))
        #expect(r.ok && r.data["source"] == "browse" && r.data["dropped"] == 1)
        #expect(steps.withLock { $0 } == ["已搜索1次，读了0个页面", "已搜索1次，读了1个页面"])
        #expect(said.withLock { $0 } == [FindEventsExecutor.handoffLine])
        #expect(await store.all.map(\.name) == ["2026横琴人工智能大赛AI嘉年华"])
        #expect(await store.covers(cities: ["珠海"], from: "2026-11-28", to: "2026-11-29"))
    }

    @Test("T-046x F-18 §35 row 28: 12 calls without an answer: EVENTS_FAILED, item 7's next, failed reason=timeout")
    func row28() async {
        let model = Script((0..<13).map { n in EventChatReply(content: "", toolCalls: [call("search", #"{"query":"q"}"#, id: "c\(n)")]) })
        let lines = Mutex<[String]>([])
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let browser = EventBrowser(store: store, work: nil) { _ in
            EventBrowseLoop(model: model, searcher: Hits(), fetcher: Pages([:]), clock: ManualClock(), now: { noon },
                            onLine: { l in lines.withLock { $0.append(l) } })
        }
        let r = await FindEventsExecutor(browser: browser).execute(ToolCall(id: CallID("e3")!, name: "find_events",
            arguments: ["cities": ["珠海"], "from": "2026-11-25", "to": "2026-11-29"]))
        #expect(!r.ok && r.code == .eventsFailed && r.data["next"] == .string(FindEventsExecutor.failedNext))
        #expect(lines.withLock { $0 }.filter { $0.hasPrefix("events browse step=") }.count == EventBrowseLoop.maxCalls)
        #expect(lines.withLock { $0 }.last == "events failed reason=timeout")
        // 12 tool turns, then the one final ask.
        #expect(model.turns == 13)
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

    @Test("T-046x F-18 §35 row 30: the excerpt keeps the date line and its neighbours; a read page becomes （已读：…）")
    func row30() async throws {
        let page = PageText(html: bendibao)
        #expect(page.excerpt.contains("➤活动时间：11月28日-29日"))
        #expect(page.excerpt.contains("导语：一起来玩") && page.excerpt.contains("门票：免费"))
        #expect(!page.excerpt.contains("交通：公交") && !page.excerpt.contains("var x"))
        #expect(page.excerpt.count <= PageText.maxExcerpt)
        let long = PageText(title: "t", lines: (0..<400).map { "第\($0)行 11月\($0 % 28 + 1)日 " + String(repeating: "字", count: 20) })
        #expect(long.excerpt.count <= PageText.maxExcerpt)
        // Read pages collapse after the next model turn.
        let model = Script([
            EventChatReply(content: "", toolCalls: [call("open_page", #"{"url":"https://zh.bendibao.com/a.shtm"}"#)]),
            EventChatReply(content: "", toolCalls: [call("search", #"{"query":"澳门 活动"}"#, id: "c2")]),
            EventChatReply(content: finalJSON),
        ])
        let loop = EventBrowseLoop(model: model, searcher: Hits(), fetcher: Pages(["https://zh.bendibao.com/a.shtm": bendibao]),
                                   clock: ManualClock(), now: { noon })
        _ = try await loop.run(request())
        #expect(model.history[1].last?.content.contains("11月28日-29日") == true)
        #expect(model.history[2].contains { $0.role == .tool && $0.content == "（已读：https://zh.bendibao.com/a.shtm）" })
        #expect(!model.history[2].contains { $0.content.contains("11月28日-29日") && $0.role == .tool })
    }

    @Test("T-046x F-18 §35 item 1: declared only with search on; NON_BLOCKING; the system text cites ReAct")
    func catalog() {
        #expect(!ToolCatalog.declarations(webSearch: false).contains { $0.name == "find_events" })
        let d = ToolCatalog.declarations(webSearch: true).first { $0.name == "find_events" }
        #expect(d?.parametersJSONSchema["required"] == ["cities", "from", "to"])
        #expect(AsyncTool(name: "find_events") == .findEvents)
        #expect(ToolCatalog.validate(ToolCall(id: CallID("v")!, name: "find_events", arguments: ["cities": ["珠海"]])) == .invalidFields)
        #expect(EventBrowseLoop.system(request()).hasPrefix(EventBrowseLoop.reactInstruction))
        #expect(EventCity.from(address: "广东省珠海市香洲区情侣中路") == "珠海")
        #expect(EventCity.from(address: "澳门特别行政区") == "澳门")
        #expect(EventCity.from(address: "广东省") == nil)
    }
}
