import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// `Application Support/trip/` in memory.
final class MemoryTripFiles: TripFiles, @unchecked Sendable {
    let files = Mutex<[String: Data]>([:])
    let writes = Mutex(0)
    func read(_ name: String) -> Data? { files.withLock { $0[name] } }
    func write(_ name: String, _ data: Data) {
        files.withLock { $0[name] = data }
        writes.withLock { $0 += 1 }
    }
    func moveAside(_ name: String) {
        files.withLock { f in
            f[name.replacingOccurrences(of: ".json", with: ".bad.json")] = f[name]
            f[name] = nil
        }
    }
}

struct PlanRig {
    let search: TripSearch
    let engine: ScriptedNaviEngine
    let nav: NavigationController
    let planner: TripPlanner
    let files: MemoryTripFiles
    let lines = TripLines()

    init(files: MemoryTripFiles = MemoryTripFiles(), clock: ManualClock = ManualClock()) async {
        search = TripSearch(tianjin)
        engine = ScriptedNaviEngine(routes: [route(1, meters: 30_000, seconds: 3_600)])
        self.files = files
        let lines = self.lines
        nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: clock,
                                   onTripLine: { lines.append($0) })
        await nav.start()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let tick = Mutex(0.0)
        planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: clock, files: files,
                              now: { tick.withLock { $0 += 60; return start.addingTimeInterval($0) } },
                              onLine: { lines.append($0) })
    }

    func run(_ name: String, _ args: [String: JSONValue]) async -> ToolResult { await planner.execute(trip(name, args)) }
}

@Suite("T-040l F-15b phase 2b saved plans and days")
struct TripPlanTests {
    @Test("F-15b row 26: a changed plan comes back from the file in a new controller: same days and stops, no lookups, no passed stops, no kept route")
    func row26() async {
        let files = MemoryTripFiles()
        let first = await PlanRig(files: files)
        _ = await first.run("make_trip_list", ["places": names(["古文化街", "五大道"]), "day": 1])
        _ = await first.run("make_trip_list", ["places": names(["天津之眼", "瓷房子", "海河"]), "day": 2])
        _ = await first.run("edit_trip_list", ["action": "remove", "index": 3, "day": 2])
        _ = await first.run("route_trip", ["day": 2])
        #expect(await first.nav.current.tripRoute)

        let second = await PlanRig(files: files)
        await second.planner.restore()
        let plan = await second.planner.currentPlan
        #expect(plan.dayCount == 2 && plan.currentDay == 2)
        #expect(plan.days.map { $0.stops.map(\.place.name) } == [["古文化街", "五大道"], ["瓷房子", "天津之眼"]])
        #expect(second.search.asked.withLock { $0 }.isEmpty)
        let flow = await second.nav.current
        #expect(!flow.tripRoute && flow.tripStopsPassed.isEmpty)
        #expect(second.lines.withLock { $0 }.contains("trip load ok=yes days=2 stops=4"))
    }

