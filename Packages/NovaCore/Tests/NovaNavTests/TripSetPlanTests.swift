import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Sapporo-ish places on a line; every name answers on 高德's text search (the rig's search), so the test is about
/// the plan, not the vendor.
let sapporoTable: [String: [Place]] = sapporo
private let sapporo: [String: [Place]] = {
    var t: [String: [Place]] = [:]
    for (i, n) in ["A", "B", "C", "D", "E", "F"].enumerated() { t[n] = [spot(n, lat: 43.0 + Double(i) * 0.01, lng: 141.35)] }
    t["新千岁机场"] = [spot("新千岁机场", lat: 42.78, lng: 141.69)]
    t["桥本酒店"] = [spot("桥本酒店", lat: 43.06, lng: 141.35)]
    t["另一家酒店"] = [spot("另一家酒店", lat: 43.07, lng: 141.36)]
    t["慢地方"] = [spot("慢地方", lat: 43.08, lng: 141.37)]
    return t
}()

private func stopsOf(_ v: JSONValue?) -> [[JSONValue]] {
    guard case .array(let days)? = v?["days"] else { return [] }
    return days.map { if case .array(let s) = $0 { s } else { [] } }
}

private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}

private func stop(_ id: String? = nil, name: String? = nil, role: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = [:]
    if let id { o["id"] = .string(id) }
    if let name { o["name"] = .string(name) }
    if let role { o["role"] = .string(role) }
    return .object(o)
}

private func setPlan(_ days: [[JSONValue]], _ extra: [String: JSONValue] = [:]) -> ToolCall {
    trip("set_trip_plan", ["days": .array(days.map { .array($0) })].merging(extra) { $1 })
}

/// A rig whose plan has sights A–F (by name, one day), and their ids.
private func sightsRig(search: TripSearch = TripSearch(sapporo), clock: any NovaClock = ManualClock()) async -> (TripRig, [String: String]) {
    let rig = await TripRig(search: search, clock: clock)
    _ = await rig.run(setPlan([["A", "B", "C", "D", "E", "F"].map { stop(name: $0) }]))
    var ids: [String: String] = [:]
    for s in await rig.planner.currentPlan.allStops { ids[s.stop.place.name] = s.stop.id }
    return (rig, ids)
}

@Suite("T-040zb F-15b §52 the plan is one data structure")
struct TripSetPlanTests {
    @Test("T-040zb F-15b row 195: Sapporo 3 days, New Chitose start and end, the driver's hotel both nights, sights by id: saved as written, no lookup for id stops")
    func row195() async {
        let (rig, ids) = await sightsRig()
        let asked = rig.search.asked.withLock { $0 }.count
        let hotel = stop(name: "桥本酒店", role: "hotel")
        let r = await rig.run(setPlan([
            [stop(name: "新千岁机场", role: "start"), stop(ids["A"]), stop(ids["B"]), hotel],
            [hotel, stop(ids["C"]), stop(ids["D"]), hotel],
            [hotel, stop(ids["E"]), stop(ids["F"]), stop(name: "新千岁机场", role: "end")],
        ]))
        #expect(r.ok && r.data["status"] == "trip_list", "\(r)")
        // Only the two new names were searched.
        #expect(rig.search.asked.withLock { Array($0.dropFirst(asked)) }.sorted() == ["新千岁机场", "桥本酒店"])
        let plan = await rig.planner.currentPlan
        let days = plan.days.map { $0.stops.map(\.place.name) }
        #expect(days == [["新千岁机场", "A", "B", "桥本酒店"], ["桥本酒店", "C", "D", "桥本酒店"], ["桥本酒店", "E", "F", "新千岁机场"]])
        #expect(plan.days[0].stops.first?.role == .start && plan.days[2].stops.last?.role == .end)
        let hotels = plan.allStops.map(\.stop).filter { $0.role == .hotel }
        #expect(hotels.count == 4 && hotels.allSatisfy { $0.pickedBy == .model && $0.place.name == "桥本酒店" })
        #expect(Set(hotels.map(\.id)).count == 1)
        // The kept sights keep their ids.
        #expect(plan.days[1].stops[1].id == ids["C"])
        #expect(r.data["facts"]?["kept"] == .int(6) && r.data["facts"]?["new"] == .int(2) && r.data["facts"]?["app_picked_hotels"] == nil)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip set days=3 stops=12 kept=6 new=2 removed=0 not_placed=0 check=ok ms=") })
        // The same plan written back by id: still valid (one hotel id on both nights), no search at all.
        let again = rig.search.asked.withLock { $0 }.count
        let back = await rig.run(await sameCall(rig))
        #expect(back.ok && rig.search.asked.withLock { $0 }.count == again)
        #expect(await rig.planner.currentPlan.days.map { $0.stops.map(\.place.name) } == days)
    }

