import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §66 (T-040zs): an event stop keeps the event and its venue apart, filled by code from the events list.

private let zone = TimeZone(identifier: "Asia/Shanghai")!
private let nov24 = Date(timeIntervalSince1970: 1_795_492_800)  // 2026-11-24 12:00 Asia/Shanghai

private func entry(_ name: String, venue: String, start: String, end: String, venueVia: String = "page",
                   datesVia: String = "page", time: String = "") -> EventEntry {
    EventEntry(name: name, start: start, end: end, datesText: "", venue: venue, city: "珠海",
               sourceURL: "https://example.org/e", sourceSite: "example.org", fetchedAt: nov24,
               venueVia: venueVia, datesVia: datesVia, time: time)
}

/// 横琴AI嘉年华 (venue 珠海国际会展中心7-8号馆, 11-28…29), the PoC's confirmed entry.
private func carnival(time: String = "") -> EventEntry {
    entry("横琴AI嘉年华", venue: "珠海国际会展中心7-8号馆", start: "2026-11-28", end: "2026-11-29", time: time)
}
/// live-info §44: 航展 dates confirmed, no venue found.
private let airshow = entry("第十六届中国航展", venue: "", start: "2026-12-07", end: "2026-12-13", venueVia: "none")
/// live-info §44 item 1a: AIE in two cities, both halls confirmed by the search.
private let aie = entry("AIE电子展", venue: "珠海国际会展中心；澳门威尼斯人金光会展中心", start: "2026-12-03", end: "2026-12-05",
                        venueVia: "search")

private struct NoSearch: EventWebSearcher {
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer { EventSearchAnswer(text: "", sources: []) }
}
private struct NoExtract: EventExtractor {
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        EventModelReply(content: #"{"events":[]}"#)
    }
}

/// A fresh store holding `events` for 珠海 (no search runs).
private func finder(_ events: [EventEntry]) async -> EventFinder {
    let store = EventStore(storage: MemoryEventStorage(), now: { nov24 }, zone: { zone })
    await store.record(events, searched: EventSearchRun.defaultKinds.map { SearchedPair(city: "珠海", kind: $0, kept: 1) },
                       from: "2026-11-24", to: "2026-12-24")
    return EventFinder(store: store, work: nil) { _ in EventSearchRun(searcher: NoSearch(), extractor: NoExtract(), clock: ManualClock()) }
}

private func eventCall(start: String, days: Int = 1) -> ToolCall {
    ToolCall(id: CallID("plan")!, name: "plan_trip", arguments: ["asked": [
        "text": "珠海的活动排进去", "days": .int(Int64(days)), "city": "珠海", "start": .string(start), "notes": ["有活动的话排进去"],
    ]])
}

private let table: [String: [Place]] = [
    "珠海国际会展中心7-8号馆": [mapPlace("珠海国际会展中心", 22.10, city: "珠海市", adcode: "440402")],
    "珠海国际会展中心": [mapPlace("珠海国际会展中心", 22.10, city: "珠海市", adcode: "440402")],
    "澳门威尼斯人金光会展中心": [mapPlace("澳门威尼斯人金光会展中心", 22.14, city: "澳门特别行政区", adcode: "820007")],
    "珠海香山文化艺术中心": [mapPlace("珠海香山文化艺术中心", 22.25, city: "珠海市", adcode: "440402")],
    "珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")],
]

private func rig(_ sights: [[JSONValue]], events: [EventEntry]) async -> LookupRig {
    let r = await LookupRig([plannerAnswer(sights), plannerAnswer(sights)], search: AmapLookupSearch(table))
    await r.planner.setEvents(await finder(events))
    return r
}

private func cards(_ plan: TripPlan, day: Int = 0) -> [TripCard] {
    guard case .cards(let c) = TripScreen.of(plan.days[day], moving: false) else { return [] }
    return c
}

