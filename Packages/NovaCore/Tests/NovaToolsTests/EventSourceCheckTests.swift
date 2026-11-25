import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §44 (T-046zg): an event's venue and dates only when a source states them; one search for what is missing;
// otherwise 「未找到」; start time and ticket note from the source text.

private let noon = Date(timeIntervalSince1970: 1_795_579_200)  // 2026-11-25
private func day(_ s: String) -> EventDay { EventDay(s)! }
private func text(_ body: String, title: String = "") -> EventSourceCheck.Text { EventSourceCheck.Text(title: title, body: body) }
private let zm = ["珠海", "澳门"]

private final class Searches: EventWebSearcher, Sendable {
    private let asked = Mutex<[String]>([])
    let answer: @Sendable (String) -> EventSearchAnswer
    init(_ answer: @escaping @Sendable (String) -> EventSearchAnswer) { self.answer = answer }
    var queries: [String] { asked.withLock { $0 } }
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        asked.withLock { $0.append(query) }
        return answer(query)
    }
}

/// Answers by call order.
private final class Extract: EventExtractor, Sendable {
    private let seen = Mutex<[String]>([])
    let replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    var users: [String] { seen.withLock { $0 } }
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        let n = seen.withLock { $0.append(user); return $0.count }
        return EventModelReply(content: replies[min(n, replies.count) - 1], tokens: 1)
    }
}

private final class Pages: EventPageSource, Sendable {
    let html: [String: String]
    private let fetched = Mutex<[String]>([])
    init(_ html: [String: String]) { self.html = html }
    var pages: [String] { fetched.withLock { $0 } }
    func page(_ url: String) async -> String? {
        fetched.withLock { $0.append(url) }
        return html[url]
    }
    func images(_ query: String) async throws -> [EventImageHit] { [] }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private func request(from: String = "2026-11-25", to: String = "2026-12-31") -> EventRequest {
    EventRequest(cities: zm, from: day(from), to: day(to), kinds: "", today: day("2026-11-25"))
}

@Suite("T-046zg F-18 §44 venue, dates, time and ticket only from the source")
struct EventSourceCheckTests {
    @Test("T-046zg F-18 §44 row 87: 「…AI嘉年华… ➤活动地点 ：珠海国际会展中心7-8号馆」: venue 「横琴」 → none; 「珠海国际会展中心」 kept")
    func row87() {
        let t = [text("2026横琴人工智能大赛AI嘉年华 免费参与 ➤活动地点 ：珠海国际会展中心7-8号馆")]
        #expect(EventSourceCheck.venue("横琴", in: t, cities: zm).isEmpty)
        #expect(EventSourceCheck.venue("珠海国际会展中心", in: t, cities: zm) == ["珠海国际会展中心"])
    }

    @Test("T-046zg F-18 §44 row 88: 「➤活动地点 ：广东珠海横琴长隆度假区(5号停车场)」, venue 「横琴长隆度假区」, cities 珠海, 澳门: kept")
    func row88() {
        let t = [text("VAC电音节 ➤活动地点 ：广东珠海横琴长隆度假区(5号停车场)")]
        #expect(EventSourceCheck.venue("横琴长隆度假区", in: t, cities: zm) == ["横琴长隆度假区"])
        // Not after a place word: dropped; the split keeps each part on its own.
        #expect(EventSourceCheck.venueParts("A馆；B馆;C馆、D馆/E馆") == ["A馆", "B馆", "C馆", "D馆", "E馆"])
    }

    @Test("T-046zg F-18 §44 row 89: 「第十六届中国航展将于2026年12月7日至13日在广东珠海举办」; venue 「珠海国际航展中心」, 12-07…12-13: no venue, dates kept")
    func row89() {
        let t = [text("第十六届中国航展将于2026年12月7日至13日在广东珠海举办")]
        #expect(EventSourceCheck.venue("珠海国际航展中心", in: t, cities: zm).isEmpty)
        #expect(EventSourceCheck.dates(start: day("2026-12-07"), end: day("2026-12-13"), in: t))
    }

