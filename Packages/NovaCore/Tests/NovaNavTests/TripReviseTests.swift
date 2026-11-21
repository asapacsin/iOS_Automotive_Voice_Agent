import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// §49 (T-040u) with §52 (T-040zb): a `trip_needs_fix` answered as a model that changes nothing would (the same plan
/// written back by id with `set_trip_plan`), until the normal `trip_list` comes back (at most 2 rounds). For tests of
/// earlier sections whose plans now fail a check.
func settle(_ rig: TripRig, _ first: ToolResult) async -> ToolResult {
    var r = first
    var n = 0
    while r.data["status"] == "trip_needs_fix", n < TripPlanner.maxFixRounds + 1 {
        r = await rig.run(await sameCall(rig))
        n += 1
    }
    return r
}

/// The current plan written back unchanged, every stop by id.
func sameCall(_ rig: TripRig) async -> ToolCall { await sameCall(rig.planner) }

func sameCall(_ planner: TripPlanner) async -> ToolCall {
    let plan = await planner.currentPlan
    let d: [JSONValue] = plan.days.map { day in .array(day.stops.map { .object(["id": .string($0.id)]) }) }
    return trip("set_trip_plan", ["days": .array(d)])
}

/// Places north of the origin; every drive between two different points is 20 minutes, except to or from 远方 (3 hours).
private let farLat = 36.5
private let places: [String: [Place]] = {
    var t: [String: [Place]] = [:]
    for (i, n) in ["A", "B", "C", "D", "G"].enumerated() { t[n] = [spot(n, lat: 39.01 + Double(i) * 0.001, lng: 117.20)] }
    t["远方"] = [spot("远方", lat: farLat, lng: 117.20)]
    return t
}()
private let times: @Sendable (GeoCoordinate, GeoCoordinate) -> Int? = { a, b in
    a == b ? 0 : (a.latitude == farLat || b.latitude == farLat) ? 10_800 : 1_200
}

/// 「酒店」 around a point: three hotels 0.001° apart going north, nearest first, named by the point.
private let threeHotels: @Sendable (GeoCoordinate) -> [Place] = { center in
    let tag = Int((center.latitude * 10_000).rounded())
    return (1...3).map { k in spot("酒店\(tag)-\(k)", lat: center.latitude + Double(k) * 0.001, lng: center.longitude) }
}

private func item(_ name: String, _ minutes: Int, _ importance: Int = 3) -> JSONValue {
    ["name": .string(name), "minutes": .int(Int64(minutes)), "importance": .int(Int64(importance))]
}
private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}

