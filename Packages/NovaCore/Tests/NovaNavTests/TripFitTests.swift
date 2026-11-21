import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// §48 (T-040t): places in one area north of the origin; every drive between two different points is 20 minutes.
private let area: [String: [Place]] = {
    var t: [String: [Place]] = [:]
    for (i, n) in ["R1", "R2", "R3", "O1", "O2", "O3", "O4", "O5", "O6", "O7"].enumerated() {
        t[n] = [spot(n, lat: 39.01 + Double(i) * 0.001, lng: 117.20)]
    }
    t["博物馆"] = [Place(id: "museum", name: "博物馆", address: nil,
                      coordinate: GeoCoordinate(latitude: 39.02, longitude: 117.21, datum: .gcj02),
                      distanceMeters: nil, kind: .museum)]
    t["R480"] = [spot("R480", lat: 39.03, lng: 117.20)]
    return t
}()
private let twenty: @Sendable (GeoCoordinate, GeoCoordinate) -> Int? = { $0 == $1 ? 0 : 1_200 }

private func item(_ name: String, _ minutes: Int, optional: Bool = false) -> JSONValue {
    ["name": .string(name), "minutes": .int(Int64(minutes)), "optional": .bool(optional)]
}
/// Row 117's places: 3 required of 60 minutes, then 6 optional of 90.
private let mixed: JSONValue = .array(["R1", "R2", "R3"].map { item($0, 60) } + (1...7).map { item("O\($0)", 90, optional: true) })

private func ints(_ v: JSONValue?) -> [Int] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap { $0.intValue.map(Int.init) }
}
private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}
private func planNames(_ rig: TripRig) async -> [String] {
    await rig.planner.currentPlan.allStops.map(\.stop.place.name)
}

@Suite("T-040t F-15b §48 fitting each day to a time budget")
struct TripFitTests {
    @Test("F-15b row 117: 2 days normal, 3 required + 6 optional, 20 min drives: required kept, optional while ≤ 480, rest spare")
    func row117() async {
        let (rig, _) = await timesRig(twenty, table: area)
        let r = await rig.run(trip("make_trip_list", ["places": mixed, "day_count": 2]))
        #expect(r.ok)
        let all = await planNames(rig)
        #expect(["R1", "R2", "R3"].allSatisfy(all.contains))
        // Each stop costs 20 + its visit: R 80, O 110. §49 exchanges reach 460 + 440 (3 R + 2 O, 4 O); O7 (ranked last) is left.
        #expect(strings(r.data["spare"]) == ["O7"])
        #expect(all.filter { $0.hasPrefix("O") }.sorted() == ["O1", "O2", "O3", "O4", "O5", "O6"])
        #expect(r.data["budget_minutes"] == .int(480))
        let minutes = ints(r.data["day_minutes"])
        #expect(minutes.count == 2 && minutes.allSatisfy { $0 <= 480 })
        let line = rig.lines.withLock { $0 }.first { $0.hasPrefix("trip fit ") } ?? ""
        #expect(line.contains("days=2 pace=normal budget=480 required=3 optional=7 kept=6 dropped=1"))
        let next = factsText(r)
        #expect(next.contains("时间不够，没排进：O7"))
        #expect(next.contains("每天大约"))
        // Stops say their minutes.
        guard case .array(let stops)? = r.data["stops"] else { Issue.record("stops"); return }
        #expect(stops.allSatisfy { $0["minutes"]?.intValue != nil })
        #expect(await rig.planner.currentPlan.spare.first?.optional == true)
    }

    @Test("F-15b row 118: a required place of 480 min plus one of 60 on 1 day: both kept, over=1, 比较紧 in next")
    func row118() async {
        let (rig, _) = await timesRig(twenty, table: area)
        let r = await settle(rig, await rig.run(trip("make_trip_list", ["places": [item("R480", 480), item("R1", 60)]])))
        #expect(r.ok)
        #expect(await planNames(rig).sorted() == ["R1", "R480"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip fit ") && $0.contains(" over=1 ") })
        // 20 + 480 + 20 + 60 = 580 minutes.
        #expect(factsText(r).contains("第1天大约10小时，比较紧"))
    }

    @Test("F-15b row 119: the same places with pace=relaxed keep fewer optional places than with packed")
    func row119() async {
        let (relaxed, _) = await timesRig(twenty, table: area)
        let a = await relaxed.run(trip("make_trip_list", ["places": mixed, "day_count": 2, "pace": "relaxed"]))
        let (packed, _) = await timesRig(twenty, table: area)
        let b = await packed.run(trip("make_trip_list", ["places": mixed, "day_count": 2, "pace": "packed"]))
        #expect(a.data["budget_minutes"] == .int(360) && b.data["budget_minutes"] == .int(600))
        let keptA = await planNames(relaxed).filter { $0.hasPrefix("O") }.count
        let keptB = await planNames(packed).filter { $0.hasPrefix("O") }.count
        #expect(keptA < keptB)
        #expect(ints(a.data["day_minutes"]).allSatisfy { $0 <= 360 })
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": mixed, "pace": "fast"])) == .invalidFields)
    }

    @Test("F-15b row 120: optional places only enough to fill a day halfway: kept; 第1天还空大约…小时 in next")
    func row120() async {
        let (rig, _) = await timesRig(twenty, table: area)
        let r = await settle(rig, await rig.run(trip("make_trip_list", ["places": [item("O1", 60, optional: true), item("O2", 60, optional: true)]])))
        #expect(r.ok)
        #expect(await planNames(rig).sorted() == ["O1", "O2"])
        #expect(strings(r.data["spare"]).isEmpty)
        // 20 + 60 + 20 + 60 = 160 of 480: about 5 hours free.
        #expect(factsText(r).contains("第1天还空大约5小时，可以再加几个地方"))
    }

