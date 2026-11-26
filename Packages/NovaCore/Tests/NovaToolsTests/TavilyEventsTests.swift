import Foundation
import Synchronization
import NovaKit
import NovaPorts
import Testing
@testable import NovaTools

// F-18 §46 (T-046zi): events through Tavily and Qwen; item 0's output contract decided by code.

private let noon = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24T04:00:00Z

private func day(_ s: String) -> EventDay { EventDay(s)! }
private func request(_ cities: [String] = ["珠海", "澳门"], from: String = "2026-11-25", to: String = "2026-12-31",
                     kinds: String = "", name: String = "") -> EventRequest {
    EventRequest(cities: cities, from: day(from), to: day(to), kinds: kinds, today: day("2026-11-24"), name: name)
}

private func hit(_ n: Int, _ title: String, _ content: String, date: String = "") -> EventSearchHit {
    EventSearchHit(title: title, url: "https://e.example/\(n)", site: "e.example", snippet: content, date: date)
}

/// A picture whose bytes carry its own url (PNG header, padded past 5 KB), so the reader can answer per picture.
private func picture(_ url: String) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    d.append(Data(("URL=" + url + "=END").utf8))
    d.append(Data(repeating: 0x20, count: 6000))
    return d
}

private final class Web: EventWebSource, Sendable {
    let results: @Sendable (String, Bool) -> EventWebResults
    let pages: [EventPage]
    private let log = Mutex<(searches: [String], extracts: [[String]])>(([], []))
    init(pages: [EventPage] = [], results: @escaping @Sendable (String, Bool) -> EventWebResults) {
        self.results = results
        self.pages = pages
    }
    var searches: [String] { log.withLock { $0.searches } }
    var extracts: [[String]] { log.withLock { $0.extracts } }
    func search(_ query: String, images: Bool) async throws -> EventWebResults {
        log.withLock { $0.searches.append((images ? "image:" : "") + query) }
        return results(query, images)
    }
    func extract(_ urls: [String]) async throws -> [EventPage] {
        log.withLock { $0.extracts.append(urls) }
        return pages.filter { urls.contains($0.url) }
    }
    func download(_ url: String) async -> Data? { picture(url) }
}

private final class Reader: EventReader, Sendable {
    let readings: [String: String]
    let facts: @Sendable (String) -> String
    private let seen = Mutex<[String]>([])
    init(readings: [String: String], facts: @escaping @Sendable (String) -> String) {
        self.readings = readings
        self.facts = facts
    }
    var pictures: [String] { seen.withLock { $0 } }
    func picture(_ dataURL: String, prompt: String) async throws -> String {
        let b64 = String(dataURL.split(separator: ",").last ?? "")
        let text = String(decoding: Data(base64Encoded: b64) ?? Data(), as: UTF8.self)
        guard let a = text.range(of: "URL="), let b = text.range(of: "=END") else { return "{}" }
        let url = String(text[a.upperBound..<b.lowerBound])
        seen.withLock { $0.append(url) }
        return readings[url] ?? #"{"text": "", "dates": [], "times": [], "venue": ""}"#
    }
    func text(_ prompt: String) async throws -> String { facts(prompt) }
}

private final class Extract: EventExtractor, Sendable {
    let json: String
    private let seen = Mutex<[(String, String)]>([])
    init(_ json: String) { self.json = json }
    var calls: [(String, String)] { seen.withLock { $0 } }
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        seen.withLock { $0.append((system, user)) }
        return EventModelReply(content: json, tokens: 3, model: "qwen3.8-max-0902", promptTokens: 2, completionTokens: 1)
    }
}

private final class Lines: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ l: String) { list.withLock { $0.append(l) } }
    var all: [String] { list.withLock { $0 } }
}

private func reading(_ text: String, dates: [String], times: [String] = [], venue: String = "") -> String {
    let d = dates.map { "\"\($0)\"" }.joined(separator: ", "), t = times.map { "\"\($0)\"" }.joined(separator: ", ")
    return #"{"text": "\#(text)", "dates": [\#(d)], "times": [\#(t)], "venue": "\#(venue)"}"#
}