    @Test("T-040zb F-15b row 196: two different hotels on night 1, a hotel not at the end of its day, two starts, an unknown id: PLAN_CHECK listing it; plan unchanged")
    func row196() async {
        let (rig, ids) = await sightsRig()
        let before = await rig.planner.currentPlan
        let twoHotels = await rig.run(setPlan([
            [stop(ids["A"]), stop(name: "桥本酒店", role: "hotel")],
            [stop(name: "另一家酒店", role: "hotel"), stop(ids["B"])],
        ]))
        #expect(twoHotels.code == .planCheck)
        #expect(strings(twoHotels.data["facts"]?["problems"]).contains { $0.hasPrefix("第1晚有两个酒店") }, "\(twoHotels)")
        #expect(twoHotels.data["next"]?.stringValue?.contains("再调用 set_trip_plan") == true)
        let middle = await rig.run(setPlan([[stop(ids["A"]), stop(name: "桥本酒店", role: "hotel"), stop(ids["B"])], [stop(ids["C"])]]))
        #expect(strings(middle.data["facts"]?["problems"]).contains { $0.contains("要是当天最后一个") })
        let starts = await rig.run(setPlan([[stop(ids["A"], role: "start"), stop(ids["B"], role: "start")]]))
        #expect(strings(starts.data["facts"]?["problems"]) == ["出发点（start）最多一个，而且要是第一天第一个"])
        let unknown = await rig.run(setPlan([[stop("s99"), stop(ids["A"]), stop(ids["A"])]]))
        #expect(strings(unknown.data["facts"]?["problems"]) == ["没有这个 id：s99", "id 重复：\(ids["A"]!)"])
        // Nothing changed, and nothing was searched for a refused plan.
        #expect(await rig.planner.currentPlan == before)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip set days=2 stops=4 kept=0 new=0 removed=0 not_placed=0 check=fail ") })
        // §49's round limit: after 2 refusals in a row, the third is said to the driver.
        #expect(unknown.data["next"]?.stringValue?.contains("再调用 set_trip_plan") != true)
        // Pure: a visited stop keeps its day.
        var plan = before
        plan.mark(day: 1, index: 1, .visited)
        let moved = TripPlanner.planProblems([[], [TripPlanner.WrittenStop(id: ids["A"])]], old: plan)
        #expect(moved == ["A已经去过或跳过，要留在第1天"])
    }

