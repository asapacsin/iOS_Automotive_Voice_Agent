import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Driving seconds from `seconds(origin, destination)`; nil makes that pair missing. Counts requests.
final class FakeDrivingTimes: DrivingTimes, @unchecked Sendable {
    let seconds: @Sendable (GeoCoordinate, GeoCoordinate) -> Int?
    let requests = Mutex(0)
    init(_ seconds: @escaping @Sendable (GeoCoordinate, GeoCoordinate) -> Int?) { self.seconds = seconds }
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        requests.withLock { $0 += 1 }
        return origins.map { o in seconds(o, destination).map { DrivingTime(meters: $0 * 10, seconds: $0) } }
    }
}

/// Seconds by latitude difference (tianjin stops lie on one line north of the origin), ×10 000.
let byLine: @Sendable (GeoCoordinate, GeoCoordinate) -> Int? = { Int((abs($0.latitude - $1.latitude) * 10_000).rounded()) }

func timesRig(_ seconds: @escaping @Sendable (GeoCoordinate, GeoCoordinate) -> Int? = byLine, noOrigin: Bool = false,
              table: [String: [Place]] = tianjin, notes: TripLines? = nil, search: TripSearch? = nil,
              here: GeoCoordinate? = nil, abroad: (any PlaceSearch)? = nil,
              handoff: (@Sendable (Place) async -> Bool)? = nil,
              center: (@Sendable (String) async -> GeoCoordinate?)? = nil) async -> (TripRig, FakeDrivingTimes) {
    let service = FakeDrivingTimes(seconds)
    let rig = await TripRig(search: search ?? TripSearch(table), times: TripTimes(service: service, clock: ManualClock(), retryDelay: .milliseconds(1)),
                            noOrigin: noOrigin, notes: notes, here: here, abroad: abroad, handoff: handoff, center: center)
    return (rig, service)
}

func dayNames(_ rig: TripRig) async -> [[String]] {
    await rig.planner.currentPlan.days.map { $0.stops.map(\.place.name) }
}

@Suite("T-040n F-15b phase 3 plan ordered by driving time, one stop at a time")
struct TripPhase3Tests {
    // MARK: §27 optimizer

    @Test("F-15b row 65: 4 stops: the order with the smallest total driving time; equal totals keep the current order")
    func row65() {
        // Node 0 is the start. Straight-line would visit 1 first; driving says 3, 1, 2, 4.
        let m: [[Int]] = [
            [0, 50, 90, 10, 80],
            [50, 0, 10, 40, 70],
            [90, 10, 0, 60, 10],
            [10, 15, 60, 0, 90],
            [80, 70, 10, 90, 0],
        ]
        let path = TripOptimizer.path([1, 2, 3, 4], from: 0) { m[$0][$1] }
        #expect(path == [3, 1, 2, 4])
        #expect(TripOptimizer.cost(path, from: 0) { m[$0][$1] } == 45)
        // All equal: the current order stays.
        #expect(TripOptimizer.path([4, 2, 3, 1], from: 0) { _, _ in 7 } == [4, 2, 3, 1])
    }

    @Test("F-15b row 66: 10 stops: nearest + 2-opt is no longer than nearest alone; every stop once")
    func row66() {
        let xs: [Double] = [0, 3, 9, 1, 7, 4, 8, 2, 6, 5, 10]
        let ys: [Double] = [0, 5, 1, 8, 6, 2, 9, 3, 7, 4, 0]
        let time: (Int, Int) -> Int = { a, b in Int((hypot(xs[a] - xs[b], ys[a] - ys[b]) * 100).rounded()) }
        let stops = Array(1...10)
        let path = TripOptimizer.path(stops, from: 0, time: time)
        #expect(path.sorted() == stops)
        let nearest = TripOptimizer.nearest(stops, from: 0, time: time)
        #expect(TripOptimizer.cost(path, from: 0, time: time) <= TripOptimizer.cost(nearest, from: 0, time: time))
    }

