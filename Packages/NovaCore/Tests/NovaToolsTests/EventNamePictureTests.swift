import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §43 items 2-6 (T-046zf): a named event searched by name, every dropped event logged, event pictures, the
// source by the event's name and the cities line.

private let noon = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24T04:00:00Z
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

private func day(_ s: String) -> EventDay { EventDay(s)! }
private func request(_ cities: [String] = ["珠海", "澳门"], from: String = "2026-11-25", to: String = "2026-11-30",
                     kinds: String = "", name: String = "") -> EventRequest {
    EventRequest(cities: cities, from: day(from), to: day(to), kinds: kinds, today: day("2026-11-24"), name: name)
}

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

private final class Extract: EventExtractor, Sendable {
    private let seen = Mutex<[String]>([])
    let json: String
    init(_ json: String) { self.json = json }
    var systems: [String] { seen.withLock { $0 } }
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        seen.withLock { $0.append(system) }
        return EventModelReply(content: json, tokens: 1)
    }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

/// Pages by url and image-search results by query; counts each call.
private final class Pages: EventPageSource, Sendable {
    let html: [String: String]
    let hits: [EventImageHit]
    private let calls = Mutex<(pages: [String], images: [String])>(([], []))
    init(html: [String: String] = [:], hits: [EventImageHit] = []) {
        self.html = html
        self.hits = hits
    }
    var pages: [String] { calls.withLock { $0.pages } }
    var images: [String] { calls.withLock { $0.images } }
    func page(_ url: String) async -> String? {
        calls.withLock { $0.pages.append(url) }
        return html[url]
    }
    func images(_ query: String) async throws -> [EventImageHit] {
        calls.withLock { $0.images.append(query) }
        return hits
    }
}

private let aiHit = EventSearchHit(title: "免费参与！2026横琴AI嘉年华来啦！", url: "https://m.zh.example.com/ai", site: "m.zh.example.com",
                                   snippet: "11月28日至29日", date: "2026-11-20")

private func entry(_ name: String, start: String = "2026-11-28", end: String = "2026-11-29", url: String = "https://m.zh.example.com/ai") -> EventEntry {
    EventEntry(name: name, start: start, end: end, datesText: "", venue: "", city: "珠海", sourceURL: url, sourceSite: "", fetchedAt: noon)
}

@Suite("T-046zf F-18 §43 named events, drops, pictures (NovaCore)")
struct EventNamePictureTests {
    @Test("T-046zf F-18 §43 row 81: find_events name 「AI 展」, 珠海+澳门, window in Nov 2026: first query 「AI 展 珠海 澳门 2026年11月」; at most 3 queries")
    func row81() {
        let q = EventSearchRun.qiniuQueries(request(name: "AI 展"))
        #expect(q.first?.text == "AI 展 珠海 澳门 2026年11月")
        #expect(q.map(\.text) == ["AI 展 珠海 澳门 2026年11月", "珠海 澳门 2026年11月 展览展会 科技展", "珠海 澳门 2026年11月 演唱会 演出"])
        // With the driver's kinds: still 3 in all, every kind searched (kinds past two appended).
        let k = EventSearchRun.qiniuQueries(request(kinds: "漫展、音乐、AI", name: "AIE"))
        #expect(k.map(\.text) == ["AIE 珠海 澳门 2026年11月", "珠海 澳门 2026年11月 漫展 AI", "珠海 澳门 2026年11月 音乐"])
        // The name query marks no kind in the store.
        #expect(k[0].covers.isEmpty && k[0].kind == nil)
        // Argument checks: at most 30 characters; the shape accepts `name`.
        let today = day("2026-11-24")
        let args: JSONValue = ["cities": ["珠海"], "from": "2026-11-25", "to": "2026-11-30", "name": .string(String(repeating: "展", count: 31))]
        #expect(FindEventsExecutor.refusal(args, today: today) == "name")
        #expect(ToolCatalog.findEventsDescription.contains("司机说了某个活动的名字时填 name。"))
    }

