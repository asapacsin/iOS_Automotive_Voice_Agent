import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §74 (T-040zza): facts the driver chose reach the planner by id and by his own words, never by her retelling.

private let zone = TimeZone(identifier: "Asia/Shanghai")!
private let nov27 = Date(timeIntervalSince1970: 1_795_752_000)  // Fri 2026-11-27 12:00 Asia/Shanghai

private func entry(_ name: String, venue: String, start: String, end: String) -> EventEntry {
    EventEntry(name: name, start: start, end: end, datesText: "", venue: venue, city: "珠海",
               sourceURL: "https://example.org/e", sourceSite: "example.org", fetchedAt: nov27,
               venueVia: "search", datesVia: "page")
}

/// X: one venue.
private let carnival = entry("横琴AI嘉年华", venue: "珠海国际会展中心7-8号馆", start: "2026-11-28", end: "2026-11-29")
/// Y: venues P (珠海) and Q (澳门), the record's AIE.
private let aie = entry("AIE电子展", venue: "珠海国际会展中心；澳门威尼斯人金光会展中心", start: "2026-12-03", end: "2026-12-05")

private struct NoSearch: EventWebSearcher {
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer { EventSearchAnswer(text: "", sources: []) }
}
private struct NoExtract: EventExtractor {
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        EventModelReply(content: #"{"events":[]}"#)
    }
}

/// A store holding X and Y, 珠海 and 澳门 searched (no search runs).
private func finder() async -> EventFinder {
    let store = EventStore(storage: MemoryEventStorage(), now: { nov27 }, zone: { zone })
    let pairs = ["珠海", "澳门"].flatMap { c in EventSearchRun.defaultKinds.map { SearchedPair(city: c, kind: $0, kept: 1) } }
    await store.record([carnival, aie], searched: pairs, from: "2026-11-27", to: "2026-12-27")
    return EventFinder(store: store, work: nil) { _ in EventSearchRun(searcher: NoSearch(), extractor: NoExtract(), clock: ManualClock()) }
}

private let findCall = ToolCall(id: CallID("find")!, name: "find_events",
                                arguments: ["cities": ["珠海"], "from": "2026-11-27", "to": "2026-12-10"])

private let macau = "820007"
private let table: [String: [Place]] = [
    "珠海国际会展中心7-8号馆": [mapPlace("珠海国际会展中心", 22.10, city: "珠海市", adcode: "440402")],
    "珠海国际会展中心": [mapPlace("珠海国际会展中心", 22.10, city: "珠海市", adcode: "440402")],
    "澳门威尼斯人金光会展中心": [mapPlace("澳门威尼斯人金光会展中心", 22.14, city: "澳门特别行政区", adcode: macau)],
    "珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")],
]
/// Row 371: the PoC's 高德 answer for the venue: its halls only.
private let hallTable: [String: [Place]] = [
    "澳门威尼斯人金光会展中心": [mapPlace("澳门威尼斯人金光会展E馆", 22.14, city: "澳门特别行政区", adcode: macau),
                                mapPlace("金光会展-展馆A(金光大道)", 22.141, city: "澳门特别行政区", adcode: macau),
                                mapPlace("金光会展-展馆B(金光大道)", 22.142, city: "澳门特别行政区", adcode: macau)],
    "珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")],
]

/// A rig whose events finder listed X and Y once (`find_events`), so `e1`, `e2a`, `e2b` are known.
private func rig(_ answers: [ScriptPlanner.Answer], table: [String: [Place]] = table, listed: Bool = true) async -> (LookupRig, EventFinder) {
    let r = await LookupRig(answers, search: AmapLookupSearch(table))
    let f = await finder()
    await r.planner.setEvents(f)
    if listed { _ = await FindEventsExecutor(finder: f).execute(findCall) }
    return (r, f)
}

private func call(_ asked: [String: JSONValue], id: String = "plan") -> ToolCall {
    ToolCall(id: CallID(id)!, name: "plan_trip", arguments: ["asked": .object(asked)])
}

private let aieAtP: [[JSONValue]] = [[["name": "AIE电子展", "location": "珠海国际会展中心", "city": "珠海", "minutes": 120]],
                                     [["name": "珠海渔女", "city": "珠海", "minutes": 60]]]

private func firstMessage(_ r: LookupRig) -> String { r.model.calls.withLock { $0.first?.first?.content ?? "" } }