    @Test("F-15b row 68: 6 stops, 3 days: consecutive days of at least 1 stop; the longest day is the smallest possible")
    func row68() {
        let path = [1, 2, 3, 4, 5, 6]
        let legs = [0: 0, 1: 600, 2: 600, 3: 9_000, 4: 600, 5: 7_200, 6: 600]
        let time: (Int, Int) -> Int = { a, b in b == a + 1 ? legs[b]! : 99_999 }
        let days = TripOptimizer.cut(path, from: 0, days: 3, time: time)
        #expect(days.count == 3 && days.allSatisfy { !$0.isEmpty } && days.flatMap { $0 } == path)
        func longest(_ d: [[Int]]) -> Int {
            d.map { day in day.reduce(0) { $0 + time($1 - 1, $1) + TripOptimizer.visitSeconds } }.max()!
        }
        var best = Int.max
        for i in 1...4 { for j in (i + 1)...5 { best = min(best, longest([Array(path[0..<i]), Array(path[i..<j]), Array(path[j...])])) } }
        #expect(longest(days) == best)
    }

    // MARK: §28 the plan

    @Test("F-15b row 67: reorganize start=天津之眼 puts it first, the rest by driving time from it; start=named")
    func row67() async {
        let (rig, _) = await timesRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["五大道", "古文化街", "天津之眼"])]))
        #expect(await rig.order() == ["五大道", "古文化街", "天津之眼"])
        let r = await rig.run(trip("edit_trip_list", ["action": "reorganize", "start": "天津之眼"]))
        #expect(r.ok)
        #expect(await rig.order() == ["天津之眼", "古文化街", "五大道"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip order ok=yes stops=3 days=1 start=named") })
    }

    @Test("F-15b row 69: a reorganize keeps the same place ids; a faked ordering with another id is PLAN_CHANGED, plan unchanged")
    func row69() async {
        let (rig, _) = await timesRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "五大道", "古文化街"])]))
        let before = await dayNames(rig)
        await rig.planner.setTamper { days in
            var d = days
            var list = TripList()
            list.replace([("x", spot("别的地方", lat: 39.3, lng: 117.2), nil)])
            d[0] = list
            return d
        }
        let r = await rig.run(trip("edit_trip_list", ["action": "reorganize"]))
        #expect(r.code == .planChanged)
        #expect(await dayNames(rig) == before)
    }

    @Test("F-15b row 70: reorganize start not in the plan is searched once (§37 item 5), NOT_FOUND when nothing; two matches AMBIGUOUS")
    func row70() async {
        var table = tianjin
        table["五大道博物馆"] = [spot("五大道博物馆", lat: 39.045, lng: 117.2)]
        let (rig, _) = await timesRig(table: table)
        _ = await rig.run(trip("make_trip_list", ["places": names(["五大道", "五大道博物馆", "古文化街"])]))
        let asked = rig.search.asked.withLock { $0.count }
        #expect(await rig.run(trip("edit_trip_list", ["action": "reorganize", "start": "环宇城"])).code == .notFound)
        #expect(rig.search.asked.withLock { $0.count } == asked + 1)
        #expect(await rig.run(trip("edit_trip_list", ["action": "reorganize", "start": "五大道"])).code == .ambiguous)
    }

    @Test("F-15b row 71: no position and no start: NO_START, plan unchanged, no 高德 request")
    func row71() async {
        let (rig, service) = await timesRig(noOrigin: true)
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "五大道"])]))
        let before = service.requests.withLock { $0 }
        #expect(await rig.run(trip("edit_trip_list", ["action": "reorganize"])).code == .noStart)
        #expect(await rig.order() == ["天津之眼", "五大道"])
        #expect(service.requests.withLock { $0 } == before)
    }

    @Test("F-15b row 72: one pair's time missing after retries: ROUTE_TIMES_UNAVAILABLE, plan unchanged")
    func row72() async {
        let eye = 39.16
        let (rig, _) = await timesRig { a, b in a.latitude == eye && b.latitude != eye ? nil : byLine(a, b) }
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "五大道", "古文化街"])]))
        #expect(await rig.order() == ["天津之眼", "五大道", "古文化街"])
        #expect(await rig.run(trip("edit_trip_list", ["action": "reorganize"])).code == .routeTimesUnavailable)
        #expect(await rig.order() == ["天津之眼", "五大道", "古文化街"])
    }

    @Test("F-15b row 73: a second reorganize within 30 minutes makes no 高德 request; trip order … cached=")
    func row73() async {
        let (rig, service) = await timesRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "五大道", "古文化街"])]))
        _ = await rig.run(trip("edit_trip_list", ["action": "reorganize"]))
        let before = service.requests.withLock { $0 }
        #expect(await rig.run(trip("edit_trip_list", ["action": "reorganize"])).ok)
        #expect(service.requests.withLock { $0 } == before)
        #expect(rig.lines.withLock { $0 }.last { $0.hasPrefix("trip order") }?.contains("requests=0 cached=3") == true)
    }

    @Test("F-15b row 74 (with §48 item 4.4): make_trip_list days=[[A,B],[C]] comes back ordered by driving time, each place on its group's day, with plan")
    func row74() async {
        let (rig, _) = await timesRig()
        let r = await rig.run(trip("make_trip_list", ["days": [names(["天津之眼", "瓷房子"]), names(["五大道"])]]))
        #expect(r.ok)
        // §48 item 4.4 (T-040t) replaces the re-cut of §27 item 3: each group stays a day, ordered from the origin
        // (39.00) north: 瓷房子 39.02, then 天津之眼 39.16; day 2 is 五大道.
        #expect(await dayNames(rig) == [["瓷房子", "天津之眼"], ["五大道"]])
        #expect(r.data["plan"] == [names(["瓷房子", "天津之眼"]), names(["五大道"])])
        #expect(await rig.order() == ["瓷房子", "天津之眼"])
    }

    @Test("F-15b row 75: move index=1 to_day=1 puts the stop on day 1, ordered; the place set unchanged")
    func row75() async {
        let (rig, _) = await timesRig { a, b in byLine(a, b) }
        _ = await rig.run(trip("make_trip_list", ["places": names(["瓷房子", "天津之眼"]), "day": 1]))
        _ = await rig.run(trip("make_trip_list", ["places": names(["南开大学", "五大道"]), "day": 2]))
        // Day 2 was ordered from the origin: 五大道 (39.04) before 南开大学 (39.25).
        #expect(await dayNames(rig)[1] == ["五大道", "南开大学"])
        let all = await rig.planner.currentPlan.allStops.map(\.stop.place.id).sorted()
        let r = await rig.run(trip("edit_trip_list", ["action": "move", "index": 1, "to_day": 1, "day": 2]))
        #expect(r.ok, "\(r)")
        let days = await dayNames(rig)
        #expect(days[0].count == 3 && days[0].contains("五大道") && days[1] == ["南开大学"])
        // Ordered from its first stop 瓷房子 (39.02): 五大道 39.04, then 天津之眼 39.16.
        #expect(days[0] == ["瓷房子", "五大道", "天津之眼"])
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.id).sorted() == all)
    }

    // MARK: §29 one stop at a time

    @Test("F-15b row 76: trip_next with stop 1 visited drives to stop 2, a single destination; stop 3 is the one after")
    func row76() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "天津之眼"])]))
        _ = await rig.run(trip("edit_trip_list", ["action": "visited", "index": 1]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["status"] == "trip_next" && r.data["index"] == .int(2) && r.data["name"] == "五大道")
        #expect(r.data["after"] == "天津之眼")
        let request = rig.engine.requests.withLock { $0.last }
        #expect(request?.destinationName == "五大道")
        #expect(await rig.nav.current.tripStopID == "五大道")
        #expect(rig.lines.withLock { $0 }.contains("trip next index=2 day=1 ok=yes code=none"))
        #expect(rig.lines.withLock { $0 }.contains("trip visit index=1 day=1 by=voice"))
    }

    @Test("F-15b row 77: arrived at the stop marks it visited and sends the note; guidance stopped early marks nothing")
    func row77() async {
        let notes = TripLines()
        let rig = await TripRig(notes: notes)
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await rig.run(trip("trip_next"))
        // Stopped early: no mark.
        _ = await rig.nav.execute(trip("exit_navigation_mode"))
        #expect(await rig.planner.currentPlan.days[0].stops[0].mark == nil)
        _ = await rig.run(trip("trip_next"))
        rig.engine.emit(.arrived, generation: await rig.nav.current.generation)
        for _ in 0..<200 where await rig.planner.currentPlan.days[0].stops[0].mark == nil { await Task.yield() }
        #expect(await rig.planner.currentPlan.days[0].stops[0].mark == .visited)
        #expect(notes.withLock { $0 }.first?.hasPrefix("[系统] 已到达第1站古文化街。下一站是五大道") == true)
        #expect(rig.lines.withLock { $0 }.contains("trip visit index=1 day=1 by=arrival"))
    }

    @Test("F-15b row 78: every stop of the day visited or skipped: trip_next is DAY_DONE")
    func row78() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await rig.run(trip("edit_trip_list", ["action": "visited", "index": 1]))
        _ = await rig.run(trip("edit_trip_list", ["action": "skip", "index": 2]))
        #expect(await rig.run(trip("trip_next")).code == .dayDone)
    }

    @Test("F-15b row 79: trip_plans open has plan with every day's names and marks")
    func row79() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["days": [names(["古文化街", "五大道"]), names(["天津之眼"])]]))
        _ = await rig.run(trip("edit_trip_list", ["action": "visited", "index": 1]))
        _ = await rig.run(trip("trip_plans", ["action": "save", "name": "天津两日"]))
        let r = await rig.run(trip("trip_plans", ["action": "open", "name": "天津两日"]))
        #expect(r.data["plan"] == [names(["古文化街（已去过）", "五大道"]), names(["天津之眼"])])
    }

    @Test("F-15b row 80: no route_trip; trip_next declared; the §31 texts present")
    func row80() {
        let declared = ToolCatalog.declarations(webSearch: false).map(\.name)
        #expect(!declared.contains("route_trip") && declared.contains("trip_next"))
        func text(_ n: String) -> String { ToolCatalog.spec(n)!.declaration.description }
        #expect(text("make_trip_list").contains("清单会按司机现在的位置和真实车程自动排好顺序、分好天。"))
        #expect(text("edit_trip_list").contains("「重新排一下」「从横琴开始重新排」→reorganize（start 填清单里的地点名，days 填天数）；「把X放到第二天」→move 加 to_day；「已经去过了」→visited；「跳过这个」→skip。按结果的 plan 说每天去哪。NO_START=问司机从哪里出发。"))
        #expect(text("trip_next").hasPrefix("行程按站导航：「开始第一天」「去下一站」「先去长隆」→trip_next（day、stop 可选）。一次只导航到一个地点。按 next 说一句；DAY_DONE=问要不要开始下一天。"))
        #expect(text("trip_plans").contains("打开后要导航就调用 trip_next。") && !text("trip_plans").contains("route_trip"))
        #expect(ToolCatalog.validate(trip("trip_next", ["day": 2, "stop": "长隆"])) == nil)
        #expect(ToolCatalog.validate(trip("edit_trip_list", ["action": "reorganize", "start": "横琴", "days": 2])) == nil)
        #expect(ToolCatalog.validate(trip("edit_trip_list", ["action": "remove", "index": 1, "start": "x"])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("edit_trip_list", ["action": "visited"])) == .invalidFields)
    }

    // MARK: review fixes

    @Test("F-15b §29 item 1: trip_next while guiding stops the old guidance first, as 换成X")
    func nextReplacesGuidance() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await rig.run(trip("trip_next"))
        #expect(await rig.nav.current.navigating)
        rig.engine.calls.withLock { $0.removeAll() }
        _ = await rig.run(trip("edit_trip_list", ["action": "skip", "index": 1]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["name"] == "五大道")
        let calls = rig.engine.calls.withLock { $0 }
        #expect(calls.first == "stop")
        #expect(await rig.nav.current.destination?.name == "五大道")
    }

    @Test("F-15b §26 item 3: a timed-out or failed request is tried up to twice more")
    func timesRetry() async {
        final class Flaky: DrivingTimes, @unchecked Sendable {
            let fails = Mutex(0)
            func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
                let n = fails.withLock { $0 += 1; return $0 }
                if n == 1 { throw AmapWebError.timeout }
                if n == 2 { throw AmapWebError.failed }
                return origins.map { _ in DrivingTime(meters: 10, seconds: 1) }
            }
        }
        let flaky = Flaky()
        let times = TripTimes(service: flaky, clock: ManualClock(), parallel: 1, retryDelay: .milliseconds(1))
        let a = spot("古文化街", lat: 39.10, lng: 117.20)
        let table = await times.table(start: .here(spot("五大道", lat: 39.04, lng: 117.20).coordinate), stops: [TripTimes.Node(key: a.id, coordinate: a.coordinate)])
        #expect(table != nil)
        #expect(flaky.fails.withLock { $0 } == 3)
    }

    @Test("F-15b §29 item 4: a hand edit drops the known driving times")
    func editDropsLegs() {
        let p = spot("古文化街", lat: 39.10, lng: 117.20), q = spot("五大道", lat: 39.04, lng: 117.20)
        var list = TripList()
        list.arrange([TripStop(index: 1, asked: "a", place: p, distanceMeters: nil, legSeconds: 60), TripStop(index: 2, asked: "b", place: q, distanceMeters: nil, legSeconds: 120)])
        list.move(from: 2, to: 1)
        #expect(list.stops.allSatisfy { $0.legSeconds == nil })
    }
}
