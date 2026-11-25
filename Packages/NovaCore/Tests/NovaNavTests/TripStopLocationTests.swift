import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §67 (T-040zt): every stop has a name and a location; only the location goes to the map.

private let zhuhaiTable: [String: [Place]] = [
    "珠海|香山文化艺术中心": [mapPlace("珠海香山文化艺术中心", 22.25, city: "珠海市")],
    "珠海|珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市")],
]

private func cards(_ plan: TripPlan) -> [TripCard] {
    if case .cards(let c) = TripScreen.of(plan: plan, moving: false) { return c }
    return []
}

@Suite("T-040zt F-15b §67 every stop has a name and a location; only the location goes to the map")
struct TripStopLocationTests {
    @Test("T-040zt F-15b §67 row 314: sight {name 动漫游园会, location 香山文化艺术中心}: the map looks up 香山文化艺术中心 only; card title 动漫游园会, line under it the map's place")
    func row314() async {
        let sight: JSONValue = ["name": "动漫游园会", "location": "香山文化艺术中心", "city": "珠海", "minutes": 120]
        let rig = await LookupRig([plannerAnswer([[sight]]), plannerAnswer([[sight]])], search: AmapLookupSearch(zhuhaiTable))
        let r = await rig.run(planCall())
        #expect(r.ok, "\(r)")
        #expect(Set(rig.search.asked) == ["香山文化艺术中心"], "\(rig.search.asked)")
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.asked == "动漫游园会" && stop?.location == "香山文化艺术中心" && stop?.place.name == "珠海香山文化艺术中心")
        let card = cards(await rig.planner.currentPlan).first
        #expect(card?.name == "动漫游园会" && card?.place == "珠海香山文化艺术中心", "\(String(describing: card))")
        // §67 item 4: plan_text and the trip line give 「<name>（<place name>）」.
        #expect(r.data["plan_text"]?.stringValue == "第1天：动漫游园会（珠海香山文化艺术中心）")
        #expect(TripPlanJSON.noteLine(await rig.planner.currentPlan)?.contains("\"name\":\"动漫游园会（珠海香山文化艺术中心）\"") == true)
    }

    @Test("T-040zt F-15b §67 row 315: sight {name 珠海渔女}: location = 珠海渔女; unchanged behaviour")
    func row315() async {
        let sight: JSONValue = ["name": "珠海渔女", "city": "珠海", "minutes": 60]
        let rig = await LookupRig([plannerAnswer([[sight]]), plannerAnswer([[sight]])], search: AmapLookupSearch(zhuhaiTable))
        let r = await rig.run(planCall())
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.location == "珠海渔女" && stop?.asked == "珠海渔女")
        #expect(Set(rig.search.asked) == ["珠海渔女"])
        #expect(r.data["plan_text"]?.stringValue == "第1天：珠海渔女")
        #expect(cards(await rig.planner.currentPlan).first?.place == nil)
        // The planner shape parses `location`; one equal to `name` is the same as none.
        let parsed = TripPlannerShape.parse(#"{"days":[{"sights":[{"name":"A","location":"A"},{"name":"B","location":"C"}],"stay":null}],"done":true}"#)
        #expect(parsed?.days.first?.sights.map(\.location) == [nil, "C"])
        #expect(parsed?.days.first?.sights.map(\.lookup) == ["A", "C"])
    }

    @Test("T-040zt F-15b §67 row 316: a saved plan from before §67 loads; location = asked")
    func row316() throws {
        let old = #"{"version":1,"plan":{"currentDay":1,"days":[[{"asked":"大三巴","id":"p1","name":"大三巴牌坊","lat":22.19,"lng":113.54}]]}}"#
        let plan = try #require(TripPlanFile.current(from: Data(old.utf8)))
        let stop = try #require(plan.allStops.first?.stop)
        #expect(stop.location == "大三巴" && stop.asked == "大三巴")
        // A location written now survives the file round trip; one equal to asked is not written.
        var list = TripList()
        list.arrange([TripStop(index: 0, asked: "动漫游园会", place: mapPlace("珠海香山文化艺术中心", 22.25, city: "珠海市"),
                               distanceMeters: nil, location: "香山文化艺术中心")])
        let again = TripPlanFile.decode(TripPlanFile.encode(TripPlan(name: nil, days: [list])))
        #expect(again.allStops.first?.stop.location == "香山文化艺术中心")
        #expect(TripPlanFile.encode(stop).location == nil)
    }

    @Test("T-040zt F-15b §67 row 317: location not found: counts and she see 「地图没找到 香山文化艺术中心（动漫游园会）」")
    func row317() async {
        let sight: JSONValue = ["name": "动漫游园会", "location": "香山文化艺术中心", "city": "珠海", "minutes": 120]
        let rig = await LookupRig([plannerAnswer([[sight]], done: false), plannerAnswer([[sight]])], search: AmapLookupSearch([:]))
        let r = await rig.run(planCall())
        let counts = rig.model.calls.withLock { $0 }[1].last?.content ?? ""
        #expect(counts.contains("地图没找到 香山文化艺术中心（动漫游园会）"), "\(counts)")
        #expect(rig.line("trip planner text counts=").first?.contains("地图没找到 香山文化艺术中心（动漫游园会）") == true)
        let missed: JSONValue? = if case .array(let a)? = r.data["not_placed"] { a.first } else { nil }
        #expect(missed?["name"] == "动漫游园会" && missed?["location"] == "香山文化艺术中心")
        #expect(missed?["map"] == "地图没找到 香山文化艺术中心（动漫游园会）", "\(r)")
        #expect(Set(rig.search.asked) == ["香山文化艺术中心"])
    }

    @Test("T-040zt F-15b §67 item 5: the planner system text has exactly item 5's three changes")
    func item5() {
        let s = TripPlannerShape.system
        #expect(s.contains(#"{"name": "司机怎么叫它", "location": "地图上要搜的地点全名", "city": "所在城市", "minutes": 停留分钟, "event": {"title": "活动名", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD"} 只有活动才写}"#))
        #expect(s.contains("- name 写司机怎么叫它；location 写能在地图上搜到的地点全名（活动、演出这类不是地点的，写它的场馆）；name 本身就是地点时 location 可以不写。city 写它真正所在的城市。"))
        #expect(s.contains("- 只在某几天开放的活动，name 写活动名，location 写场馆全名，event 写活动名和开放日期，照给你的活动表写；只能排在开放的那天。"))
        #expect(!s.contains("地点写能在地图上搜到的全名"))
    }
}