    @Test("F-15b row 27: an unreadable current.json starts empty, logs trip load ok=no and is moved to current.bad.json")
    func row27() async {
        let files = MemoryTripFiles()
        files.write("current.json", Data("{not json".utf8))
        let rig = await PlanRig(files: files)
        await rig.planner.restore()
        #expect(await rig.planner.currentPlan.isEmpty)
        #expect(rig.lines.withLock { $0 }.contains("trip load ok=no days=1 stops=0"))
        #expect(files.read("current.json") == nil && files.read("current.bad.json") == Data("{not json".utf8))
        // An unknown version is not read either.
        let v2 = MemoryTripFiles()
        v2.write("current.json", Data(#"{"version":2,"plan":{"currentDay":1,"days":[]}}"#.utf8))
        let other = await PlanRig(files: v2)
        await other.planner.restore()
        #expect(other.lines.withLock { $0 }.contains { $0.hasPrefix("trip load ok=no") })
    }

    @Test("F-15b row 28: no place names in the trip lines or the files' log lines")
    func row28() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街", "五大道", "盘山"])])
        _ = await rig.run("edit_trip_list", ["action": "remove", "name": "五大道"])
        _ = await rig.run("route_trip", ["start": true])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        _ = await rig.planner.tap(.remove(index: 1), moving: false)
        let lines = rig.lines.withLock { $0 }
        #expect(!lines.isEmpty)
        for name in ["古文化街", "五大道", "盘山", "天津", "瓷房子"] {
            #expect(lines.allSatisfy { !$0.contains(name) }, "\(name) in \(lines)")
        }
    }

    @Test("F-15b row 29: make day=1, then day=2, then day=4: two days kept, the third OUT_OF_RANGE")
    func row29() async {
        let rig = await PlanRig()
        #expect(await rig.run("make_trip_list", ["places": names(["古文化街"]), "day": 1]).ok)
        let two = await rig.run("make_trip_list", ["places": names(["五大道", "瓷房子"]), "day": 2])
        #expect(two.data["day"] == .int(2) && two.data["days"] == .int(2))
        #expect(await rig.run("make_trip_list", ["places": names(["天津之眼"]), "day": 4]).code == .outOfRange)
        #expect(await rig.planner.currentPlan.dayCount == 2)
        // Without a day the whole plan becomes one day (phase 1).
        _ = await rig.run("make_trip_list", ["places": names(["海河"])])
        #expect(await rig.planner.currentPlan.dayCount == 1)
    }

    @Test("F-15b row 30: route_trip day=2 start=true routes only day 2's stops and makes day 2 current")
    func row30() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街", "五大道"]), "day": 1])
        _ = await rig.run("make_trip_list", ["places": names(["天津之眼", "瓷房子"]), "day": 2])
        _ = await rig.run("edit_trip_list", ["action": "read", "day": 1])
        #expect(await rig.planner.currentPlan.currentDay == 1)
        let r = await rig.run("route_trip", ["day": 2, "start": true])
        #expect(r.ok && r.data["day"] == .int(2))
        // Nearest from the origin: 瓷房子 (39.02) then 天津之眼 (39.16); day 1's stops are not in the route.
        let request = rig.engine.requests.withLock { $0.last }
        #expect(request?.destinationName == "天津之眼" && request?.waypoints.map(\.latitude) == [39.02])
        #expect(await rig.planner.currentPlan.currentDay == 2)
    }