    @Test("T-046zg F-18 §44 row 90: 「2026AIE电子展将于12月3日至5日在澳门、珠海同步举办」; end 12-06 → no dates; 12-05 → kept")
    func row90() {
        let t = [text("2026AIE电子展将于12月3日至5日在澳门、珠海同步举办")]
        #expect(!EventSourceCheck.dates(start: day("2026-12-03"), end: day("2026-12-06"), in: t))
        #expect(EventSourceCheck.dates(start: day("2026-12-03"), end: day("2026-12-05"), in: t))
        // The other forms: MM-DD, M.D, YYYY.MM.DD, English month.
        #expect(EventSourceCheck.dates(start: day("2026-12-03"), end: day("2026-12-03"), in: [text("2026-12-03 开幕")]))
        #expect(EventSourceCheck.dates(start: day("2026-12-03"), end: day("2026-12-05"), in: [text("2026 展期 12.3-12.5")]))
        #expect(EventSourceCheck.dates(start: day("2026-12-05"), end: day("2027-01-10"), in: [text("光影节 2026.12.05–2027.01.10")]))
        #expect(EventSourceCheck.dates(start: day("2026-12-27"), end: day("2026-12-27"), in: [text("Race day December 27", title: "Marathon 2026")]))
    }

    @Test("T-046zg F-18 §44 row 91: item 2: result 1's page names no hall, result 2 「…将于12月7日至13日在珠海国际航展中心举办」; venue 「珠海国际航展中心；珠海国际会展中心」: 航展中心 kept, record venue=search, one search, one model call")
    func row91() async throws {
        let first = EventSearchHit(title: "第十六届中国航展 门票", url: "https://a.example.com/1", site: "", snippet: "中国航展在珠海举办", date: "2026-11-20")
        let second = EventSearchHit(title: "第十六届中国航展", url: "https://b.example.com/2", site: "",
                                    snippet: "2026年第十六届中国航展将于12月7日至13日在珠海国际航展中心举办", date: "2026-11-21")
        let source = EventSearchHit(title: "第十六届中国航展", url: "https://s.example.com/air", site: "",
                                    snippet: "第十六届中国航展将于2026年12月7日至13日在广东珠海举办", date: "2026-11-17")
        let searcher = Searches { q in
            q.hasSuffix("时间 地点") ? EventSearchAnswer(text: "", sources: [first, second]) : EventSearchAnswer(text: "", sources: [source])
        }
        let extract = Extract([
            #"{"events":[{"name":"第十六届中国航展","start":"2026-12-07","end":"2026-12-13","venue":"珠海国际航展中心","city":"珠海","source_url":"1"}]}"#,
            #"{"events":[{"name":"第十六届中国航展","start":"2026-12-07","end":"2026-12-13","venue":"珠海国际航展中心；珠海国际会展中心","city":"珠海","source_url":"2"}]}"#,
        ])
        let pages = Pages(["https://a.example.com/1": "<html><title>航展</title><body>第十六届中国航展 在珠海举办</body></html>"])
        let lines = Lines()
        let out = try await EventSearchRun(searcher: searcher, extractor: extract, clock: ManualClock(), mode: .qiniu, pages: pages,
                                           now: { noon }, onLine: lines.add).run(request())
        let e = try #require(out.kept.first)
        #expect(e.venue == "珠海国际航展中心" && e.venueVia == "search" && e.datesVia == "page")
        #expect(searcher.queries.filter { $0 == "第十六届中国航展 2026 时间 地点" }.count == 1 && extract.users.count == 2)
        #expect(extract.users[1].hasPrefix("[1] 2026-11-20 第十六届中国航展 门票"))
        #expect(pages.pages == ["https://s.example.com/air", "https://a.example.com/1"])
        #expect(lines.all.contains("events check name=第十六届中国航展 venue=search dates=page image=none time=none ticket=none"))
        #expect(e.factsText == "场馆：珠海国际航展中心；日期：2026-12-07–2026-12-13")
    }

