import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §54 (T-040zg): a trip to a new place is a new plan. Sights A–C near Sapporo; 关闸 in Macau; 近处 15 km away.
private let table: [String: [Place]] = [
    "A": [spot("A", lat: 43.00, lng: 141.35)], "B": [spot("B", lat: 43.01, lng: 141.35)],
    "C": [spot("C", lat: 43.02, lng: 141.35)],
    "关闸": [spot("关闸", lat: 22.216, lng: 113.549)],
    "近处": [spot("近处", lat: 43.13, lng: 141.40)],
]

private func stop(_ id: String? = nil, name: String? = nil, role: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = [:]
    if let id { o["id"] = .string(id) }
    if let name { o["name"] = .string(name) }
    if let role { o["role"] = .string(role) }
    return .object(o)
}

private func setPlan(_ days: [[JSONValue]]) -> ToolCall {
    trip("set_trip_plan", ["days": .array(days.map { .array($0) })])
}

private func rigWithPlan(_ search: TripSearch) async -> (TripRig, [String: String]) {
    let rig = await TripRig(search: search)
    _ = await rig.run(setPlan([["A", "B", "C"].map { stop(name: $0) }]))
    var ids: [String: String] = [:]
    for s in await rig.planner.currentPlan.allStops { ids[s.stop.place.name] = s.stop.id }
    return (rig, ids)
}

@Suite("T-040zg F-15b §54 a new place is a new plan")
struct TripNewTripTests {
    @Test("T-040zg F-15b row 218: make_trip_list and set_trip_plan texts say when to use each")
    func row218() {
        #expect(ToolCatalog.makeTripListDescription.contains("会替换旧清单。司机说去一个新地方、规划新的行程（比如有东京的行程时说「规划澳门两天」），就用这个，不要用 set_trip_plan 改旧行程。"))
        #expect(ToolCatalog.setTripPlanDescription.hasPrefix("修改行程：只用来改屏幕上这份行程（加减地点、换酒店、调顺序）；司机要规划去别的城市或国家，用 make_trip_list。"))
    }

    @Test("F-15b row 219: kept ids plus 关闸 as start: PLAN_CHECK new_trip, plan unchanged, next says make_trip_list")
    func row219() async {
        let (rig, ids) = await rigWithPlan(TripSearch(table))
        let before = await rig.planner.currentPlan
        let r = await rig.run(setPlan([[stop(name: "关闸", role: "start"), stop(ids["A"]), stop(ids["B"]), stop(ids["C"])]]))
        #expect(r.code == .planCheck && r.data["facts"]?["new_trip"] == true, "\(r)")
        #expect(r.data["next"]?.stringValue?.contains("make_trip_list") == true)
        #expect(await rig.planner.currentPlan == before)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip set days=1 stops=4 kept=3 new=1 ") && $0.contains(" check=new_trip ") })
    }

    @Test("F-15b row 220: 关闸 not found near the trip, found by the second search: same refusal")
    func row220() async {
        let search = TripSearch(table, lateAnswer: ["关闸": 1])
        let (rig, ids) = await rigWithPlan(search)
        let before = await rig.planner.currentPlan
        let r = await rig.run(setPlan([[stop(name: "关闸", role: "start"), stop(ids["A"]), stop(ids["B"])]]))
        #expect(r.code == .planCheck && r.data["facts"]?["new_trip"] == true, "\(r)")
        #expect(search.asked.withLock { $0.filter { $0 == "关闸" }.count } >= 2)
        #expect(await rig.planner.currentPlan == before)
    }

    @Test("F-15b row 221: a place 15 km from the kept stops is an edit")
    func row221() async {
        let (rig, ids) = await rigWithPlan(TripSearch(table))
        let r = await rig.run(setPlan([[stop(ids["A"]), stop(ids["B"]), stop(ids["C"]), stop(name: "近处")]]))
        #expect(r.ok && r.data["facts"]?["new_trip"] == nil, "\(r)")
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.name).contains("近处"))
    }

    @Test("F-15b row 222: every stop new (no ids) in Macau is saved; isForeign by country group and distance")
    func row222() async {
        let (rig, _) = await rigWithPlan(TripSearch(table))
        let r = await rig.run(setPlan([[stop(name: "关闸")]]))
        #expect(r.ok, "\(r)")
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.name) == ["关闸"])
        let tokyo = Place(id: "t", name: "T", address: nil, coordinate: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .wgs84),
                          distanceMeters: nil, countryCode: "JP")
        let macau = Place(id: "m", name: "M", address: nil, coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02),
                          distanceMeters: nil, countryCode: "MO")
        let zhuhai = Place(id: "z", name: "Z", address: nil, coordinate: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02),
                           distanceMeters: nil)
        #expect(TripPlanner.isForeign(macau, kept: [tokyo], kilometres: 300))
        #expect(!TripPlanner.isForeign(zhuhai, kept: [macau], kilometres: 300))
    }
}