    @Test("F-15b row 31: clear day=1 on 3 days leaves 2; the old day 2 is now day 1")
    func row31() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街"]), "day": 1])
        _ = await rig.run("make_trip_list", ["places": names(["五大道"]), "day": 2])
        _ = await rig.run("make_trip_list", ["places": names(["天津之眼"]), "day": 3])
        #expect(await rig.run("edit_trip_list", ["action": "clear", "day": 1]).ok)
        let plan = await rig.planner.currentPlan
        #expect(plan.dayCount == 2 && plan.days[0].stops.first?.place.name == "五大道")
        #expect(await rig.run("edit_trip_list", ["action": "read", "day": 3]).code == .outOfRange)
        // Without a day the whole plan is cleared.
        _ = await rig.run("edit_trip_list", ["action": "clear"])
        #expect(await rig.planner.currentPlan.isEmpty)
    }

    @Test("F-15b row 32: save, list, open by containment, rename, delete; the plan lines")
    func row32() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街", "五大道"])])
        let saved = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        #expect(saved.ok && saved.data["replaced"] == false)
        #expect(await rig.run("trip_plans", ["action": "save", "name": "天津一日游"]).data["replaced"] == true)
        _ = await rig.run("make_trip_list", ["places": names(["天津之眼"])])
        _ = await rig.run("trip_plans", ["action": "save", "name": "海河夜景"])
        let list = await rig.run("trip_plans", ["action": "list"])
        #expect(list.data["count"] == .int(2))
        guard case .array(let plans)? = list.data["plans"] else { Issue.record("plans"); return }
        #expect(plans.compactMap { $0["name"]?.stringValue } == ["海河夜景", "天津一日游"])
        let opened = await rig.run("trip_plans", ["action": "open", "name": "天津"])
        #expect(opened.ok && opened.data["name"] == "天津一日游" && opened.data["kept_previous"] == false)
        #expect(await rig.planner.current.stops.map(\.place.name) == ["古文化街", "五大道"])
        #expect(await rig.run("trip_plans", ["action": "rename", "name": "天津一日游", "new_name": "周末出游"]).ok)
        #expect(await rig.planner.currentPlan.name == "周末出游")
        #expect(await rig.run("trip_plans", ["action": "delete", "name": "周末出游"]).ok)
        #expect(await rig.run("trip_plans", ["action": "open", "name": "周末出游"]).code == .planNotFound)
        #expect(await rig.planner.current.count == 2)
        #expect(rig.lines.withLock { $0 }.contains("trip plan action=save ok=yes days=1 stops=2"))
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "save"])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "list", "name": "x"])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "save", "name": .string(String(repeating: "长", count: 21))])) == .invalidFields)
        // The saved plans survive a restart.
        let again = await PlanRig(files: rig.files)
        await again.planner.restore()
        #expect(await again.planner.savedPlans.entries.map(\.name) == ["海河夜景"])
    }

    @Test("F-15b row 33: an unnamed plan with stops is kept as 上一个清单 when another plan is opened, and can be opened again")
    func row33() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街"])])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        _ = await rig.run("make_trip_list", ["places": names(["天津之眼", "瓷房子"])])
        let opened = await rig.run("trip_plans", ["action": "open", "name": "天津一日游"])
        #expect(opened.data["kept_previous"] == true && opened.data["next"]?.stringValue?.contains("上一个清单") == true)
        #expect(await rig.run("trip_plans", ["action": "open", "name": "上一个清单"]).ok)
        #expect(await rig.planner.current.stops.map(\.place.name) == ["天津之眼", "瓷房子"])
    }

    @Test("F-15b row 34: a new name with 20 saved is PLANS_FULL (the same name still saves); two names containing it are AMBIGUOUS; save on an empty plan is NO_TRIP_LIST")
    func row34() async {
        let rig = await PlanRig()
        #expect(await rig.run("trip_plans", ["action": "save", "name": "空"]).code == .noTripList)
        _ = await rig.run("make_trip_list", ["places": names(["古文化街"])])
        for i in 1...20 { _ = await rig.run("trip_plans", ["action": "save", "name": .string("行程\(i)")]) }
        #expect(await rig.run("trip_plans", ["action": "save", "name": "第二十一个"]).code == .plansFull)
        #expect(await rig.run("trip_plans", ["action": "save", "name": "行程3"]).ok)
        #expect(await rig.run("trip_plans", ["action": "open", "name": "行程1"]).ok)
        _ = await rig.run("trip_plans", ["action": "delete", "name": "行程10"])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津东"])
        _ = await rig.run("trip_plans", ["action": "delete", "name": "行程11"])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津西"])
        #expect(await rig.run("trip_plans", ["action": "open", "name": "天津"]).code == .ambiguous)
    }

    @Test("F-15b §16 item 7: opening a plan drops a kept trip route; guidance on a running route goes on")
    func openWhileRouting() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街", "五大道"])])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        _ = await rig.run("route_trip", [:])
        #expect(await rig.nav.current.tripRoute)
        _ = await rig.run("trip_plans", ["action": "open", "name": "天津一日游"])
        #expect(await !rig.nav.current.tripRoute)
        _ = await rig.run("route_trip", ["start": true])
        _ = await rig.run("trip_plans", ["action": "open", "name": "天津一日游"])
        #expect(await rig.nav.current.navigating)
    }

    @Test("F-15b §11 item 5: a day tab is edit_trip_list read day; open from 我的行程 sends the open note; while moving both are refused")
    func taps() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街"]), "day": 1])
        _ = await rig.run("make_trip_list", ["places": names(["五大道"]), "day": 2])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津两日游"])
        let day = await rig.planner.tap(.day(1), moving: false)
        let current = await rig.planner.currentPlan.currentDay
        #expect(day.result.ok && day.note == nil && current == 1)
        #expect(await rig.planner.tap(.openPlan("天津两日游"), moving: true).result.code == .notWhileMoving)
        let open = await rig.planner.tap(.openPlan("天津两日游"), moving: false)
        #expect(open.note == "[系统] 司机在屏幕上打开了行程「天津两日游」，现在清单有1个地点。这句不用回答。")
        #expect(rig.lines.withLock { $0 }.contains("trip tap action=open ok=yes"))
        #expect(await rig.planner.tap(.deletePlan("天津两日游"), moving: false).result.ok)
        #expect(await rig.planner.savedPlans.entries.isEmpty)
    }
}