@Suite("T-040zs F-15b §66 an event stop keeps the event and its venue apart, filled by code from the events list")
struct TripEventLinkTests {
    @Test("T-040zs F-15b §66 row 308: sight {name 2026横琴AI嘉年华}: event = 横琴AI嘉年华 11-28…29 from the list; the map looks up 珠海国际会展中心7-8号馆 only; record by=name")
    func row308() async throws {
        let r = await rig([[["name": "2026横琴AI嘉年华", "city": "珠海", "minutes": 120]]], events: [carnival()])
        let result = await r.run(eventCall(start: "2026-11-28"))
        #expect(result.ok, "\(result)")
        #expect(r.search.asked.allSatisfy { $0 == "珠海国际会展中心7-8号馆" } && !r.search.asked.isEmpty, "\(r.search.asked)")
        let stop = try #require(await r.planner.currentPlan.allStops.first?.stop)
        #expect(stop.event?.title == "横琴AI嘉年华" && stop.event?.start == "2026-11-28" && stop.event?.end == "2026-11-29")
        #expect(stop.event?.linked == true && stop.location == "珠海国际会展中心7-8号馆" && stop.placed)
        // One line per linked sight in the call (two rounds), the planner's name kept as `sight=`.
        #expect(r.line("trip event link ") == ["trip event link sight=2026横琴AI嘉年华 event=横琴AI嘉年华 venue=珠海国际会展中心7-8号馆 by=name"])
        // The text compared: spaces, punctuation and a leading year removed; the longest entry name wins.
        #expect(TripPlannerShape.linkKey("2026 横琴·AI嘉年华！") == "横琴AI嘉年华")
        let short = entry("AI嘉年华", venue: "某馆", start: "2026-11-28", end: "2026-11-28")
        let won = TripPlannerShape.link(.init(name: "2026横琴AI嘉年华"), events: [short, carnival()])
        #expect(won?.entry.name == "横琴AI嘉年华" && won?.by == "name")
    }

    @Test("T-040zs F-15b §66 row 309: sight {name 珠海国际会展中心7-8号馆, event title AI嘉年华}: linked by=title; the event's dates from the list")
    func row309() async throws {
        let sight: JSONValue = ["name": "珠海国际会展中心7-8号馆", "city": "珠海", "minutes": 120,
                                "event": ["title": "AI嘉年华", "start": "2026-11-29", "end": "2026-12-31"]]
        let r = await rig([[sight]], events: [carnival()])
        _ = await r.run(eventCall(start: "2026-11-28"))
        let stop = try #require(await r.planner.currentPlan.allStops.first?.stop)
        #expect(stop.event?.title == "横琴AI嘉年华" && stop.event?.start == "2026-11-28" && stop.event?.end == "2026-11-29", "\(stop)")
        #expect(r.line("trip event link ").first?.hasSuffix("by=title") == true, "\(r.line("trip event link "))")
    }

    @Test("T-040zs F-15b §66 row 310: sight {name 珠海香山文化艺术中心, event 动漫游园会}, no list entry: kept as written; card shows the venue and 动漫游园会 (§67 item 7: no dates)")
    func row310() async throws {
        let sight: JSONValue = ["name": "珠海香山文化艺术中心", "city": "珠海", "minutes": 120,
                                "event": ["title": "动漫游园会", "start": "2026-11-28", "end": "2026-11-29"]]
        let r = await rig([[sight]], events: [carnival()])
        let result = await r.run(eventCall(start: "2026-11-28"))
        #expect(result.ok, "\(result)")
        #expect(Set(r.search.asked) == ["珠海香山文化艺术中心"])
        let card = try #require(cards(await r.planner.currentPlan).first)
        #expect(card.name == "珠海香山文化艺术中心" && card.event == "动漫游园会", "\(card)")
        #expect(r.line("trip event link ").isEmpty)
        #expect(result.data["plan_text"]?.stringValue == "第1天 · 11月28日 周六：珠海香山文化艺术中心（动漫游园会）", "\(result)")
    }

    @Test("T-040zs F-15b §66 row 311: sight {name 珠海渔女}, no match: unchanged, no record line")
    func row311() async throws {
        let r = await rig([[["name": "珠海渔女", "city": "珠海", "minutes": 60]]], events: [carnival(), airshow, aie])
        let result = await r.run(eventCall(start: "2026-11-28"))
        let stop = try #require(await r.planner.currentPlan.allStops.first?.stop)
        #expect(stop.asked == "珠海渔女" && stop.location == "珠海渔女" && stop.event == nil && stop.placed)
        #expect(r.line("trip event link ").isEmpty)
        #expect(result.data["plan_text"]?.stringValue == "第1天 · 11月28日 周六：珠海渔女")
    }