    @Test("T-040zb F-15b row 197: a new name whose search is held past its limit: edit succeeds, placed=false, not_placed; the background retry places it when released")
    func row197() async {
        let clock = ManualClock()
        let search = TripSearch(sapporo, slow: ["慢地方"])
        let (rig, ids) = await sightsRig(search: search, clock: clock)
        let call = setPlan([[stop(ids["A"]), stop(name: "慢地方")]])
        let made = Task { await rig.run(call) }
        for _ in 0..<5000 where search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(16))
        let r = await made.value
        #expect(r.ok, "\(r)")
        #expect(strings(r.data["facts"]?["not_placed"]) == ["慢地方"] && r.code != .notFound)
        let slowStop = await rig.planner.currentPlan.allStops.first { $0.stop.asked == "慢地方" }?.stop
        #expect(slowStop?.placed == false)
        #expect(stopsOf(r.data["plan"]).first?.last?["placed"] == .bool(false))
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip set days=1 stops=2 kept=1 new=1 removed=5 not_placed=1 check=ok ") })
        // The held search is released; the retry 10 s later asks again and is answered.
        search.release()
        for _ in 0..<200 where search.waiting == 0 {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(search.waiting == 1)
        search.release()
        await rig.planner.retriesSettled()
        let placed = await rig.planner.currentPlan.allStops.first { $0.stop.id == slowStop?.id }?.stop
        #expect(placed?.placed == true && placed?.place.name == "慢地方")
        #expect(rig.lines.withLock { $0 }.contains("trip place-retry name=\(slowStop?.id ?? "") try=1 ok=yes"))
    }

    @Test("T-040zb F-15b row 198: a stop left out of the written plan is removed and named in removed")
    func row198() async {
        let (rig, ids) = await sightsRig()
        let r = await rig.run(setPlan([["A", "B", "D", "E", "F"].map { stop(ids[$0]) }]))
        #expect(r.ok && strings(r.data["facts"]?["removed"]) == ["C"])
        #expect(await rig.order() == ["A", "B", "D", "E", "F"])
    }