/// Detail calls held until `release()`, counted per place.
final class HeldPhotoSearch: PlaceSearch, @unchecked Sendable {
    let details = Mutex<[String]>([])
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])
    let hold: Bool
    init(hold: Bool) { self.hold = hold }
    var waiting: Int { held.withLock { $0.count } }
    func release() { for c in held.withLock({ h in defer { h = [] }; return h }) { c.resume() } }
    func text(_ keywords: String, city: String?) async throws -> [Place] { tianjin[keywords] ?? [] }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? {
        details.withLock { $0.append(id) }
        if hold { await withCheckedContinuation { c in held.withLock { $0.append(c) } } }
        return spot(id, lat: 0, lng: 0).with(photoURL: URL(string: "https://a.cn/\(id.unicodeScalars.first!.value).jpg"))
    }
}

@Suite("T-040j T-040l F-15b review fixes")
struct TripReviewFixTests {
    func rig(_ search: HeldPhotoSearch) async -> (NavigationController, TripPlanner, ScriptedNaviEngine, TripLines) {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 20_000, seconds: 1_800)])
        let lines = TripLines()
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        let planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: ManualClock(),
                                  onLine: { lines.append($0) })
        return (nav, planner, engine, lines)
    }

    @Test("F-15b §12: a reorder of stops with known photos sends the list with the links; a change while lookups run asks nobody again")
    func photosOnScreen() async {
        let search = HeldPhotoSearch(hold: true)
        let seen = Mutex<[TripList]>([])
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 20_000, seconds: 1_800)])
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        let planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: ManualClock(),
                                  onChange: { list in seen.withLock { $0.append(list) } })
        _ = await planner.execute(trip("make_trip_list", ["places": names(["古文化街", "五大道", "瓷房子"])]))
        for _ in 0..<2000 where search.waiting < 3 { try? await Task.sleep(for: .milliseconds(1)) }
        _ = await planner.execute(trip("edit_trip_list", ["action": "move", "index": 3, "to_index": 1]))
        search.release()
        await planner.photosSettled()
        #expect(search.details.withLock { $0 }.count == 3)
        _ = await planner.execute(trip("make_trip_list", ["places": names(["五大道", "古文化街"])]))
        let last = seen.withLock { $0.last }
        #expect(last?.stops.allSatisfy { $0.place.photoURL != nil } == true)
        #expect(search.details.withLock { $0 }.count == 3)
    }

    @Test("F-15b row 10: a photo arriving after the route was kept does not make the start recalculate")
    func photoAfterKept() async {
        let search = HeldPhotoSearch(hold: true)
        let (nav, planner, engine, _) = await rig(search)
        _ = await planner.execute(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await planner.execute(trip("route_trip", [:]))
        search.release()
        await planner.photosSettled()
        #expect(await planner.execute(trip("route_trip", ["start": true])).ok)
        #expect(engine.calls.withLock { $0 }.filter { $0.hasPrefix("calculate") }.count == 1)
        #expect(await nav.current.navigating)
    }

    @Test("F-15b §15: another day is a plan change: its route is nearest, a day tab drops the other day's kept route, a slow add of day 1 is stale after switching")
    func dayIsAChange() async {
        let search = HeldPhotoSearch(hold: false)
        let (nav, planner, engine, _) = await rig(search)
        _ = await planner.execute(trip("make_trip_list", ["places": names(["古文化街", "五大道"]), "day": 1]))
        _ = await planner.execute(trip("make_trip_list", ["places": names(["天津之眼", "瓷房子"]), "day": 2]))
        _ = await planner.execute(trip("route_trip", ["day": 1]))
        _ = await planner.execute(trip("route_trip", ["day": 2, "start": true]))
        #expect(engine.requests.withLock { $0.last?.destinationName } == "天津之眼")
        _ = await nav.execute(tool("exit_navigation_mode"))
        _ = await planner.execute(trip("route_trip", ["day": 1]))
        #expect(await nav.current.tripRoute)
        _ = await planner.tap(.day(2), moving: false)
        #expect(await !nav.current.tripRoute)
    }

    @Test("F-15b §14 item 4: an unreadable plans.json logs trip load ok=no")
    func badPlans() async {
        let files = MemoryTripFiles()
        files.write("plans.json", Data("[".utf8))
        let rig = await PlanRig(files: files)
        await rig.planner.restore()
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip load ok=no") })
        #expect(files.read("plans.bad.json") != nil)
    }

    @Test("F-15b §13 item 5: an opened plan's pins are not labelled or greyed from the running route")
    func pinsOnlyForTheRoute() {
        let list = TripList.withStops(["古文化街", "五大道"])
        #expect(TripScreen.passed(list, routeStops: ["天津之眼", "瓷房子"], passed: [1]).isEmpty)
        #expect(TripScreen.passed(list, routeStops: ["古文化街", "五大道"], passed: [1]) == [1])
    }
}