@Suite("T-040zza F-15b §74 facts the driver chose reach the planner by id and by his own words")
struct TripEventIDTests {
    @Test("T-040zza F-15b §74 row 364: find_events lists X as e1, Y once per venue as e2a P / e2b Q with its own venue in facts; next ends with item 1's sentence")
    func row364() async throws {
        let f = await finder()
        let result = await FindEventsExecutor(finder: f).execute(findCall)
        #expect(result.ok, "\(result)")
        guard case .array(let items)? = result.data["events"] else { Issue.record("no events"); return }
        #expect(items.map { $0["id"]?.stringValue ?? "" } == ["e1", "e2a", "e2b"])
        #expect(items[0]["name"]?.stringValue == "横琴AI嘉年华")
        #expect(items[1]["facts"]?.stringValue?.hasPrefix("场馆：珠海国际会展中心；日期") == true, "\(items[1])")
        #expect(items[2]["facts"]?.stringValue?.hasPrefix("场馆：澳门威尼斯人金光会展中心；日期") == true, "\(items[2])")
        #expect(result.data["next"]?.stringValue?.hasSuffix("同一个活动有几个场馆时分开列出，每个场馆一个 id。") == true)
        // Kept for the conversation: listed again, the same ids; a new conversation starts at e1.
        _ = await FindEventsExecutor(finder: f).execute(findCall)
        #expect(await f.ids.chosen("e2b")?.venue == "澳门威尼斯人金光会展中心")
        await f.ids.reset()
        #expect(await f.ids.chosen("e2b") == nil)
        #expect(await f.ids.ids(for: aie) == ["e1a", "e1b"])
    }

    @Test("T-040zza F-15b §74 row 365: events [e2b], when 下个星期周末 on Fri 11-27: start 12-05; events line has Y; the stop is looked up at Q in 澳门 though the planner wrote P; hall line by=id")
    func row365() async throws {
        let (r, _) = await rig([plannerAnswer(aieAtP), plannerAnswer(aieAtP)])
        let result = await r.run(call(["text": "去看AIE电子展，在威尼斯那个", "days": 2, "city": "珠海",
                                       "events": ["e2b"], "when": "下个星期周末"]))
        #expect(result.ok, "\(result)")
        #expect(result.data["asked"]?["start"]?.stringValue == "2026-12-05", "\(result)")
        #expect(r.line("trip when ") == ["trip when text=下个星期周末 start=2026-12-05"])
        let first = firstMessage(r)
        #expect(first.contains(TripPlannerShape.eventsHead) && first.contains("AIE电子展"), "\(first)")
        let stop = try #require(await r.planner.currentPlan.days[0].stops.first)
        #expect(stop.location == "澳门威尼斯人金光会展中心" && stop.placed && TripPlannerShape.cityOf(stop.place) == "澳门", "\(stop)")
        #expect(stop.event?.start == "2026-12-03" && stop.event?.end == "2026-12-05")
        #expect(r.line("trip event hall ").contains("trip event hall sight=AIE电子展 hall=澳门威尼斯人金光会展中心 by=id"), "\(r.line("trip event hall "))")
        #expect(r.line("trip events read ").first == "trip events read start=2026-12-05 cities=珠海 entries=1 ids=1", "\(r.line("trip events read "))")
    }