@Suite("T-040u F-15b §49 the model revises the plan after code checks it")
struct TripReviseTests {
    @Test("F-15b row 127: plain strings are importance 3; optional=false/true are 3 / 1; importance is kept and saved")
    func row127() {
        let items = TripPlanner.items([.string("A"), ["name": "B", "optional": false], ["name": "C", "optional": true],
                                       ["name": "D", "importance": 2], ["name": "E", "importance": 9]])
        #expect(items.map(\.importance) == [3, 3, 1, 2, 3])
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [item("A", 60, 2)], "wishes": "酒店靠近车站"])) == nil)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [item("A", 60, 4)]])) == .invalidFields)
        let stop = TripStop(index: 1, asked: "D", place: spot("D", lat: 39, lng: 117), distanceMeters: nil, importance: 2)
        #expect(stop.optional && stop.importance == 2)
        var plan = TripPlan(name: nil, days: [{ var l = TripList(); l.arrange([stop]); return l }()])
        plan.wishes = "便宜一点"
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.allStops.first?.stop.importance == 2 && back?.wishes == "便宜一点")
    }

    @Test("F-15b row 128: a 1 that only fits by moving a 2 across days: the exchange is made, the score rises, moves=1")
    func row128() {
        let minutes = [1: 200, 2: 250, 10: 150, 11: 230]
        let imp = [1: 3, 2: 3, 10: 2, 11: 1]
        let visit: (Int) -> Int = { (minutes[$0] ?? 0) * 60 }
        let time: (Int, Int) -> Int = { $0 == $1 ? 0 : 1_200 }
        let importance: (Int) -> Int = { imp[$0] ?? 3 }
        // Insertion alone: the 2 on day 1 (390), the 1 fits nowhere (640 or 520): score 8.
        let (inserted, left, _) = TripFitter.insert([10, 11], into: [[1], [2]], group: [:], from: 0, to: nil,
                                                    budgetSeconds: 480 * 60, maxPerDay: 16, visit: visit, time: time)
        #expect(left == [11])
        #expect(TripFitter.score(inserted, from: 0, to: nil, budgetSeconds: 480 * 60, visit: visit, time: time, importance: importance) == 8)
        let r = TripFitter.fit(required: [[1], [2]], optional: [11, 10], from: 0, to: nil, budgetSeconds: 480 * 60,
                               maxPerDay: 16, visit: visit, time: time, importance: importance)
        #expect(r.moves == 1 && r.spare.isEmpty)
        #expect(r.days[0].sorted() == [1, 11] && r.days[1].sorted() == [2, 10])
        #expect(TripFitter.score(r.days, from: 0, to: nil, budgetSeconds: 480 * 60, visit: visit, time: time, importance: importance) == 9)
    }

    @Test("F-15b row 129: an importance-2 place left out and an importance-1 place kept on a full day: they are swapped")
    func row129() {
        let minutes = [1: 280, 10: 160, 11: 150]
        let imp = [1: 3, 10: 2, 11: 1]
        let r = TripFitter.improve(days: [[1, 11]], left: [10], required: [1], from: 0, to: nil, budgetSeconds: 480 * 60,
                                   maxPerDay: 16, visit: { (minutes[$0] ?? 0) * 60 }, time: { $0 == $1 ? 0 : 1_200 },
                                   importance: { imp[$0] ?? 3 })
        #expect(r.days == [[1, 10]] && r.spare == [11] && r.moves == 1)
    }

    @Test("F-15b row 130: one place not found: trip_needs_fix round=1 with its line; next says to call set_trip_plan")
    func row130() async {
        let (rig, _) = await timesRig(times, table: places)
        let r = await rig.run(trip("make_trip_list", ["places": [item("A", 400), item("无名", 60)]]))
        #expect(r.ok && r.data["status"] == "trip_needs_fix" && r.data["round"] == .int(1))
        #expect(strings(r.data["issues"]) == ["无名没找到，换一个附近类似的或者去掉"])
        #expect(r.data["next"]?.stringValue?.contains("调用 set_trip_plan") == true)
        #expect(r.data["next"]?.stringValue?.contains("先不要跟司机说话") == true)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip check round=0 not_found=1 over=0 driving=0 under=0 hotel=0 far=0 ms=") })
        // The plan is kept as fitted so far.
        #expect(await rig.order() == ["A"])
    }

    @Test("F-15b row 132: checks still fail after round 2: no round 3, trip_list with the issue in next")
    func row132() async {
        let (rig, _) = await timesRig(times, table: places)
        let a = await rig.run(trip("make_trip_list", ["places": [item("A", 400), item("无名", 60)]]))
        #expect(a.data["round"] == .int(1))
        // §52 (T-040zb): the fix is the whole plan written back with set_trip_plan.
        let b = await rig.run(await planCall(rig, [["A", "无名二"]]))
        #expect(b.data["status"] == "trip_needs_fix" && b.data["round"] == .int(2))
        #expect(strings(b.data["issues"]).first == "无名二没找到，换一个附近类似的或者去掉")
        let c = await rig.run(await planCall(rig, [["A", "无名三"]]))
        #expect(c.ok && c.data["status"] == "trip_list" && c.data["round"] == nil)
        #expect(strings(c.data["not_found"]).contains("无名三"))
        // The request is closed: the next write is a plain one.
        #expect(await rig.run(await sameCall(rig)).data["status"] == "trip_list")
    }

    @Test("F-15b row 133: a day of 75% driving and a day at 30% of its budget with no spare: driving and under, one result")
    func row133() async {
        let (rig, _) = await timesRig(times, table: places)
        let r = await rig.run(trip("make_trip_list", ["days": [[item("G", 120)], [item("远方", 60)]]]))
        #expect(r.data["status"] == "trip_needs_fix")
        // Day 1: 20 + 120 = 140 of 480. Day 2: 180 driving + 60.
        #expect(strings(r.data["issues"]) == ["第2天大半时间在开车，考虑把这天换到一个区域", "第1天还空约6小时，在和平区附近加1到2个"])
    }

    @Test("F-15b row 134: wishes and 2 nights: hotel issue with 3 choices per night and distances; picks set them; an unlisted pick is invalidFields")
    func row134() async {
        let (rig, _) = await timesRig(times, table: places, search: TripSearch(places, hotels: threeHotels))
        let r = await rig.run(trip("make_trip_list", ["days": [[item("A", 400)], [item("B", 400)], [item("C", 400)]],
                                                      "wishes": "酒店靠近车站"]))
        #expect(r.data["status"] == "trip_needs_fix" && r.data["wishes"] == "酒店靠近车站")
        let issues = strings(r.data["issues"])
        #expect(issues.count == 2)
        #expect(issues[0].hasPrefix("第1晚从这几个里挑一个：") && issues[1].hasPrefix("第2晚从这几个里挑一个："))
        #expect(issues[0].components(separatedBy: "公里）").count == 4)
        #expect(issues[0].contains("（0.1公里）、") || issues[0].contains("（0.2公里）、"))
        // The first is taken meanwhile.
        let plan = await rig.planner.currentPlan
        let night1 = plan.days[0].stops.last
        #expect(night1?.role == .hotel && night1?.place.name.hasSuffix("-1") == true)
    }

    @Test("F-15b row 135: no wishes: the first hotel is taken as §37 item 4; no hotel issue, no round for it")
    func row135() async {
        let (rig, _) = await timesRig(times, table: places, search: TripSearch(places, hotels: threeHotels))
        let r = await rig.run(trip("make_trip_list", ["days": [[item("A", 400)], [item("B", 400)], [item("C", 400)]]]))
        #expect(r.ok && r.data["status"] == "trip_list")
        #expect(await rig.planner.currentPlan.days[0].stops.last?.place.name.hasSuffix("-1") == true)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip check round=0 ") && $0.contains(" hotel=0 ") })
    }

    @Test("F-15b §49 item 4: TripChecks lines in order; §49 item 10: the catalog texts")
    func checksAndCatalog() {
        let days = [TripChecks.Day(minutes: 600, drivingMinutes: 300, onlyMustSee: true, area: nil)]
        let issues = TripChecks.run(notFound: ["X"], days: days, budgetMinutes: 480, spareEmpty: true,
                                    hotels: [1: [TripChecks.HotelChoice(name: "H", meters: 800)]])
        #expect(issues.map(\.kind) == [.notFound, .over, .driving, .hotel])
        #expect(issues.last?.line == "第1晚从这几个里挑一个：H（0.8公里）")
        #expect(ToolCatalog.makeTripListDescription.contains("写进 wishes"))
        #expect(ToolCatalog.makeTripListDescription.contains("optional=false") == false)
        // §52 item 14 (T-040zb): revise_trip_list is removed; set_trip_plan writes the plan.
        #expect(ToolCatalog.spec("revise_trip_list") == nil && AsyncTool(name: "revise_trip_list") == nil)
        #expect(ToolCatalog.spec("set_trip_plan")?.declaration.description == ToolCatalog.setTripPlanDescription)
    }
}