@Suite("T-040l F-15b review fixes 2")
struct TripReviewFix2Tests {
    @Test("F-15b §15: a look at day 2 during day 1's guidance, then start day 1 again: already running, no new calculation; tripStopIDs follow the route")
    func lookAtOtherDay() async {
        let rig = await PlanRig()
        _ = await rig.run("make_trip_list", ["places": names(["古文化街", "五大道"]), "day": 1])
        _ = await rig.run("make_trip_list", ["places": names(["天津之眼", "瓷房子"]), "day": 2])
        _ = await rig.run("route_trip", ["day": 1])
        let ids = await rig.planner.current.stops.map(\.place.id)
        #expect(await rig.nav.current.tripStopIDs == ids)
        _ = await rig.run("route_trip", ["day": 1, "start": true])
        #expect(await rig.nav.current.tripStopIDs == ids)
        _ = await rig.run("edit_trip_list", ["action": "read", "day": 2])
        let again = await rig.run("route_trip", ["day": 1, "start": true])
        #expect(again.ok)
        #expect(rig.engine.calls.withLock { $0 }.filter { $0.hasPrefix("calculate") }.count == 1)
        #expect(!rig.engine.calls.withLock { $0 }.contains("stop"))
        _ = await rig.nav.execute(tool("exit_navigation_mode"))
        #expect(await rig.nav.current.tripStopIDs.isEmpty)
    }

    @Test("F-15b row 36: one make_trip_list days=[[…],[…],[…]] makes a new 3-day plan, replaces an older 4-day one, day 1 current, a place twice is a duplicate")
    func row36() async {
        let rig = await PlanRig(files: MemoryTripFiles())
        for d in 1...4 { _ = await rig.run("make_trip_list", ["places": names(["海河"]), "day": .int(Int64(d))]) }
        let r = await rig.run("make_trip_list", ["days": .array([names(["古文化街", "五大道"]), names(["天津之眼", "古文化街"]),
                                                                 names(["瓷房子", "盘山"])])])
        #expect(r.ok && r.data["days"] == .int(3) && r.data["day"] == .int(1))
        #expect(r.data["duplicates"] == names(["古文化街"]) && r.data["not_found"] == names(["盘山"]))
        let plan = await rig.planner.currentPlan
        #expect(plan.days.map { $0.stops.map(\.place.name) } == [["古文化街", "五大道"], ["天津之眼"], ["瓷房子"]])
        #expect(plan.name == nil)
        #expect(r.data["next"]?.stringValue?.contains("3天的行程做好了（第1天2个，第2天1个，第3天1个）") == true)
    }

    @Test("F-15b row 36b: day 1 found nothing: it stays as an empty day and day 2 is current; nothing found anywhere is NO_CANDIDATES")
    func row36b() async {
        let rig = await PlanRig(files: MemoryTripFiles())
        let r = await rig.run("make_trip_list", ["days": .array([names(["盘山"]), names(["五大道"])])])
        #expect(r.ok && r.data["day"] == .int(2) && r.data["count"] == .int(1))
        let none = await rig.run("make_trip_list", ["days": .array([names(["盘山"]), names(["盘山"])])])
        #expect(none.code == .noCandidates)
        #expect(await rig.planner.currentPlan.days.count == 2)
    }

    @Test("F-15b row 37: days and places together, days with day, 6 days, or an empty day are invalidFields")
    func row37() {
        let ok = trip("make_trip_list", ["days": .array([names(["古文化街"]), names(["五大道"])])])
        #expect(ToolCatalog.validate(ok) == nil)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["days": .array([names(["古文化街"])]), "places": names(["五大道"])])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["days": .array([names(["古文化街"])]), "day": 1])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["days": .array(Array(repeating: names(["古文化街"]), count: 6))])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["days": .array([names(["古文化街"]), .array([])])])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", [:])) == .invalidFields)
    }

    @Test("F-15b row 38: the make_trip_list text says to pick places herself and not ask, and to use days for a multi-day plan")
    func row38() {
        let d = ToolCatalog.makeTripListDescription
        #expect(d.contains("没推荐过就直接凭自己的知识挑有名的景点，不要反问去哪里"))
        #expect(d.contains("几天的行程一次调用，用 days 代替 places"))
    }
}
