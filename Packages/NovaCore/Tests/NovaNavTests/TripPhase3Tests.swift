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

    @Test("F-15b row 76: trip_next with stop 1 visited drives to stop 2, a single destination; stop 3 is the one after")
    func row76() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼"])]))
        await rig.planner.markForTests(index: 1, .visited)
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["status"] == "trip_next" && r.data["index"] == .int(2) && r.data["name"] == "五大道")
        #expect(r.data["after"] == "天津之眼")
        let request = rig.engine.requests.withLock { $0.last }
        #expect(request?.destinationName == "五大道")
        #expect(await rig.nav.current.tripStopID == "五大道")
        #expect(rig.lines.withLock { $0 }.contains("trip next index=2 day=1 ok=yes code=none"))
    }

    @Test("F-15b row 77: arrived at the stop marks it visited and sends the note; guidance stopped early marks nothing")
    func row77() async {
        let notes = TripLines()
        let rig = await TripRig(notes: notes)
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
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
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        await rig.planner.markForTests(index: 1, .visited)
        await rig.planner.markForTests(index: 2, .skipped)
        let done = await rig.run(trip("trip_next"))
        #expect(done.code == .dayDone)
        // F-09b §13 row 7 (T-031o): the last day is done; no next day is offered.
        #expect(done.advice == nil && done.data["facts"] == .object(["day": .int(1), "day_count": .int(1)]))
        #expect(done.data["may"] == .array([]))
        #expect(done.data["must_not"] == .array([.string("claim_started"), .string("invent")]))
    }

    @Test("F-15b row 79: trip_plans open has plan with every day's names and marks")
    func row79() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["days": [names(["古文化街", "五大道"]), names(["天津之眼"])]]))
        await rig.planner.markForTests(index: 1, .visited)
        _ = await rig.run(trip("trip_plans", ["action": "save", "name": "天津两日"]))
        let r = await rig.run(trip("trip_plans", ["action": "open", "name": "天津两日"]))
        #expect(planNames(r.data["plan"]) == [names(["古文化街（已去过）", "五大道"]), names(["天津之眼"])])
    }

    @Test("F-15b row 80: no route_trip; trip_next declared; the §31 texts present")
    func row80() {
        let declared = ToolCatalog.declarations(webSearch: false).map(\.name)
        #expect(!declared.contains("route_trip") && declared.contains("trip_next"))
        func text(_ n: String) -> String { ToolCatalog.spec(n)!.declaration.description }
        #expect(text("trip_next").hasPrefix("行程按站导航：「开始第一天」「去下一站」「先去长隆」→trip_next（day、stop 可选）。一次只导航到一个地点。按 next 说一句；DAY_DONE=问要不要开始下一天。"))
        #expect(text("trip_plans").contains("打开后要导航就调用 trip_next。") && !text("trip_plans").contains("route_trip"))
        #expect(ToolCatalog.validate(trip("trip_next", ["day": 2, "stop": "长隆"])) == nil)
        // §55 item 11 (T-040zh): make_trip_list and edit_trip_list are removed.
        #expect(!declared.contains("make_trip_list") && !declared.contains("edit_trip_list"))
    }

    // MARK: review fixes

    @Test("F-15b §29 item 1: trip_next while guiding stops the old guidance first, as 换成X")
    func nextReplacesGuidance() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        _ = await rig.run(trip("trip_next"))
        #expect(await rig.nav.current.navigating)
        rig.engine.calls.withLock { $0.removeAll() }
        await rig.planner.markForTests(index: 1, .skipped)
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