    @Test("T-040zs F-15b §66 row 312: a plan with a linked stop: plan_text and the trip line give 「横琴AI嘉年华（珠海国际会展中心7-8号馆，11-28–11-29）」; the card the venue's map name and the event line")
    func row312() async throws {
        let r = await rig([[["name": "2026横琴AI嘉年华", "city": "珠海", "minutes": 120]]], events: [carnival()])
        let result = await r.run(eventCall(start: "2026-11-28"))
        let want = "横琴AI嘉年华（珠海国际会展中心7-8号馆，11-28–11-29）"
        #expect(result.data["plan_text"]?.stringValue == "第1天 · 11月28日 周六：" + want, "\(result)")
        let plan = await r.planner.currentPlan
        #expect(TripPlanJSON.noteLine(plan)?.contains("\"name\":\"\(want)\"") == true)
        let card = try #require(cards(plan).first)
        #expect(card.name == "横琴AI嘉年华" && card.place == "珠海国际会展中心" && card.event == "横琴AI嘉年华 · 2026-11-28～2026-11-29")
        // Saved and reopened, the stop is still linked.
        let again = TripPlanFile.decode(TripPlanFile.encode(plan))
        #expect(again.allStops.first?.stop.label == want)
    }

    @Test("T-040zs F-15b §66 row 313a: 第十六届中国航展 with no venue; sight {name 航展, location 珠海国际航展中心}: linked; no map call; card 「场馆未找到」 + 珠海; trip line 「第十六届中国航展（场馆未找到，12-07–12-13）」")
    func row313a() async throws {
        let sight: JSONValue = ["name": "航展", "location": "珠海国际航展中心", "city": "珠海", "minutes": 180]
        let r = await rig([[sight]], events: [airshow])
        let result = await r.run(eventCall(start: "2026-12-07"))
        #expect(result.ok, "\(result)")
        #expect(r.search.asked.isEmpty, "\(r.search.asked)")
        let plan = await r.planner.currentPlan
        let stop = try #require(plan.allStops.first?.stop)
        #expect(stop.asked == "第十六届中国航展" && !stop.placed && !stop.mapLookup && stop.event?.venueFound == false)
        let card = try #require(cards(plan).first)
        #expect(card.name == "第十六届中国航展" && card.place == "场馆未找到 · 珠海" && card.district == nil, "\(card)")
        #expect(card.event == "第十六届中国航展 · 2026-12-07～2026-12-13")
        let want = "第十六届中国航展（场馆未找到，12-07–12-13）"
        #expect(result.data["plan_text"]?.stringValue == "第1天 · 12月7日 周一：" + want, "\(result)")
        #expect(TripPlanJSON.noteLine(plan)?.contains(want) == true)
        // Not a map miss: no not_placed, the counts say 场馆未找到, the record says venue=none.
        #expect(result.data["not_placed"] == nil)
        let counts = r.model.calls.withLock { $0 }[1].last?.content ?? ""
        #expect(counts.contains("第十六届中国航展=场馆未找到") && !counts.contains("地图没找到"), "\(counts)")
        #expect(r.line("trip event link ") == ["trip event link sight=航展 event=第十六届中国航展 venue=none by=name"])
        // No navigation and no background lookup.
        await r.planner.retriesSettled()
        #expect(r.search.asked.isEmpty)
        let next = await r.run(ToolCall(id: CallID("n1")!, name: "trip_next", arguments: [:]))
        #expect(!next.ok, "\(next)")
        // No confirmed dates: 「日期未找到」, not checked against the day.
        let noDates = TripPlannerShape.linkedEvent(entry("某展", venue: "", start: "2026-12-01", end: "2026-12-02",
                                                        venueVia: "none", datesVia: "none"), hall: nil)
        #expect(noDates.shortDates == "日期未找到" && TripPlannerShape.eventFact(noDates, date: EventDay("2026-12-20")) == nil)
    }