    @Test("T-040zb F-15b row 200: every trip tool result carries the whole plan with id, name, role, placed, picked_by for every day; long plans drop minutes")
    func row200() async {
        let (rig, ids) = await sightsRig()
        _ = await rig.run(setPlan([[stop(ids["A"]), stop(ids["B"])], [stop(ids["C"])], []]))
        let results = [
            await rig.run(trip("edit_trip_list", ["action": "read"])),
            await rig.run(trip("edit_trip_list", ["action": "replace", "index": 9, "name": "D"])),
            await rig.run(trip("trip_plans", ["action": "list"])),
            await rig.run(await sameCall(rig)),
            await rig.run(trip("trip_next", ["day": 3])),
        ]
        for r in results {
            let days = stopsOf(r.data["plan"])
            #expect(days.count == 3, "\(r)")
            #expect(days.joined().count == 3)
            for s in days.joined() {
                for key in ["id", "name", "role", "placed", "picked_by", "minutes"] { #expect(s[key] != nil, "\(key)") }
            }
        }
        // §52 item 2: over 2,000 characters, minutes go first; ids, names and roles stay.
        var long = TripList()
        long.arrange((0..<16).map { TripStop(index: 0, asked: "x", place: spot("很长很长的名字" + String(repeating: "长", count: 20) + "\($0)", lat: 43, lng: 141),
                                             distanceMeters: nil) })
        let plan = TripPlan(name: nil, days: [long, long, long])
        let v = TripPlanJSON.value(plan)
        #expect(stopsOf(v).joined().allSatisfy { $0["minutes"] == nil && $0["id"] != nil && $0["name"] != nil && $0["role"] != nil })
        #expect(stopsOf(TripPlanJSON.value(await rig.planner.currentPlan)).joined().allSatisfy { $0["minutes"] != nil })
        #expect(TripPlanJSON.noteLine(TripPlan()) == nil)
        #expect(TripPlanJSON.noteLine(await rig.planner.currentPlan)?.hasPrefix("行程：{\"days\":[[{") == true)
        // The file keeps ids, placed and picked_by.
        let back = TripPlanFile.current(from: TripPlanFile.current(await rig.planner.currentPlan))
        #expect(back?.allStops.map(\.stop.id) == (await rig.planner.currentPlan).allStops.map(\.stop.id))
    }

    @Test("T-040zb F-15b row 201: a night with no hotel after set_trip_plan: the app picks one (picked_by=app, app_picked_hotels); a model-written hotel is never replaced")
    func row201() async {
        let hotel = spot("站前酒店", lat: 43.03, lng: 141.35)
        let search = TripSearch(sapporo, hotels: { _ in [hotel] })
        let (rig, ids) = await sightsRig(search: search)
        let r = await rig.run(setPlan([[stop(ids["A"]), stop(ids["B"])], [stop(ids["C"])]]))
        #expect(strings(r.data["facts"]?["app_picked_hotels"]) == ["站前酒店"], "\(r)")
        var plan = await rig.planner.currentPlan
        #expect(plan.days[0].stops.last?.pickedBy == .app && plan.days[1].stops.first?.place.name == "站前酒店")
        #expect(stopsOf(r.data["plan"])[0].last?["picked_by"] == "app")
        // The driver's hotel replaces it on that night; the app picks nothing.
        let mine = stop(name: "桥本酒店", role: "hotel")
        let r2 = await rig.run(setPlan([[stop(ids["A"]), stop(ids["B"]), mine], [mine, stop(ids["C"])]]))
        #expect(r2.ok && r2.data["facts"]?["app_picked_hotels"] == nil)
        plan = await rig.planner.currentPlan
        #expect(plan.days[0].stops.last?.place.name == "桥本酒店" && plan.days[0].stops.last?.pickedBy == .model)
        #expect(strings(r2.data["facts"]?["removed"]) == ["站前酒店"])
        // Written back by id: still the driver's.
        _ = await rig.run(await sameCall(rig))
        #expect(await rig.planner.currentPlan.days[1].stops.first?.place.name == "桥本酒店")
    }

    @Test("T-040zb F-15b §52 items 3, 14: set_trip_plan declared async with the §52 text; validation; old actions gone")
    func catalog() {
        #expect(AsyncTool(name: "set_trip_plan") != nil && TripPlanner.tools.contains("set_trip_plan"))
        // §54 item 2 (T-040zg) puts its sentence after 「修改行程：」.
        #expect(ToolCatalog.setTripPlanDescription.contains("把整份行程（每天的地点，带 id 和 role）按司机的意思改好后整份传回。已有的地点只写 id；新地点写 name。role：start 出发点"))
        #expect(ToolCatalog.setTripPlanDescription.hasSuffix("去掉的地点不写。结果稍后回来：" + ToolCatalog.tripWorkingLine))
        #expect(ToolCatalog.validate(setPlan([[stop("s1"), stop(name: "X", role: "hotel")]], ["optimise": true, "pace": "relaxed"])) == nil)
        #expect(ToolCatalog.validate(setPlan([[stop("s1", name: "X")]])) == .invalidFields)
        #expect(ToolCatalog.validate(setPlan([[stop(name: "X", role: "museum")]])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("set_trip_plan", [:])) == .invalidFields)
        #expect(ToolCatalog.tripEditActions == ["replace", "clear", "read", "visited", "skip"])
    }
}

@Suite("T-040zc F-15b §52 item 9 the screen and reads from the plan")
struct TripPlanScreenTests {
    @Test("T-040zc F-15b row 199: day 2 selected and empty: trip screen still shown with every day tab; read returns the whole plan; no NO_TRIP_LIST")
    func row199() async {
        let (rig, ids) = await sightsRig()
        _ = await rig.run(setPlan([[stop(ids["A"]), stop(ids["B"])], []]))
        let revision = await rig.planner.currentPlan.revision
        let tapped = await rig.planner.tap(.day(2), moving: true)
        #expect(tapped.result.ok && tapped.note == nil)
        let plan = await rig.planner.currentPlan
        #expect(plan.currentDay == 2 && plan.revision == revision)
        #expect(TripScreen.of(plan: plan, moving: false) == .emptyDay)
        #expect(TripScreen.of(plan: plan, moving: true) == .strip(TripScreen.emptyDayText) && TripScreen.emptyDayText == "这一天还没有安排")
        #expect(await !rig.planner.cardsHidden)
        #expect(rig.lines.withLock { $0 }.contains("trip day-view day=2"))
        #expect(!rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip tap action=day") })
        let read = await rig.run(trip("edit_trip_list", ["action": "read"]))
        #expect(read.ok && read.code != .noTripList && stopsOf(read.data["plan"]).map(\.count) == [2, 0])
        let next = await rig.run(trip("trip_next"))
        #expect(next.code == .dayDone)
        // A day out of range is clamped; a tap never fails.
        #expect(await rig.planner.tap(.day(9), moving: false).result.ok)
        #expect(await rig.planner.currentPlan.currentDay == 2)
        _ = await rig.planner.tap(.day(1), moving: false)
        guard case .cards(let cards) = TripScreen.of(plan: await rig.planner.currentPlan, moving: false) else {
            Issue.record("cards"); return
        }
        #expect(cards.map(\.name) == ["A", "B"])
        #expect(TripScreen.of(plan: TripPlan(), moving: false) == .none)
    }