    @Test("T-046zf F-18 §43 row 82: store covers the window but no event has 「AI」 in its name; name 「AI 展」: not a hit, the searches run")
    func row82() async throws {
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { shanghai })
        let pairs = ["珠海", "澳门"].flatMap { c in EventSearchRun.defaultKinds.map { SearchedPair(city: c, kind: $0, kept: 1) } }
        await store.record([entry("珠海航展")], searched: pairs, from: "2026-11-25", to: "2026-11-30")
        let searcher = Searches { _ in EventSearchAnswer(text: "", sources: [aiHit]) }
        let lines = Lines()
        let finder = EventFinder(store: store, work: nil, onLine: lines.add) { _ in
            EventSearchRun(searcher: searcher, extractor: Extract(#"{"events":[]}"#), clock: ManualClock(), mode: .qiniu, now: { noon })
        }
        // Without a name the store answers.
        if case .store = await finder.find(request(), onMiss: { _ in }) {} else { Issue.record("store hit expected") }
        #expect(searcher.queries.isEmpty)
        let found = await finder.find(request(name: "AI 展"), onMiss: { _ in })
        guard case .searched = found else { Issue.record("searches expected"); return }
        #expect(searcher.queries.first == "AI 展 珠海 澳门 2026年11月")
        #expect(lines.all.contains { $0.hasPrefix("events store miss") && $0.hasSuffix("name=yes") })
        // A stored name containing the asked name (or contained in it) is a hit.
        #expect(EventFinder.names([entry("2026横琴AI嘉年华")], "AI嘉年华") && EventFinder.names([entry("AIE")], "AIE 电子展"))
        #expect(!EventFinder.names([entry("2026横琴AI嘉年华")], "AI 展"))
    }

    @Test("T-046zf F-18 §43 row 83: an extracted event with no dates: `events drop name=… reason=no_date`; every check's reason in order")
    func row83() async throws {
        let searcher = Searches { _ in EventSearchAnswer(text: "", sources: [aiHit]) }
        let json = #"""
        {"events": [
          {"name": "没日期", "start": "", "end": "", "venue": "", "city": "珠海", "source_url": "1"},
          {"name": "倒过来", "start": "2026-11-29", "end": "2026-11-28", "city": "珠海", "source_url": "1"},
          {"name": "窗外", "start": "2026-12-20", "end": "2026-12-21", "city": "珠海", "source_url": "1"},
          {"name": "广州的", "start": "2026-11-28", "end": "2026-11-29", "city": "广州", "source_url": "1"},
          {"name": "没来源", "start": "2026-11-28", "end": "2026-11-29", "city": "珠海", "source_url": "https://invented.example/x"},
          {"name": "2026横琴AI嘉年华", "start": "2026-11-28", "end": "2026-11-29", "city": "珠海", "source_url": "1"},
          {"name": "2026横琴AI嘉年华", "start": "2026-11-28", "end": "2026-11-29", "city": "珠海", "source_url": "1"}
        ]}
        """#
        let lines = Lines()
        let out = try await EventSearchRun(searcher: searcher, extractor: Extract(json), clock: ManualClock(), mode: .qiniu,
                                           now: { noon }, onLine: lines.add).run(request(name: "AI 展"))
        let drops = lines.all.filter { $0.hasPrefix("events drop ") }
        #expect(drops == ["events drop name=没日期 reason=no_date", "events drop name=倒过来 reason=end_before_start",
                          "events drop name=窗外 reason=outside_window", "events drop name=广州的 reason=city",
                          "events drop name=没来源 reason=no_source", "events drop name=2026横琴AI嘉年华 reason=duplicate"])
        #expect(out.dropped == 6 && out.kept.map(\.name) == ["2026横琴AI嘉年华"])
        let past = EventSearchRun.check([EventCandidate(name: "去年", start: "2026-11-20", end: "2026-11-23", datesText: "", venue: "",
                                                        city: "珠海", sourceURL: aiHit.url)],
                                        answers: [], request: EventRequest(cities: ["珠海"], from: day("2026-11-20"), to: day("2026-11-30"),
                                                                           kinds: "", today: day("2026-11-24")), at: noon)
        #expect(past.drops.map(\.reason) == [.past])
    }

    @Test("T-046zf F-18 §43 row 84: page og:image used; else only the good image-search result (not the shop URL, wrong title or old date); else nil")
    func row84() async throws {
        let og = #"<html><head><meta name="x" content="y"><meta content="//img.example.com/poster.jpg" property="og:image"></head><body><img src="/logo.png"></body></html>"#
        #expect(EventPicture.ogImage(og) == "https://img.example.com/poster.jpg")
        #expect(EventPicture.ogImage(#"<meta name="og:image" content="https://a.example.com/b.jpg?x=1&amp;y=2">"#) == "https://a.example.com/b.jpg?x=1&y=2")
        #expect(EventPicture.ogImage(#"<html><img src="https://a.example.com/logo.png"></html>"#) == nil)
        let ai = entry("2026横琴AI嘉年华")
        let shop = EventImageHit(title: "2026横琴AI嘉年华 海报", date: "2026-11-20", imageURL: "https://img.alicdn.com/a.jpg")
        let wrongTitle = EventImageHit(title: "横琴嘉年华 海报", date: "2026-11-20", imageURL: "https://p.example.com/1.jpg")
        let old = EventImageHit(title: "2026横琴AI嘉年华", date: "2026-09-01", imageURL: "https://p.example.com/2.jpg")
        let generated = EventImageHit(title: "2026 横琴ai嘉年华", date: "2026-11-01", imageURL: "https://p.example.com/gen_ai/3.jpg")
        let good = EventImageHit(title: "2026 横琴ai嘉年华 现场", date: "2026-10-01", imageURL: "https://p.example.com/4.jpg")
        #expect(EventPicture.pick([shop, wrongTitle, old, generated, good], for: ai) == "https://p.example.com/4.jpg")
        #expect(EventPicture.pick([shop, wrongTitle, old, generated], for: ai) == nil)
        #expect(EventPicture.query(ai) == "2026横琴AI嘉年华 2026 海报")
        // Through the run: og first (no image search); a page without og: the search; nothing: none, 「未找到图片」 later.
        let searcher = Searches { _ in EventSearchAnswer(text: "", sources: [aiHit]) }
        let json = #"{"events":[{"name": "2026横琴AI嘉年华", "start": "2026-11-28", "end": "2026-11-29", "city": "珠海", "source_url": "1"}]}"#
        func run(_ pages: Pages, known: [EventEntry] = []) async throws -> (EventEntry, [String]) {
            let lines = Lines()
            let out = try await EventSearchRun(searcher: searcher, extractor: Extract(json), clock: ManualClock(), mode: .qiniu,
                                               pages: pages, now: { noon }, onLine: lines.add).run(request(), known: known)
            return (try #require(out.kept.first), lines.all.filter { $0.hasPrefix("events image") })
        }
        let withOg = Pages(html: [aiHit.url: og], hits: [good])
        let (a, la) = try await run(withOg)
        #expect(a.imageURL == "https://img.example.com/poster.jpg" && a.imageVia == "og" && a.imageLabel == nil && withOg.images.isEmpty)
        #expect(la == ["events image name=2026横琴AI嘉年华 via=og"] && a.json["image_url"] == "https://img.example.com/poster.jpg")
        let searched = Pages(html: [aiHit.url: "<html></html>"], hits: [shop, good])
        let (b, lb) = try await run(searched)
        #expect(b.imageURL == good.imageURL && b.imageVia == "search" && b.imageLabel == "网络图片")
        #expect(searched.images == ["2026横琴AI嘉年华 2026 海报"] && lb == ["events image name=2026横琴AI嘉年华 via=search"])
        let none = Pages(hits: [shop])
        let (c, lc) = try await run(none)
        #expect(c.imageURL == nil && c.imageVia == "none" && lc == ["events image name=2026横琴AI嘉年华 via=none"])
        // Looked for today already (store): not looked for again.
        let again = Pages(html: [aiHit.url: og])
        let (d, ld) = try await run(again, known: [b])
        #expect(d.imageURL == good.imageURL && again.pages.isEmpty && again.images.isEmpty && ld.isEmpty)
    }

    @Test("T-046zf F-18 §43 items 5-6: a source url not among the results: the first result naming the event (name, without the year, the bracket part); cities line in the system text")
    func items5and6() {
        #expect(EventSearchRun.nameVariants("2026全球智能制造与电子产品博览会（AIE电子展）") == ["2026全球智能制造与电子产品博览会（AIE电子展）", "全球智能制造与电子产品博览会（AIE电子展）", "AIE电子展"])
        #expect(EventSearchRun.nameVariants("展会") == [])
        let other = EventSearchHit(title: "澳门展览", url: "https://b.example.com/mo", site: "", snippet: "", date: "")
        let aie = EventSearchHit(title: "AIE电子展12月开幕", url: "https://a.example.com/aie", site: "", snippet: "", date: "")
        let q = EventQuery(text: "q", city: "珠海", kind: "展览展会")
        let c = EventCandidate(name: "2026全球智能制造与电子产品博览会（AIE电子展）", start: "2026-11-28", end: "2026-11-29", datesText: "",
                               venue: "", city: "珠海", sourceURL: "https://model.example/aie")
        let out = EventSearchRun.check([c], answers: [(q, EventSearchAnswer(text: "", sources: [other, aie]))], request: request(),
                                       at: noon, numbered: [other, aie])
        #expect(out.kept.map(\.sourceURL) == ["https://a.example.com/aie"])
        #expect(EventSearchRun.system(request()) + "\ncities: 珠海, 澳门" == EventSearchRun.system(request(), qiniu: true))
        #expect(EventSearchRun.system(request(), qiniu: true).hasSuffix("\nto: 2026-11-30\ncities: 珠海, 澳门"))
    }
}