@Suite("F-18 §46 Tavily events")
struct TavilyEventsTests {
    @Test("T-046zi F-18 §46 row 108: find_events 珠海+澳门, 11-25…12-31: the three item 2 queries exactly")
    func queries() {
        let q = TavilyEventRun.queries(request()).map(\.text)
        #expect(q == ["珠海 横琴 澳门 2026年11月 12月 展览展会 AI 科技展 航展",
                      "澳门 2026年11月 12月 演唱会 演出时间表 FANCON",
                      "珠海 横琴 2026年11月 12月 演唱会 嘉年华 电音节 马拉松"])
        // With no SAR city q2 uses all cities; a named event takes the first query.
        #expect(TavilyEventRun.queries(request(["深圳"]))[1].text == "深圳 2026年11月 12月 演唱会 演出时间表 FANCON")
        let named = TavilyEventRun.queries(request(name: "张敬轩")).map(\.text)
        #expect(named.count == 3 && named[0] == "张敬轩 珠海 横琴 澳门 2026年11月 12月")
        #expect(named[1].hasSuffix("演唱会 演出时间表 FANCON"))
    }

    @Test("T-046zi F-18 §46 row 109: two queries share a url: the extraction message deduplicated, item 3's system text, `[n]` becomes the url")
    func extractionMessage() {
        let a = EventWebResults(hits: [hit(1, "韦礼安 演唱会", "12月12日 澳门", date: "2026-11-01"), hit(2, "AIE", "x")])
        let b = EventWebResults(hits: [hit(2, "AIE", "x"), hit(3, "马拉松", "y")])
        let (text, numbered) = TavilyEventRun.user([a, b])
        #expect(numbered.map(\.url) == ["https://e.example/1", "https://e.example/2", "https://e.example/3"])
        #expect(text == "[1] 2026-11-01 韦礼安 演唱会 — 12月12日 澳门 (https://e.example/1)\n[2]  AIE — x (https://e.example/2)\n[3]  马拉松 — y (https://e.example/3)")
        #expect(TavilyEventRun.system(request()) == #"Extract the event information. Answer in JSON.\#n{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "start_time": "HH:MM or empty", "venue": "", "city": "", "ticket": "", "source_url": ""}]}\#ntoday: 2026-11-24\#nfrom: 2026-11-25\#nto: 2026-12-31"#)
        let c = EventCandidate(name: "韦礼安 演唱会", start: "2026-12-12", end: "2026-12-12", datesText: "", venue: "", city: "澳门",
                               sourceURL: "[1]")
        let pre = TavilyEventRun.precheck([c], numbered: numbered, request: request())
        #expect(pre.kept.count == 1 && pre.drops.isEmpty)
    }

    @Test("T-046zi F-18 §46 row 110: 韦礼安's poster rejected for 张敬轩 x 澳门中乐团 12-24…12-31; his own accepted")
    func posterMatch() {
        let keys = EventText.keys("张敬轩 x 澳门中乐团 《盛乐》演唱会")
        let wrong = PosterReading.parse(reading("2026 韦礼安 HI WE1 演唱会", dates: ["12-12"]))!
        let right = PosterReading.parse(reading("张敬轩 × 澳门中乐团 盛乐", dates: ["12-24"]))!
        #expect(!wrong.matches(keys: keys, start: day("2026-12-24"), end: day("2026-12-31")))
        #expect(right.matches(keys: keys, start: day("2026-12-24"), end: day("2026-12-31")))
        // Traditional text is converted first (item 0).
        #expect(EventText.keys("2026横琴马拉松") == ["马拉松"])
        #expect(EventText.names("橫琴馬拉松 2026", keys: ["马拉松"]))
        #expect(!EventText.names("橫琴馬拉松", keys: ["世界杯"]))
        // Removed words are deleted, so the rest stays one key.
        #expect(EventText.keys("张学友演唱会世界巡回") == ["张学友世界"])
    }

    @Test("T-046zi F-18 §46 row 112: a venue quote not in that source's excerpt is not sure; one that is, is sure")
    func venueQuote() {
        let pool = [EventPoolSource(url: "u1", title: "张敬轩", text: "张敬轩 x 澳门中乐团 地点：澳门威尼斯人综艺馆 晚上9:30", cities: [], at: noon),
                    EventPoolSource(url: "u2", title: "韦礼安", text: "韦礼安 地点：银河综艺馆", cities: [], at: noon)]
        let ex = EventFacts.excerpts(pool, keys: EventText.keys("张敬轩 x 澳门中乐团"))
        var a = EventFacts.Answer()
        a.venue = "银河综艺馆"; a.venueQuote = "地点：银河综艺馆"; a.venueSource = 1
        #expect(!EventFacts.venueSure(a, excerpts: ex))
        a.venue = "澳门威尼斯人综艺馆"; a.venueQuote = "地点：澳门威尼斯人综艺馆"
        #expect(EventFacts.venueSure(a, excerpts: ex))
    }

    @Test("T-046zi F-18 §46 row 113: 「晚上6時正」 with 18:00 sure; 「13:30–17:30」 with 13:30 from another event's excerpt not sure")
    func hourQuote() {
        let pool = [EventPoolSource(url: "u1", title: "UAU", text: "UAU 演唱會 晚上6時正 開始", cities: [], at: noon),
                    EventPoolSource(url: "u2", title: "AIE", text: "AIE 开放 13:30–17:30", cities: [], at: noon)]
        let ex = EventFacts.excerpts(pool, keys: EventText.keys("UAU 演唱会"))
        var a = EventFacts.Answer()
        a.startTime = "18:00"; a.timeQuote = "晚上6時正"; a.timeSource = 1
        #expect(EventFacts.hourSure(a, excerpts: ex))
        a.startTime = "13:30"; a.timeQuote = "13:30–17:30"; a.timeSource = 2
        #expect(!EventFacts.hourSure(a, excerpts: ex))
        a.startTime = "25:00"; a.timeQuote = "晚上6時正"; a.timeSource = 1
        #expect(!EventFacts.hourSure(a, excerpts: ex))
    }

    @Test("T-046zi F-18 §46 row 117b: dates confirmed in one excerpt (start, range sign, English month); a planted wrong date rejected")
    func datesRow() {
        #expect(EventDates.confirmed(start: day("2026-12-27"), end: day("2026-12-27"), in: "比赛时间：2026年12月27日（星期日）07:30"))
        #expect(!EventDates.confirmed(start: day("2026-12-28"), end: day("2026-12-28"), in: "比赛时间：2026年12月27日（星期日）07:30"))
        #expect(EventDates.confirmed(start: day("2026-12-03"), end: day("2026-12-05"), in: "将于12月3日至5日在澳门举办"))
        #expect(!EventDates.confirmed(start: day("2026-12-03"), end: day("2026-12-06"), in: "将于12月3日至5日在澳门举办"))
        #expect(EventDates.confirmed(start: day("2026-12-12"), end: day("2026-12-12"), in: "December 12, 2026 Galaxy Arena"))
        #expect(EventDates.confirmed(start: day("2026-12-01"), end: day("2026-12-01"), in: "December  1 2026, Arena"))
        #expect(!EventDates.confirmed(start: day("2026-12-12"), end: day("2026-12-12"), in: "Dec 12"))
        // A different year just before the day does not count.
        #expect(!EventDates.confirmed(start: day("2026-11-28"), end: day("2026-11-28"), in: "2025年11月28日在伦敦人综艺馆"))
        // 11-2 is not inside 11-25.
        #expect(!EventDates.confirmed(start: day("2026-11-02"), end: day("2026-11-02"), in: "11月25日"))
    }

    @Test("T-046zi F-18 §46 row 120: item 0, one fixture per row: each dropped with that row's reason, in order")
    func contractRows() {
        let numbered = [hit(1, "张敬轩 演唱会", "12月24日 澳门"), hit(2, "韦礼安 演唱会", "12月12日")]
        func c(_ name: String, _ start: String, _ end: String, city: String = "澳门", src: String = "1") -> EventCandidate {
            EventCandidate(name: name, start: start, end: end, datesText: "", venue: "", city: city, sourceURL: src)
        }
        let pre = TavilyEventRun.precheck([
            c("周杰伦 演唱会", "2026-12-24", "2026-12-24", src: "1"),     // name not in its source (no result names it)
            c("张敬轩 演唱会", "2026-12-24", "2026-12-24", city: "深圳"),
            c("张敬轩 演唱会", "2026-12-24", "2026-12-20"),
        ], numbered: numbered, request: request())
        #expect(pre.drops.map(\.reason) == [.noSource, .city, .endBeforeStart])

        let e = EventEntry(name: "张敬轩 演唱会", start: "2026-12-24", end: "2026-12-24", datesText: "", venue: "", city: "澳门",
                           sourceURL: "u1", sourceSite: "", fetchedAt: noon)
        let keys = EventText.keys(e.name)
        func verdict(_ text: String, venue: String, vq: String, time: String, tq: String) -> TavilyEventRun.Drop? {
            let pool = [EventPoolSource(url: "u1", title: "张敬轩", text: text, cities: [], at: noon),
                        EventPoolSource(url: "u2", title: "韦礼安", text: "韦礼安 12月24日 银河综艺馆 晚上8時", cities: [], at: noon)]
            let ex = EventFacts.excerpts(pool, keys: keys)
            var a = EventFacts.Answer()
            a.venue = venue; a.venueQuote = vq; a.venueSource = 1; a.startTime = time; a.timeQuote = tq; a.timeSource = 1
            return TavilyEventRun.decide(e, keys: keys, start: day("2026-12-24"), end: day("2026-12-24"), excerpts: ex, pool: pool,
                                         answer: a, poster: nil, posterURL: nil, posterVia: "none", pictures: 0).drop
        }
        let good = "张敬轩 12月24日 地点：澳门威尼斯人综艺馆 晚上9:30"
        #expect(verdict(good, venue: "澳门威尼斯人综艺馆", vq: "澳门威尼斯人综艺馆", time: "21:30", tq: "晚上9:30") == nil)
        // Dates only in another event's excerpt.
        #expect(verdict("张敬轩 地点：澳门威尼斯人综艺馆 晚上9:30", venue: "澳门威尼斯人综艺馆", vq: "澳门威尼斯人综艺馆", time: "21:30",
                        tq: "晚上9:30") == .datesNotSure)
        #expect(verdict(good, venue: "银河综艺馆", vq: "银河综艺馆", time: "21:30", tq: "晚上9:30") == .venueNotSure)
        #expect(verdict(good, venue: "澳门威尼斯人综艺馆", vq: "澳门威尼斯人综艺馆", time: "25:00", tq: "晚上9:30") == .timeNotSure)
        #expect(verdict(good, venue: "澳门威尼斯人综艺馆", vq: "澳门威尼斯人综艺馆", time: "20:00", tq: "晚上8時") == .timeNotSure)
    }

    /// One run: 张敬轩 (page pictures: 韦礼安's then his own), 横琴马拉松 (no page picture matches: one picture search, still
    /// none), AIE (no hour anywhere: dropped).
    private func fullRun(_ lines: Lines, web: inout Web?, reader: inout Reader?) async throws -> EventSearchOutcome {
        let results: [EventSearchHit] = [
            hit(1, "张敬轩 x 澳门中乐团 盛乐", "张敬轩 x 澳门中乐团 12月24日 澳门威尼斯人综艺馆 晚上9:30"),
            hit(2, "2026橫琴馬拉松", "橫琴馬拉松 比赛时间：2026年12月27日（星期日）07:30 起点：横琴口岸"),
            hit(3, "AIE电子展", "AIE电子展 12月3日至5日 澳门威尼斯人"),
        ]
        let w = Web(pages: [EventPage(url: "https://e.example/1", title: "张敬轩", rawContent: "张敬轩 x 澳门中乐团",
                                      images: ["p/weilian.png", "p/hins.png"]),
                            EventPage(url: "https://e.example/2", title: "横琴马拉松", rawContent: "", images: ["p/logo.png"])]) { q, images in
            images ? EventWebResults(hits: [], images: ["s/\(q).png"]) : EventWebResults(hits: results)
        }
        let r = Reader(readings: [
            "p/weilian.png": reading("2026 韦礼安 HI WE1 演唱会", dates: ["12-12"]),
            "p/hins.png": reading("张敬轩 × 澳门中乐团 盛乐", dates: ["12-24"], times: ["21:30"]),
        ]) { prompt in
            if prompt.hasPrefix("Event: 张敬轩") {
                return #"{"venue": "澳门威尼斯人综艺馆", "venue_quote": "澳门威尼斯人综艺馆", "venue_source": 1, "start_time": "21:30", "time_kind": "start", "time_quote": "晚上9:30", "time_source": 1}"#
            }
            if prompt.hasPrefix("Event: 2026横琴马拉松") {
                return #"{"venue": "横琴口岸", "venue_quote": "起点：横琴口岸", "venue_source": 2, "start_time": "07:30", "time_kind": "start", "time_quote": "比赛时间：2026年12月27日（星期日）07:30", "time_source": 2}"#
            }
            return #"{"venue": "澳门威尼斯人", "venue_quote": "澳门威尼斯人", "venue_source": 3, "start_time": "", "time_kind": "opening", "time_quote": "", "time_source": 0}"#
        }
        web = w
        reader = r
        let json = #"{"events": [{"name": "张敬轩 x 澳门中乐团 盛乐", "start": "2026-12-24", "end": "2026-12-24", "start_time": "21:30", "venue": "x", "city": "澳门", "ticket": "", "source_url": "1"}, {"name": "2026横琴马拉松", "start": "2026-12-27", "end": "2026-12-27", "start_time": "", "venue": "", "city": "横琴", "ticket": "", "source_url": "https://e.example/2"}, {"name": "AIE电子展", "start": "2026-12-03", "end": "2026-12-05", "start_time": "", "venue": "", "city": "澳门", "ticket": "", "source_url": "3"}]}"#
        return try await TavilyEventRun(web: w, extractor: Extract(json), reader: r, clock: ManualClock(), now: { noon },
                                        onLine: lines.add).run(request())
    }

    @Test("T-046zi F-18 §46 rows 110, 111, 114, 121: poster page then search, one picture per call; hour not sure: dropped; poster none: kept with 未找到图片")
    func run() async throws {
        let lines = Lines()
        var web: Web?, reader: Reader?
        let out = try await fullRun(lines, web: &web, reader: &reader)
        #expect(out.kept.map(\.name) == ["张敬轩 x 澳门中乐团 盛乐", "2026横琴马拉松"])
        let hins = out.kept[0], race = out.kept[1]
        // Row 110: the first page picture (韦礼安's) rejected, the second is the poster.
        #expect(hins.imageURL == "p/hins.png" && hins.imageVia == "page")
        #expect(hins.venue == "澳门威尼斯人综艺馆" && hins.time == "21:30" && hins.factsText.contains("开始：21:30"))
        // Rows 111, 121: no page picture matches: one 「<name> 海报」 search; none matches: kept, 「未找到图片」.
        #expect(Set(web!.searches.filter { $0.hasPrefix("image:") }) == ["image:2026横琴马拉松 海报", "image:AIE电子展 海报"])
        #expect(!reader!.pictures.contains { $0.hasPrefix("s/张敬轩") })
        #expect(reader!.pictures.contains("s/2026横琴马拉松 海报.png"))
        #expect(race.imageURL == nil && race.imageCardText == "未找到图片" && race.city == "珠海")
        // Row 114: AIE has no hour: not in the result; record line.
        #expect(lines.all.contains("events drop name=AIE电子展 reason=time_not_sure"))
        #expect(out.unsure == 1)
        #expect(lines.all.contains { $0.hasPrefix("events verify name=张敬轩 x 澳门中乐团 盛乐 venue=S1 time=S1 kind=start poster=page pictures=2 kept=yes") })
        #expect(lines.all.filter { $0.hasPrefix("events search provider=tavily q=") }.count == 3)
        #expect(lines.all.contains { $0.hasPrefix("events extract model=qwen3.8-max-0902 ms=") && $0.hasSuffix("tokens=2,1") })
        // Item 4: one Extract call for the kept events' pages.
        #expect(web!.extracts.count == 1)
    }

    @Test("T-046zi F-18 §46 row 114: a dropped event is not stored and find_events says how many were not confirmed")
    func droppedNotStored() async throws {
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { TimeZone(identifier: "Asia/Shanghai")! })
        let lines = Lines()
        var web: Web?, reader: Reader?
        let out = try await fullRun(lines, web: &web, reader: &reader)
        await store.record(out.kept, searched: out.searched, from: "2026-11-25", to: "2026-12-31")
        #expect(await store.all.map(\.name).contains("AIE电子展") == false)
        #expect(FindEventsExecutor.unsureNote(out.unsure) == "另有1个活动时间或地点未确认，未列出")
    }

    @Test("T-046zi F-18 §46 row 114 (review): with older events stored (an unverified one, a verified one dropped now) only this run's verified events are shown; an old window does not answer")
    func storeOnTavilyPath() async throws {
        let store = EventStore(storage: MemoryEventStorage(), now: { noon }, zone: { TimeZone(identifier: "Asia/Shanghai")! })
        var oldQiniu = EventEntry(name: "旧活动", start: "2026-12-01", end: "2026-12-01", datesText: "", venue: "", city: "澳门",
                                  sourceURL: "u", sourceSite: "", fetchedAt: noon)
        oldQiniu.checkedOn = "2026-11-24"
        var aie = EventEntry(name: "AIE电子展", start: "2026-12-03", end: "2026-12-05", datesText: "", venue: "x", city: "澳门",
                             sourceURL: "u", sourceSite: "", fetchedAt: noon)
        aie.datesVia = "source"
        await store.record([oldQiniu, aie], searched: [SearchedPair(city: "澳门", kind: "展览展会", kept: 2)],
                           from: "2026-11-25", to: "2026-12-31")
        let lines = Lines()
        var web: Web?, reader: Reader?
        _ = try await fullRun(lines, web: &web, reader: &reader)
        let w = web!, rd = reader!
        let json = #"{"events": [{"name": "张敬轩 x 澳门中乐团 盛乐", "start": "2026-12-24", "end": "2026-12-24", "start_time": "", "venue": "", "city": "澳门", "ticket": "", "source_url": "1"}, {"name": "AIE电子展", "start": "2026-12-03", "end": "2026-12-05", "start_time": "", "venue": "", "city": "澳门", "ticket": "", "source_url": "3"}]}"#
        let finder = EventFinder(store: store, work: nil, verified: { true }) { _ in
            TavilyEventRun(web: w, extractor: Extract(json), reader: rd, clock: ManualClock(), now: { noon })
        }
        let r = request(["澳门"], kinds: "展览展会")
        guard case .searched(let shown, _) = await finder.find(r, onMiss: { _ in }) else {
            Issue.record("the old window answered")
            return
        }
        #expect(shown.map(\.name) == ["张敬轩 x 澳门中乐团 盛乐"])
        #expect(await store.all.map(\.name) == ["张敬轩 x 澳门中乐团 盛乐"])
        guard case .store(let again, _) = await finder.find(r, onMiss: { _ in }) else {
            Issue.record("the verified window did not answer")
            return
        }
        #expect(again.map(\.name) == ["张敬轩 x 澳门中乐团 盛乐"])
    }

    @Test("T-046zi F-18 §46 item 5: picture bytes: JPEG/PNG/GIF/WebP, 5 KB–4 MB only")
    func pictureBytes() {
        #expect(EventPoster.dataURL(picture("a"))?.hasPrefix("data:image/png;base64,") == true)
        #expect(EventPoster.dataURL(Data([0xFF, 0xD8, 0xFF]) + Data(count: 100)) == nil)
        #expect(EventPoster.dataURL(Data("<html>".utf8) + Data(count: 6000)) == nil)
    }
}