    @Test("T-040zc F-15b §52 item 9: the view model gets the whole plan on every change; an unplaced stop shows 位置待确认 and has no pin")
    func viewModel() async {
        let seen = TripLines()
        let nav = NavigationController(search: TripSearch(sapporo), engine: ScriptedNaviEngine(routes: []), location: NoLocation(),
                                       clock: ManualClock())
        await nav.start()
        let planner = TripPlanner(search: TripSearch(sapporo), navigation: nav, origin: { nil }, clock: ManualClock(),
                                  onPlan: { plan in seen.append("days=\(plan.dayCount) stops=\(plan.stopCount) day=\(plan.currentDay)") })
        _ = await planner.execute(setPlan([[stop(name: "A"), stop(name: "无此地")], [stop(name: "B")]]))
        _ = await planner.tap(.day(2), moving: false)
        #expect(seen.withLock { $0 }.suffix(2) == ["days=2 stops=3 day=1", "days=2 stops=3 day=2"])
        _ = await planner.tap(.day(1), moving: false)
        let plan = await planner.currentPlan
        guard case .cards(let cards) = TripScreen.of(plan: plan, moving: false) else { Issue.record("cards"); return }
        #expect(cards.last?.placed == false && cards.last?.district == "位置待确认" && cards.last?.km == nil)
        #expect(TripPin.pins(plan.days[0]).count == 1)
    }
}

@Suite("T-040ze F-15b §52 item 13 clearing the whole trip asks first")
struct TripClearConfirmTests {
    @Test("T-040ze F-15b row 205 (unit): 清空行程 / 把行程拿回去 with a plan: CONFIRM_CLEAR first; cleared only by the clear on the driver's next turn")
    func row205() async {
        let turns = TripLines()
        let nav = NavigationController(search: TripSearch(sapporo), engine: ScriptedNaviEngine(routes: []), location: NoLocation(),
                                       clock: ManualClock())
        await nav.start()
        let lines = TripLines()
        let planner = TripPlanner(search: TripSearch(sapporo), navigation: nav, origin: { nil }, clock: ManualClock(),
                                  onLine: { lines.append($0) }, driverTurns: { turns.withLock { $0 }.count })
        _ = await planner.execute(setPlan([[stop(name: "A"), stop(name: "B")]]))
        turns.append("driver: 把行程拿回去")
        let asked = await planner.execute(trip("edit_trip_list", ["action": "clear"]))
        #expect(asked.code == .confirmClear && replyValues(asked.data["may"]) == ["ask_confirm"], "\(asked)")
        #expect(await planner.currentPlan.stopCount == 2)
        // The same turn again: still asks (no yes heard yet).
        #expect(await planner.execute(trip("edit_trip_list", ["action": "clear"])).code == .confirmClear)
        turns.append("driver: 对")
        let cleared = await planner.execute(trip("edit_trip_list", ["action": "clear"]))
        let empty = await planner.currentPlan.isEmpty
        #expect(cleared.ok && empty)
        #expect(lines.withLock { $0 }.filter { $0.hasPrefix("trip clear") } == ["trip clear confirm=asked via=edit", "trip clear confirm=asked via=edit", "trip clear confirm=yes via=edit"])
        // set_trip_plan with no stops is a whole clear too; another call in between forgets the question.
        _ = await planner.execute(setPlan([[stop(name: "A")]]))
        turns.append("driver: 清空行程")
        #expect(await planner.execute(setPlan([[]])).code == .confirmClear)
        turns.append("driver: 先看看")
        _ = await planner.execute(trip("edit_trip_list", ["action": "read"]))
        turns.append("driver: 清空")
        #expect(await planner.execute(setPlan([[]])).code == .confirmClear)
        #expect(await planner.currentPlan.stopCount == 1)
        // clear day=N stays immediate.
        #expect(await planner.execute(trip("edit_trip_list", ["action": "clear", "day": 1])).ok)
    }
}

/// Review 2026-11-21 of T-040zb/zd: the four blocking findings, each as a test.
@Suite("T-040zb F-15b §52 review fixes")
struct TripSetPlanReviewTests {
    @Test("T-040zb F-15b row 196 (review): a reached hotel is on two days; writing it back as day 2's first stop is no problem")
    func reachedHotel() async {
        let (rig, ids) = await sightsRig()
        let hotel = stop(name: "桥本酒店", role: "hotel")
        _ = await rig.run(setPlan([[stop(ids["A"]), hotel], [hotel, stop(ids["B"])]]))
        var plan = await rig.planner.currentPlan
        let hotelID = plan.days[0].stops.last!.id
        plan.mark(day: 1, index: plan.days[0].stops.count, .visited)
        plan.mark(day: 2, index: 1, .visited)
        let written: [[TripPlanner.WrittenStop]] = [
            [TripPlanner.WrittenStop(id: ids["A"]), TripPlanner.WrittenStop(id: hotelID)],
            [TripPlanner.WrittenStop(id: hotelID), TripPlanner.WrittenStop(id: ids["B"]), TripPlanner.WrittenStop(name: "C")],
        ]
        #expect(TripPlanner.planProblems(written, old: plan) == [])
    }

