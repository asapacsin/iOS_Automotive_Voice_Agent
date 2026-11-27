import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §73 (T-040zz): each stop carries a hidden map-search word, `query`; only it goes to the map.

private func cards(_ plan: TripPlan) -> [TripCard] {
    if case .cards(let c) = TripScreen.of(plan: plan, moving: false) { return c }
    return []
}

/// 高德 fixture of rows 361-362: the planner's 「珠海大剧院」 is not on 高德; the driver's 「日月贝」 is.
private let riyuebei: [String: [Place]] = [
    "珠海大剧院": [mapPlace("长隆剧院", 22.10, city: "珠海市"), mapPlace("华发中演大剧院", 22.20, city: "珠海市")],
    "日月贝": [mapPlace("日月贝(公交站)", 22.26, city: "珠海市"), mapPlace("珠海日月贝", 22.27, city: "珠海市")],
]
private let riyuebeiSight: JSONValue = ["name": "日月贝", "location": "珠海大剧院", "query": "珠海大剧院", "city": "珠海", "minutes": 60]

@Suite("T-040zz F-15b §73 each stop carries a hidden map-search word, query; only it goes to the map")
struct TripStopQueryTests {
    @Test("T-040zz F-15b §73 row 353: query 长隆海洋王国 is looked up with city 珠海市; 「珠海长隆海洋王国」 passes the name check; placed")
    func row353() async {
        let sight: JSONValue = ["name": "长隆海洋王国", "location": "珠海长隆海洋王国", "query": "长隆海洋王国", "city": "珠海市", "minutes": 300]
        let search = AmapLookupSearch(["珠海市|长隆海洋王国": [mapPlace("珠海长隆海洋王国", 22.10, city: "珠海市")]])
        let rig = await LookupRig([plannerAnswer([[sight]]), plannerAnswer([[sight]])], search: search)
        let r = await rig.run(planCall())
        #expect(r.ok, "\(r)")
        let asked = search.requests.withLock { $0 }
        #expect(asked.allSatisfy { $0.keywords == "长隆海洋王国" } && asked.first?.city == "珠海市", "\(asked)")
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.name == "珠海长隆海洋王国")
        #expect(stop?.asked == "长隆海洋王国" && stop?.location == "珠海长隆海洋王国" && stop?.query == "长隆海洋王国")
        #expect(rig.line("trip lookup retry=nocity").isEmpty)
    }

    @Test("T-040zz F-15b §73 row 354: the same sight without query looks up location (today's behaviour)")
    func row354() async {
        let sight: JSONValue = ["name": "长隆海洋王国", "location": "珠海长隆海洋王国", "city": "珠海市", "minutes": 300]
        let search = AmapLookupSearch(["珠海市|珠海长隆海洋王国": [mapPlace("珠海长隆海洋王国", 22.10, city: "珠海市")]])
        let rig = await LookupRig([plannerAnswer([[sight]]), plannerAnswer([[sight]])], search: search)
        _ = await rig.run(planCall())
        #expect(Set(search.asked) == ["珠海长隆海洋王国"], "\(search.asked)")
        #expect(await rig.planner.currentPlan.allStops.first?.stop.query == "珠海长隆海洋王国")
        let parsed = TripPlannerShape.parse(#"{"days":[{"sights":[{"name":"A"},{"name":"B","location":"C"},{"name":"D","location":"E","query":"F"}],"stay":{"name":"G","query":"H"}}],"done":true}"#)
        #expect(parsed?.days.first?.sights.map(\.lookup) == ["A", "C", "F"])
        #expect(parsed?.days.first?.stay?.lookup == "H")
    }

    @Test("T-040zz F-15b §73 row 355: a saved plan from before §73 loads with query = location; a query written now round-trips")
    func row355() throws {
        let old = #"{"version":1,"plan":{"currentDay":1,"days":[[{"asked":"日月贝","location":"珠海大剧院","id":"p1","name":"珠海日月贝","lat":22.27,"lng":113.5}]]}}"#
        let plan = try #require(TripPlanFile.current(from: Data(old.utf8)))
        let stop = try #require(plan.allStops.first?.stop)
        #expect(stop.query == "珠海大剧院" && stop.location == "珠海大剧院")
        #expect(TripPlanFile.encode(stop).query == nil)
        var list = TripList()
        list.arrange([TripStop(index: 0, asked: "长隆海洋王国", place: mapPlace("珠海长隆海洋王国", 22.1, city: "珠海市"),
                               distanceMeters: nil, location: "珠海长隆海洋王国", query: "长隆海洋王国")])
        let again = TripPlanFile.decode(TripPlanFile.encode(TripPlan(name: nil, days: [list])))
        #expect(again.allStops.first?.stop.query == "长隆海洋王国")
    }

    @Test("T-040zz F-15b §73 row 356: query is on no card, trip line, plan_text or tool result")
    func row356() async throws {
        let sight: JSONValue = ["name": "海洋王国", "location": "珠海长隆海洋王国", "query": "QWORD", "city": "珠海", "minutes": 300]
        let missing: JSONValue = ["name": "大剧院", "location": "珠海大剧院", "query": "QMISS", "city": "珠海", "minutes": 60]
        let search = AmapLookupSearch(["QWORD": [mapPlace("珠海长隆海洋王国", 22.10, city: "珠海市")]])
        let rig = await LookupRig([plannerAnswer([[sight, missing]]), plannerAnswer([[sight, missing]])], search: search)
        let r = await rig.run(planCall())
        #expect(search.asked.contains("QWORD"))
        let plan = await rig.planner.currentPlan
        #expect(plan.allStops.first?.stop.query == "QWORD")
        let shown = [String(describing: cards(plan)), TripPlanJSON.noteLine(plan) ?? "", r.data["plan_text"]?.stringValue ?? "",
                     TripPlanJSON.text(.object(r.data))]
        for text in shown { #expect(!text.contains("QWORD") && !text.contains("QMISS"), "\(text)") }
        // §73 item 5: the planner gets its own query back in the plan it changes.
        #expect(TripPlanJSON.text(TripPlannerShape.shape(plan)).contains("\"query\":\"QWORD\""))
    }

    @Test("T-040zz F-15b §73 row 357: a lookup reaching the picker records trip lookup … query=… and trip pick candidates …")
    func row357() async {
        let picker = FakePicker(["珠海大剧院": nil, "日月贝": nil])
        let rig = await LookupRig([plannerAnswer([[riyuebeiSight]]), plannerAnswer([[riyuebeiSight]])],
                                  search: AmapLookupSearch(riyuebei), picker: picker)
        _ = await rig.run(planCall())
        #expect(rig.line("trip pick candidates query=珠海大剧院 n=2 names=长隆剧院｜华发中演大剧院").count >= 1, "\(rig.lines.withLock { $0 })")
        #expect(TripPlanner.lookupMissLine(name: "日月贝", query: "珠海大剧院", city: "珠海", reason: "none")
            == "trip lookup name=日月贝 query=珠海大剧院 city=珠海 info=none")
        let many = (1...7).map { mapPlace("P\($0)", 22, city: "珠海市") }
        #expect(TripPlanner.pickCandidatesLine(query: "Q", places: many) == "trip pick candidates query=Q n=7 names=P1｜P2｜P3｜P4｜P5")
    }

    @Test("T-040zz F-15b §73 item 6, row 358: TripPlannerShape.system has exactly item 6's two changes")
    func row358() {
        let s = TripPlannerShape.system
        #expect(s.contains(#"{"name": "司机怎么叫它", "location": "地图上要搜的地点全名", "query": "在地图App搜索框里会输入的最短地点名", "city": "所在城市", "minutes": 停留分钟,"#))
        #expect(s.contains(#""stay": {"name": "当晚住的地方全名", "query": "在地图App搜索框里会输入的最短地点名", "city": "城市"} 或 null"#))
        let lines = s.components(separatedBy: "\n")
        let i = lines.firstIndex { $0.hasPrefix("- name 写司机怎么叫它；location") }
        #expect(i.map { lines[$0 + 1] } == "- query 写人在地图App里搜这个地方会输入的词：最短的常用名，不带城市、括号和说明，城市写在 city；它只用来搜地图，不给司机看。")
        #expect(s.components(separatedBy: "query").count - 1 == 3)
    }

    @Test("T-040zz F-15b §73 item 2b, row 361: 珠海大剧院 not placed; 日月贝 looked up once more; picker option 2 places it at 珠海日月贝")
    func row361() async {
        let picker = FakePicker(["珠海大剧院": nil, "日月贝": 1])
        let rig = await LookupRig([plannerAnswer([[riyuebeiSight]]), plannerAnswer([[riyuebeiSight]])],
                                  search: AmapLookupSearch(riyuebei), picker: picker)
        let r = await rig.run(planCall())
        #expect(r.ok)
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.name == "珠海日月贝", "\(String(describing: stop))")
        #expect(stop?.asked == "日月贝" && stop?.location == "珠海大剧院")
        #expect(rig.line("trip lookup fallback=name name=日月贝 query=珠海大剧院 found=yes").count >= 1, "\(rig.lines.withLock { $0 })")
        #expect(picker.calls.withLock { $0 }.prefix(2) == [["珠海大剧院"], ["日月贝"]])
    }

    @Test("T-040zz F-15b §73 item 2b, row 362: the picker answers none for 日月贝 too: not_found, 「地图没找到 珠海大剧院（日月贝）」, found=no")
    func row362() async {
        let picker = FakePicker(["珠海大剧院": nil, "日月贝": nil])
        let rig = await LookupRig([plannerAnswer([[riyuebeiSight]]), plannerAnswer([[riyuebeiSight]])],
                                  search: AmapLookupSearch(riyuebei), picker: picker)
        let r = await rig.run(planCall())
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == false)
        let missed: JSONValue? = if case .array(let a)? = r.data["not_placed"] { a.first } else { nil }
        #expect(missed?["map"] == "地图没找到 珠海大剧院（日月贝）", "\(r)")
        #expect(missed?["reason"] == "not_found")
        #expect(rig.line("trip lookup fallback=name name=日月贝 query=珠海大剧院 found=no").count >= 1)
    }

    @Test("T-040zz F-15b §73 item 2b, row 363: no fallback lookup for a sight with event or with name = query")
    func row363() async {
        let event: JSONValue = ["name": "灯光节", "location": "珠海大剧院", "query": "珠海大剧院", "city": "珠海", "minutes": 60,
                                "event": ["title": "灯光节", "start": "2026-11-28", "end": "2026-11-29"]]
        let same: JSONValue = ["name": "珠海大剧院", "query": "珠海大剧院", "city": "珠海", "minutes": 60]
        for sight in [event, same] {
            let search = AmapLookupSearch(riyuebei)
            let rig = await LookupRig([plannerAnswer([[sight]]), plannerAnswer([[sight]])], search: search,
                                      picker: FakePicker(["珠海大剧院": nil]))
            _ = await rig.run(planCall())
            #expect(!search.asked.contains("灯光节") && rig.line("trip lookup fallback=").isEmpty, "\(search.asked)")
        }
    }
}