    @Test("F-15b row 121: days groups with 2 places each: each place stays on its group's day")
    func row121() async {
        let (rig, _) = await timesRig(twenty, table: area)
        let groups: JSONValue = [[item("R1", 60), item("O5", 90, optional: true)], [item("O1", 60, optional: true), item("R3", 60)]]
        let r = await rig.run(trip("make_trip_list", ["days": groups]))
        #expect(r.ok)
        let d = await dayNames(rig)
        #expect(d.count == 2)
        #expect(d[0].sorted() == ["O5", "R1"])
        #expect(d[1].sorted() == ["O1", "R3"])
    }

    @Test("F-15b row 122: a plain string place of kind museum: minutes=120, optional=false")
    func row122() async {
        let (rig, _) = await timesRig(twenty, table: area)
        let r = await rig.run(trip("make_trip_list", ["places": names(["博物馆"])]))
        #expect(r.ok)
        guard case .array(let stops)? = r.data["stops"] else { Issue.record("stops"); return }
        #expect(stops.first?["minutes"] == .int(120))
        let stop = await rig.planner.current.stops.first
        #expect(stop?.optional == false && stop?.minutes == nil && stop?.visitMinutes == 120)
        // Minutes outside 15–600 are clamped, not refused.
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [item("R1", 900)]])) == nil)
        #expect(TripPlanner.items([item("R1", 900), item("R2", 1)]).map(\.minutes) == [600, 15])
    }

    @Test("F-15b row 123: a picked hotel makes day 1 over budget: day 1's last-ranked optional goes to spare; required kept")
    func row123() async {
        // The hotel is 4 hours from everything; other drives 20 minutes.
        let hotelLat = 36.5
        var table = area.mapValues { $0.map { jp($0.name, lat: $0.coordinate.latitude, lng: $0.coordinate.longitude) } }
        table["酒店"] = [jp("远方酒店", lat: hotelLat)]
        let far: @Sendable (GeoCoordinate, GeoCoordinate) -> Int? = { a, b in
            a == b ? 0 : (a.latitude == hotelLat || b.latitude == hotelLat) ? 14_400 : 1_200
        }
        let (rig, _) = await timesRig(far, table: area, abroad: FakeRentals(table, rentals: []))
        let r = await rig.run(trip("make_trip_list", ["places": [item("R1", 60), item("R2", 60), item("O1", 90, optional: true),
                                                                 item("O2", 90, optional: true)],
                                                      "day_count": 2, "abroad": true]))
        #expect(r.ok)
        let d = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d.first?.last?.role == .hotel)
        // Before the hotel day 1 was R1, O1, O2 (300 min); 240 more to the hotel is over: O2 (ranked last) goes.
        #expect(strings(r.data["spare"]) == ["O2"])
        let all = await planNames(rig)
        #expect(all.contains("R1") && all.contains("R2") && all.contains("O1"))
        #expect(ints(r.data["day_minutes"]).first.map { $0 <= 480 } == true)
    }

    @Test("F-15b row 125: driving times fail at home: no place dropped; the model's order, required first; ROUTE_TIMES_UNAVAILABLE")
    func row125() async {
        let (rig, _) = await timesRig({ _, _ in nil }, table: area)
        let r = await rig.run(trip("make_trip_list", ["places": .array([item("O1", 90, optional: true), item("R1", 60), item("R2", 60)])]))
        #expect(r.ok)
        #expect(await rig.order() == ["R1", "R2", "O1"])
        #expect(r.data["spare"] == nil)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip fit ") } == false)
        #expect(r.data["facts"]?["ordered"] == .bool(false))
        #expect(await rig.order() == ["R1", "R2", "O1"])
    }

    @Test("F-15b §48 item 4: TripFitter keeps required, inserts optional in order within the budget, the rest spare")
    func fitterPure() {
        let time: (Int, Int) -> Int = { $0 == $1 ? 0 : 10 }
        let visit: (Int) -> Int = { $0 < 10 ? 50 : 100 }
        let r = TripFitter.fit(required: [[1], [2]], optional: [10, 11, 12], from: 0, to: nil, budgetSeconds: 200,
                               maxPerDay: 16, visit: visit, time: time)
        #expect(r.days.flatMap { $0 }.filter { $0 < 10 }.sorted() == [1, 2])
        // Each day 60; an optional adds 110: one per day, the third is spare.
        #expect(r.spare == [12])
        #expect(TripFitter.costs(r.days, from: 0, to: nil, visit: visit, time: time).allSatisfy { $0 <= 200 })
        // A required day over budget stays over; nothing optional goes on it.
        let over = TripFitter.fit(required: [[1, 2, 3, 4]], optional: [10], from: 0, to: nil, budgetSeconds: 100,
                                  maxPerDay: 16, visit: visit, time: time)
        #expect(over.days == [[1, 2, 3, 4]] && over.spare == [10])
        #expect(TripFitter.Pace(budgetMinutes: nil) == .normal && TripFitter.Pace.packed.budgetMinutes == 600)
    }

    @Test("F-15b §48 item 6: spare places, minutes and optional are saved with the plan")
    func saved() async {
        let (rig, _) = await timesRig(twenty, table: area)
        _ = await rig.run(trip("make_trip_list", ["places": mixed, "day_count": 2]))
        let plan = await rig.planner.currentPlan
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.spare.map(\.place.name) == ["O7"])
        #expect(back?.budgetMinutes == 480)
        #expect(back?.allStops.map(\.stop.optional) == plan.allStops.map(\.stop.optional))
        #expect(back?.allStops.map(\.stop.minutes) == plan.allStops.map(\.stop.minutes))
    }
}