    @Test("T-046zg F-18 §44 row 91a: item 2 finds nothing confirmed: find_events text 「场馆：未找到」; card 「场馆未找到」 + city; no map query, no navigation")
    func row91a() async throws {
        let source = EventSearchHit(title: "2026横琴马拉松", url: "https://s.example.com/run", site: "", snippet: "2026横琴马拉松 12月27日 开跑",
                                    date: "2026-11-01")
        let old = EventSearchHit(title: "2026横琴马拉松 路线", url: "https://o.example.com/2025", site: "",
                                 snippet: "2025横琴马拉松起点在横琴金融岛中央公园", date: "2025-12-01")
        let searcher = Searches { q in EventSearchAnswer(text: "", sources: q.hasSuffix("时间 地点") ? [old] : [source]) }
        let json = #"{"events":[{"name":"2026横琴马拉松","start":"2026-12-27","end":"2026-12-27","venue":"横琴金融岛中央公园","city":"珠海","source_url":"1"}]}"#
        // Item 2's extraction reads last year's race from the old page.
        let lastYear = #"{"events":[{"name":"2025横琴马拉松","start":"2025-12-28","end":"2025-12-28","venue":"横琴金融岛中央公园","city":"珠海","source_url":"1"}]}"#
        let out = try await EventSearchRun(searcher: searcher, extractor: Extract([json, lastYear]), clock: ManualClock(), mode: .qiniu,
                                           pages: Pages([:]), now: { noon }).run(request())
        let e = try #require(out.kept.first)
        #expect(e.venueVia == "none" && e.venue.isEmpty && e.datesVia == "page")
        #expect(e.factsText == "场馆：未找到；日期：2026-12-27–2026-12-27")
        // Nothing confirmed at all: both fields still given.
        var bare = e
        bare.datesVia = "none"
        #expect(bare.factsText == "场馆：未找到；日期：未找到")
        #expect(e.json["facts"] == .string(e.factsText) && e.json["venue"] == nil && e.json["start"] == nil)
        #expect(e.venueCardText == "场馆未找到 · 珠海" && bare.datesCardText == "日期未找到" && e.mapQuery == nil)
    }

    @Test("T-046zg F-18 §44 row 91b: an event with no picture: card 「未找到图片」; the tool result says 「未找到这个活动的图片」")
    func row91b() {
        let e = EventEntry(name: "AIE", start: "2026-12-03", end: "2026-12-05", datesText: "", venue: "", city: "澳门", sourceURL: "u",
                           sourceSite: "", fetchedAt: noon)
        #expect(e.imageCardText == "未找到图片" && e.json["image"] == "未找到这个活动的图片" && e.json["image_url"] == nil)
        var withPicture = e
        withPicture.imageURL = "https://p.example.com/a.jpg"
        #expect(withPicture.imageCardText == nil && withPicture.json["image"] == nil)
    }

    @Test("T-046zg F-18 §44 row 95: 「…2025年11月28日（六）在伦敦人综艺馆举行… © 2026」, model start 2026-11-28: dates none")
    func row95() {
        let page = EventSourceCheck.page("<html><head><title>韦礼安演唱会</title></head><body><p>演唱会于2025年11月28日（六）在伦敦人综艺馆举行</p><footer>© 2026 某网</footer></body></html>")
        #expect(page.title == "韦礼安演唱会" && page.body.contains("© 2026"))
        #expect(!EventSourceCheck.dates(start: day("2026-11-28"), end: day("2026-11-28"), in: [page]))
        // The year right before the day, or in the title, counts.
        #expect(EventSourceCheck.dates(start: day("2026-11-28"), end: day("2026-11-28"), in: [text("11月28日（六）举行", title: "2026 演唱会")]))
    }

    @Test("T-046zg F-18 §44 row 96: LINGORM page text, model time 16:00 → kept; 19:00 → none")
    func row96() {
        let t = [text("LINGORM 澳门粉丝见面会 2026年12月6日（星期日）下午4时 伦敦人综艺馆")]
        #expect(EventSourceCheck.time("16:00", in: t) == "16:00")
        #expect(EventSourceCheck.time("19:00", in: t) == nil)
        #expect(EventSourceCheck.time("20:00", in: [text("晚上8时开始")]) == "20:00")
        #expect(EventSourceCheck.time("10:00", in: [text("活动 10:00 开始")]) == "10:00" && EventSourceCheck.time("10:00", in: [text("110:00")]) == nil)
        #expect(EventSourceCheck.time("19:30", in: [text("19点30入场")]) == "19:30")
    }