    @Test("T-040zb F-15b row 197 (review): the background retry places nothing while set_trip_plan runs; the edit is not OPTIONS_STALE")
    func retryWaitsForEdit() async {
        let clock = ManualClock()
        var table = sapporoTable
        table["晚到"] = [spot("晚到", lat: 43.09, lng: 141.38)]
        table["慢二"] = [spot("慢二", lat: 43.10, lng: 141.39)]
        // 晚到: not found by the first write, found by the retry (which would raise the revision); 慢二 holds the second write.
        let search = TripSearch(table, slow: ["慢二"], lateAnswer: ["晚到": 1])
        let (rig, ids) = await sightsRig(search: search, clock: clock)
        #expect(await rig.run(setPlan([[stop(ids["A"]), stop(name: "晚到")]])).ok)
        let lateID = await rig.planner.currentPlan.allStops.first { $0.stop.asked == "晚到" }!.stop.id
        #expect(await rig.planner.currentPlan.allStops.first { $0.stop.id == lateID }?.stop.placed == false)
        let second = Task { await rig.run(setPlan([[stop(ids["A"]), stop(lateID), stop(name: "慢二")]])) }
        for _ in 0..<5000 where search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(20))
        // The retry's 10 s pass while 慢二 is held, then the name limit.
        for _ in 0..<16 {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(5))
        }
        let r = await second.value
        #expect(r.ok && r.code != .optionsStale, "\(r)")
        search.release()
    }

    @Test("T-040zd F-15b row 204 (review): every slow path is search_slow with a code that is not not-found")
    func slowPaths() async {
        func held(_ call: ToolCall, _ rig: TripRig, _ search: TripSearch, _ clock: ManualClock) async -> ToolResult {
            let made = Task { await rig.run(call) }
            for _ in 0..<5000 where search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
            try? await Task.sleep(for: .milliseconds(20))
            clock.advance(by: .seconds(16))
            let r = await made.value
            search.release()
            return r
        }
        let notFoundCodes: [ToolErrorCode?] = [.notFound, .noCandidates]
        // All slow, places without day.
        do {
            let clock = ManualClock(); let search = TripSearch(sapporoTable, slow: ["慢地方"])
            let rig = await TripRig(search: search, clock: clock)
            let r = await held(trip("make_trip_list", ["places": ["慢地方"]]), rig, search, clock)
            #expect(!notFoundCodes.contains(r.code) && strings(r.data["facts"]?["search_slow"]) == ["慢地方"], "\(r)")
        }
        // All slow, places with day.
        do {
            let clock = ManualClock(); let search = TripSearch(sapporoTable, slow: ["慢地方"])
            let rig = await TripRig(search: search, clock: clock)
            let r = await held(trip("make_trip_list", ["places": ["慢地方"], "day": 1]), rig, search, clock)
            #expect(!notFoundCodes.contains(r.code) && strings(r.data["facts"]?["search_slow"]) == ["慢地方"], "\(r)")
        }
        // A slow frame stop (start).
        do {
            let clock = ManualClock(); let search = TripSearch(sapporoTable, slow: ["慢地方"])
            let rig = await TripRig(search: search, clock: clock)
            var r = await held(trip("make_trip_list", ["places": ["A", "B"], "start": "慢地方"]), rig, search, clock)
            r = await settle(rig, r)
            #expect(strings(r.data["facts"]?["search_slow"]) == ["慢地方"], "\(r)")
            let nf = strings(r.data["not_found"]) + strings(r.data["facts"]?["not_found"])
            #expect(!nf.contains("慢地方"))
        }
        // Replace with a slow name.
        do {
            let clock = ManualClock(); let search = TripSearch(sapporoTable, slow: ["慢地方"])
            let (rig, _) = await sightsRig(search: search, clock: clock)
            let r = await held(trip("edit_trip_list", ["action": "replace", "index": 2, "name": "慢地方"]), rig, search, clock)
            #expect(!notFoundCodes.contains(r.code) && strings(r.data["facts"]?["search_slow"]) == ["慢地方"], "\(r)")
        }
    }

    @Test("T-040zb F-15b §51 item 8 (review): a stop not on the map is never the trip's next stop or a search centre")
    func unplacedNotNear() async {
        let clock = ManualClock()
        let search = TripSearch(sapporoTable, slow: ["慢地方"])
        let (rig, ids) = await sightsRig(search: search, clock: clock)
        let made = Task { await rig.run(setPlan([[stop(name: "慢地方"), stop(ids["A"])]])) }
        for _ in 0..<5000 where search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(16))
        #expect(await made.value.ok)
        let near = await rig.planner.nearTrip()
        #expect(near?.next?.name == "A")
        #expect(near?.stops.contains { $0.coordinate.latitude == 0 && $0.coordinate.longitude == 0 } == false)
        search.release()
    }

    @Test("T-040zd F-15b row 204 (review): make_trip_list with a lookup out of time says search_slow, not not_found")
    func makeSlow() async {
        let clock = ManualClock()
        let search = TripSearch(sapporoTable, slow: ["慢地方"])
        let rig = await TripRig(search: search, clock: clock)
        let made = Task { await rig.run(trip("make_trip_list", ["places": ["A", "慢地方"]])) }
        for _ in 0..<5000 where search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(16))
        var r = await made.value
        r = await settle(rig, r)
        #expect(strings(r.data["facts"]?["search_slow"]) == ["慢地方"], "\(r)")
        let notFound = strings(r.data["facts"]?["not_found"])
        #expect(!notFound.contains("慢地方"))
        search.release()
    }
}