    @Test("T-040zs F-15b §66 row 313b: AIE with both halls; a 澳门 stop with location 珠海国际会展中心 gets 澳门威尼斯人金光会展中心; a 珠海 stop with location 横琴 gets 珠海国际会展中心")
    func row313b() async throws {
        let days: [[JSONValue]] = [
            [["name": "AIE", "location": "珠海国际会展中心", "city": "澳门", "minutes": 120]],
            [["name": "AIE电子展", "location": "横琴", "city": "珠海", "minutes": 120]],
        ]
        let r = await rig(days, events: [aie])
        let result = await r.run(eventCall(start: "2026-12-04", days: 2))
        #expect(result.ok, "\(result)")
        let plan = await r.planner.currentPlan
        let d1 = try #require(plan.days[0].stops.first), d2 = try #require(plan.days[1].stops.first)
        #expect(d1.location == "澳门威尼斯人金光会展中心" && d1.placed && d1.place.adcode == "820007", "\(d1)")
        #expect(d2.location == "珠海国际会展中心" && d2.placed, "\(d2)")
        // The pure rule: the planner's location when it is a hall in the stop's city; else the hall there; else the first.
        let cities = ["珠海国际会展中心": "珠海市", "澳门威尼斯人金光会展中心": "澳门"]
        #expect(TripPlannerShape.hall(for: aie, location: "澳门威尼斯人金光会展中心", city: "澳门", hallCity: cities) == "澳门威尼斯人金光会展中心")
        #expect(TripPlannerShape.hall(for: aie, location: nil, city: "珠海", hallCity: cities) == "珠海国际会展中心")
        #expect(TripPlannerShape.hall(for: aie, location: nil, city: "深圳", hallCity: cities) == "珠海国际会展中心")
        #expect(TripPlannerShape.hall(for: aie, location: nil, city: "澳门", hallCity: [:]) == "珠海国际会展中心")
    }

    @Test("T-040zs F-15b §66 row 313c: day from 09:00: 150-min stop, 23-min drive, event at 16:00: no line; six 90-min stops before it: 「…16:00开始，按行程…才到」; a leg into 澳门 with no drive time: 「…16:00开始，到澳门的车程查不到」")
    func row313c() async throws {
        let t = "横琴AI嘉年华"
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: [(150, nil, "珠海")], legIn: 23, city: "珠海") == nil)
        let six = [(minutes: 150, legIn: Int?.none, city: String?("珠海"))] + Array(repeating: (minutes: 90, legIn: Int?(20), city: String?("珠海")), count: 6)
        // 09:00 + 150 + 6×90 + 6×20 + 23 = 22:53.
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: six, legIn: 23, city: "珠海") == "横琴AI嘉年华16:00开始，按行程22:53才到")
        let macau = [(minutes: 150, legIn: Int?.none, city: String?("珠海")), (minutes: 60, legIn: Int?(23), city: String?("珠海"))]
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: macau, legIn: nil, city: "澳门") == "横琴AI嘉年华16:00开始，到澳门的车程查不到")
        // No drive table for the whole day: the leg across the border is named.
        let none = [(minutes: 150, legIn: Int?.none, city: String?("珠海")), (minutes: 60, legIn: Int?.none, city: String?("珠海市"))]
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: none, legIn: nil, city: "澳门特别行政区") == "横琴AI嘉年华16:00开始，到澳门的车程查不到")
        // 15 minutes before the start is on time; one minute later is counted.
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: [(405, nil, "珠海")], legIn: 0, city: "珠海") == nil)
        #expect(TripPlannerShape.startFact(title: t, time: "16:00", before: [(406, nil, "珠海")], legIn: 0, city: "珠海") == "横琴AI嘉年华16:00开始，按行程15:46才到")
        // Wired into the counts and the card: a start time from the list; no drive table in this rig.
        let r = await rig([[["name": "珠海渔女", "city": "珠海", "minutes": 60], ["name": "AI嘉年华", "city": "珠海", "minutes": 120]]],
                          events: [carnival(time: "16:00")])
        _ = await r.run(eventCall(start: "2026-11-28"))
        let counts = r.model.calls.withLock { $0 }[1].last?.content ?? ""
        #expect(counts.contains("横琴AI嘉年华16:00开始，到珠海的车程查不到"), "\(counts)")
        #expect(!TripPlannerShape.adviceWords.contains(where: { counts.replacingOccurrences(of: "开车", with: "").contains($0) }))
        let card = cards(await r.planner.currentPlan).first { $0.name == "横琴AI嘉年华" }
        #expect(card?.event == "横琴AI嘉年华 · 2026-11-28～2026-11-29 · 16:00开始", "\(String(describing: card))")
    }
}