    @Test("T-046zg F-18 §44 row 97: 韦礼安 page (「门票火速售罄」 in another story's line; 「2026年12月12日…公开发售」): ticket 需购票 only")
    func row97() {
        let other = "上一场演唱会门票火速售罄，" + String(repeating: "。", count: 320)
        let t = [text(other + "韦礼安演唱会将于2026年12月12日在伦敦人综艺馆举行，门票于11月28日公开发售")]
        #expect(EventSourceCheck.ticket(start: day("2026-12-12"), in: t, today: day("2026-11-25")) == ["需购票"])
        #expect(EventSourceCheck.ticket(start: day("2026-11-28"), in: [text("2026横琴AI嘉年华 11月28日 免费参与，需提前预约")],
                                        today: day("2026-11-25")) == ["免费", "需预约"])
    }

    @Test("T-046zg F-18 §44 row 98: 「…December 27… Registration will close at 10:00 p.m. on September 12」, today 2026-11-25: 报名已截止")
    func row98() {
        let t = [text("Hengqin Marathon 2026 will be held on December 27. Registration will close at 10:00 p.m. on September 12.")]
        #expect(EventSourceCheck.ticket(start: day("2026-12-27"), in: t, today: day("2026-11-25")) == ["报名已截止"])
        #expect(EventSourceCheck.ticket(start: day("2026-12-27"), in: [text("12月27日开跑，报名将于12月1日截止")], today: day("2026-11-25"))
                == ["需报名"])  // 截止 after the date: the order rule does not match
        #expect(EventSourceCheck.ticket(start: day("2026-12-27"), in: [text("12月27日开跑，报名截止日期为12月1日")], today: day("2026-11-25"))
                == ["报名截止12月1日"])
    }

    @Test("T-046zg F-18 §44 items 5-6: the store keeps checked events; checked today: no new page fetch or search; a confirmed value is never replaced")
    func store() async throws {
        let source = EventSearchHit(title: "AIE电子展", url: "https://s.example.com/aie", site: "",
                                    snippet: "2026AIE电子展将于12月3日至5日在珠海国际会展中心举办", date: "2026-11-17")
        let searcher = Searches { _ in EventSearchAnswer(text: "", sources: [source]) }
        let json = #"{"events":[{"name":"AIE电子展","start":"2026-12-03","end":"2026-12-05","time":"09:30","venue":"珠海国际会展中心","city":"珠海","source_url":"1"}]}"#
        let pages = Pages([:])
        let lines = Lines()
        let run = EventSearchRun(searcher: searcher, extractor: Extract([json]), clock: ManualClock(), mode: .qiniu, pages: pages,
                                 now: { noon }, onLine: lines.add)
        let first = try await run.run(request())
        let e = try #require(first.kept.first)
        #expect(e.venueVia == "page" && e.datesVia == "page" && e.time == "" && e.checkedOn == "2026-11-25")
        #expect(lines.all.contains("events check name=AIE电子展 venue=page dates=page image=none time=none ticket=none"))
        // Encoded and read back by the store with every field.
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(EventEntry.self, from: data) == e)
        let again = try await run.run(request(), known: [e])
        #expect(again.kept == [e] && pages.pages.count == 1)
        // An older check's confirmed venue stays when today's finds none.
        var older = e
        older.checkedOn = "2026-11-24"
        older.venue = "澳门威尼斯人金光会展中心"
        let noVenue = #"{"events":[{"name":"AIE电子展","start":"2026-12-03","end":"2026-12-05","venue":"横琴","city":"珠海","source_url":"1"}]}"#
        let kept = try await EventSearchRun(searcher: searcher, extractor: Extract([noVenue, #"{"events":[]}"#]), clock: ManualClock(),
                                            mode: .qiniu, pages: pages, now: { noon }).run(request(), known: [older])
        #expect(kept.kept.first?.venue == "澳门威尼斯人金光会展中心")
        // The extraction shape asks for the start time.
        #expect(EventSearchRun.shape.contains(#""time": "HH:MM""#))
    }
}