    @Test("T-040zza F-15b §74 row 366: when resolved by code (这周末 下周末 下个星期周末 这周六 下周日 明天 12月5号 过几天; 这周末 on a Sunday)")
    func row366() {
        let fri = EventDay("2026-11-27")!, sun = EventDay("2026-11-29")!
        let cases: [(String, String?)] = [("这周末", "2026-11-28"), ("下周末", "2026-12-05"), ("下个星期周末", "2026-12-05"),
                                          ("这周六", "2026-11-28"), ("下周日", "2026-12-06"), ("明天", "2026-11-28"),
                                          ("12月5号", "2026-12-05"), ("过几天", nil), ("周末", "2026-11-28"), ("下星期六", "2026-12-05")]
        for (text, want) in cases { #expect(TripWhen.resolve(text, today: fri)?.description == want, "\(text)") }
        #expect(TripWhen.resolve("这周末", today: sun)?.description == "2026-11-28")
        // A date already past is next year's.
        #expect(TripWhen.resolve("1月3日", today: fri)?.description == "2027-01-03")
    }

    @Test("T-040zza F-15b §66 item 7 with §74 rows 367-368: an unknown id is dropped and recorded; Y in must without its id is turned back once naming e2a, e2b; a second call is planned with §66 item 7")
    func rows367and368() async throws {
        let (r, _) = await rig([plannerAnswer(aieAtP), plannerAnswer(aieAtP)])
        let asked: [String: JSONValue] = ["text": "下个星期周末去AIE电子展", "days": 2, "city": "珠海", "must": ["AIE电子展"],
                                          "events": ["e9"], "when": "下个星期周末"]
        let first = await r.run(call(asked))
        #expect(!first.ok && first.code == .invalidArgument && first.data["field"]?.stringValue == "asked.events", "\(first)")
        #expect(first.data["next"]?.stringValue == "asked.events 没填：AIE电子展有2个场馆（e2a 珠海国际会展中心，e2b 澳门威尼斯人金光会展中心），填司机说的那个场馆的 id；司机没说就问他去哪个。", "\(first)")
        #expect(r.line("trip events id=") == ["trip events id=e9 known=no"])
        #expect(r.model.count == 0)
        let second = await r.run(call(asked, id: "plan2"))
        #expect(second.ok, "\(second)")
        let stop = try #require(await r.planner.currentPlan.days[0].stops.first)
        #expect(stop.location == "珠海国际会展中心", "\(stop)")
        #expect(r.line("trip event hall ").contains("trip event hall sight=AIE电子展 hall=珠海国际会展中心 by=city"), "\(r.line("trip event hall "))")
    }

    @Test("T-040zza F-15b §74 row 369: no start and no when, X in must: the store is read (events line has X), the entry's dates on the stop, no day dates")
    func row369() async throws {
        let days: [[JSONValue]] = [[["name": "横琴AI嘉年华", "city": "珠海", "minutes": 120]]]
        let (r, _) = await rig([plannerAnswer(days), plannerAnswer(days)], listed: false)
        let result = await r.run(call(["text": "去横琴AI嘉年华", "days": 1, "city": "珠海", "must": ["横琴AI嘉年华"]]))
        #expect(result.ok, "\(result)")
        #expect(firstMessage(r).contains(TripPlannerShape.eventsHead), "\(firstMessage(r))")
        #expect(r.line("trip events read ") == ["trip events read start=none cities=珠海 entries=2 ids=0"])
        let text = result.data["plan_text"]?.stringValue ?? ""
        #expect(text.hasPrefix("第1天：") && !text.contains("月"), "\(text)")
        let stop = try #require(await r.planner.currentPlan.days[0].stops.first)
        #expect(stop.event?.start == "2026-11-28" && stop.event?.end == "2026-11-29")
    }

    @Test("T-040zza F-15b §74 row 370: every store city named in the text counts, in text order; a province is not a city")
    func row370() {
        let store = ["珠海", "澳门"]
        func cities(_ c: String) -> [String] { TripPlanner.tripCities(TripAsked(text: "两天", city: c), planCity: nil, storeCities: store) }
        #expect(cities("澳门珠海") == ["澳门", "珠海"])
        #expect(cities("珠海、澳门") == ["珠海", "澳门"])
        #expect(cities("广东省珠海市") == ["珠海"])
        // None from the store: as before §74.
        #expect(TripPlanner.tripCities(TripAsked(text: "两天", city: "广州"), planCity: nil, storeCities: store) == ["广州"])
    }

    @Test("T-040zza F-15b §74 row 371: a linked venue is placed at its first hall (6 shared starting characters); the same name as a plain sight still fails §71's check")
    func row371() async throws {
        let linked: [[JSONValue]] = [[["name": "AIE电子展", "location": "澳门威尼斯人金光会展中心", "city": "澳门", "minutes": 120]]]
        let (r, _) = await rig([plannerAnswer(linked), plannerAnswer(linked)], table: hallTable)
        let result = await r.run(call(["text": "去AIE电子展", "days": 1, "city": "澳门", "events": ["e2b"]]))
        #expect(result.ok, "\(result)")
        let stop = try #require(await r.planner.currentPlan.days[0].stops.first)
        #expect(stop.placed && stop.place.name == "澳门威尼斯人金光会展E馆", "\(stop)")
        #expect(TripSar.hallMatches(venue: "澳门威尼斯人金光会展中心", found: "澳门威尼斯人金光会展E馆"))
        #expect(!TripSar.hallMatches(venue: "澳门威尼斯人金光会展中心", found: "金光会展-展馆A(金光大道)"))

        let plain: [[JSONValue]] = [[["name": "澳门威尼斯人金光会展中心", "city": "澳门", "minutes": 60]]]
        let p = await LookupRig([plannerAnswer(plain), plannerAnswer(plain)], search: AmapLookupSearch(hallTable))
        let r2 = await p.run(call(["text": "澳门一天", "days": 1, "city": "澳门"]))
        #expect(r2.ok, "\(r2)")
        #expect(await p.planner.currentPlan.days[0].stops.first?.placed == false)
    }

    @Test("T-040zza F-15b §74 rows 372-373: a trip with no event and no date words works as before; plan_trip's catalog text has item 3's line before 调用后不用说话")
    func rows372and373() async throws {
        let days: [[JSONValue]] = [[["name": "珠海渔女", "city": "珠海", "minutes": 60]]]
        let (r, _) = await rig([plannerAnswer(days), plannerAnswer(days)])
        let result = await r.run(call(["text": "帮我规划珠海两天", "days": 1, "city": "珠海"]))
        #expect(result.ok, "\(result)")
        #expect(r.line("trip events").isEmpty && r.line("trip when").isEmpty, "\(r.line("trip events"))")
        #expect(!firstMessage(r).contains(TripPlannerShape.eventsHead))
        let line = "司机说喜欢或问某个活动时只回答，不调用；司机要你做行程时，行程里有 find_events 查到的活动，asked.events 填那个活动的 id；同一个活动有几个场馆时，填司机说的那个场馆的 id，司机没说哪个场馆就先问他。asked.when 照司机说日期的原话写（比如「下个星期周末」「这周六」），没说就不写。"
        #expect(ToolCatalog.planTripDescription.contains(line + "调用后不用说话"))
    }

    @Test("T-040zza F-15b §74 row 376: Y chosen by id, open 12-03..12-05; when 这周末 (trip 11-28..11-29): EVENT_CLOSED, no planner call, record line")
    func row376() async throws {
        let (r, _) = await rig([plannerAnswer(aieAtP)])
        let result = await r.run(call(["text": "这周末去AIE电子展", "days": 2, "city": "珠海", "events": ["e2a"], "when": "这周末"]))
        #expect(!result.ok && result.code == .eventClosed, "\(result)")
        #expect(result.data["event"]?.stringValue == "AIE电子展" && result.data["open"]?.stringValue == "2026-12-03～2026-12-05"
                && result.data["trip"]?.stringValue == "2026-11-28～2026-11-29", "\(result)")
        #expect(result.data["next"]?.stringValue == "AIE电子展开放2026-12-03～2026-12-05，行程是2026-11-28～2026-11-29，对不上。跟司机说这两个日期，问他是把行程改到活动开放的日子，还是不去这个活动。")
        #expect(r.model.count == 0)
        #expect(r.line("trip event closed ") == ["trip event closed event=AIE电子展 open=2026-12-03~2026-12-05 trip=2026-11-28~2026-11-29"])
    }

    @Test("T-040zza F-15b §74 row 377: same entry, when 下个星期周末 (trip 12-05..12-06): planned; Y on 12-06 gives §64 item 4's fact")
    func row377() async throws {
        let both: [[JSONValue]] = [[["name": "AIE电子展", "location": "珠海国际会展中心", "city": "珠海", "minutes": 120]],
                                   [["name": "AIE电子展", "location": "珠海国际会展中心", "city": "珠海", "minutes": 120]]]
        let (r, _) = await rig([plannerAnswer(both), plannerAnswer(both)])
        let result = await r.run(call(["text": "下个星期周末去AIE电子展", "days": 2, "city": "珠海", "events": ["e2a"], "when": "下个星期周末"]))
        #expect(result.ok && result.code == nil, "\(result)")
        let counts = r.model.calls.withLock { $0.last?.last?.content ?? "" }
        #expect(counts.contains("AIE电子展开放2026-12-03～2026-12-05，这天是2026-12-06"), "\(counts)")
        #expect(!counts.contains("这天是2026-12-05"), "\(counts)")
    }
}
