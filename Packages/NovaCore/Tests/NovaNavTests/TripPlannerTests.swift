import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Answers each name from a table; a name in `slow` waits until `release()`.
final class TripSearch: PlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let slow: Set<String>
    let error: AmapWebError?
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])
    let asked = Mutex<[String]>([])
    let returned = Mutex(0)

    init(_ table: [String: [Place]], slow: Set<String> = [], error: AmapWebError? = nil) {
        self.table = table
        self.slow = slow
        self.error = error
    }

    var waiting: Int { held.withLock { $0.count } }
    func release() { for c in held.withLock({ c in defer { c = [] }; return c }) { c.resume() } }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        if slow.contains(keywords) { await withCheckedContinuation { c in held.withLock { $0.append(c) } } }
        if let error { throw error }
        defer { returned.withLock { $0 += 1 } }
        return table[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

func spot(_ name: String, id: String? = nil, lat: Double, lng: Double) -> Place {
    Place(id: id ?? name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, district: "和平区")
}

func trip(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(id: CallID("t1")!, name: name, arguments: .object(args))
}

func names(_ list: [String]) -> JSONValue { .array(list.map { .string($0) }) }

/// Tianjin-ish stops on a line north of the origin, so nearest-next is predictable.
let origin = GeoCoordinate(latitude: 39.00, longitude: 117.20, datum: .gcj02)
let tianjin: [String: [Place]] = [
    "古文化街": [spot("古文化街", lat: 39.10, lng: 117.20)],
    "五大道": [spot("五大道", lat: 39.04, lng: 117.20)],
    "天津之眼": [spot("天津之眼", lat: 39.16, lng: 117.20)],
    "瓷房子": [spot("瓷房子", lat: 39.02, lng: 117.20)],
    "意式风情区": [spot("意式风情区", lat: 39.13, lng: 117.20)],
    "海河": [spot("海河观光", lat: 39.07, lng: 117.20)],
    "水上公园": [spot("天津水上公园", lat: 39.20, lng: 117.20)],
    "南开大学": [spot("南开大学", lat: 39.25, lng: 117.20)],
    "西开教堂": [spot("五大道", lat: 39.05, lng: 117.20)],
    "盘山": [spot("蓟州农家饭店", lat: 39.30, lng: 117.20)],
    "古文化街旅游区": [spot("古文化街", lat: 39.10, lng: 117.20)],
]

final class TripLines: Sendable {
    let all = Mutex<[String]>([])
    func withLock(_ body: (inout [String]) -> [String]) -> [String] { all.withLock { body(&$0) } }
    func append(_ line: String) { all.withLock { $0.append(line) } }
}

struct TripRig {
    let search: TripSearch
    let engine: ScriptedNaviEngine
    let nav: NavigationController
    let planner: TripPlanner
    let lines = TripLines()

    init(search: TripSearch = TripSearch(tianjin), engine: ScriptedNaviEngine? = nil, tuning: NovaNav.NavigationTuning = NovaNav.NavigationTuning(),
         clock: any NovaClock = ManualClock(), resolveLimit: NovaDuration = .seconds(15)) async {
        self.search = search
        let engine = engine ?? ScriptedNaviEngine(routes: [route(1, meters: 156_000, seconds: 14_640, toll: 20)])
        self.engine = engine
        let lines = self.lines
        nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: clock, tuning: tuning,
                                   onTripLine: { line in lines.append(line) })
        await nav.start()
        var t = TripTuning()
        t.resolveLimit = resolveLimit
        planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: clock, tuning: t,
                              onLine: { line in lines.append(line) })
    }

    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func order() async -> [String] { await planner.current.stops.map(\.place.name) }
}

@Suite("T-040i F-15b phase 1 trip list")
struct TripPlannerTests {
    @Test("F-15b row 1: 8 names, 7 found, the 8th's first result has an unrelated name: count 7, not_found, one nomatch line")
    func row1() async {
        let rig = await TripRig()
        let r = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区",
                                                                      "海河", "水上公园", "盘山"]), "city": "天津"]))
        #expect(r.ok && r.data["count"] == .int(7))
        #expect(r.data["not_found"] == names(["盘山"]))
        guard case .array(let stops)? = r.data["stops"] else { Issue.record("stops"); return }
        #expect(stops.compactMap { $0["index"] } == (1...7).map { .int(Int64($0)) })
        let lookups = rig.lines.withLock { $0 }.filter { $0.hasPrefix("trip lookup") }
        #expect(lookups == ["trip lookup index=8 ok=no reason=nomatch"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip list stops=7 not_found=1 duplicates=0 ms=") })
    }

    @Test("F-15b row 2: two names resolve to the same place id: one stop, the other in duplicates")
    func row2() async {
        let rig = await TripRig()
        let r = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "古文化街旅游区", "五大道"])]))
        #expect(r.data["count"] == .int(2))
        #expect(r.data["duplicates"] == names(["古文化街旅游区"]))
    }

    @Test("F-15b row 3: 17 names or a blank name are invalidFields; the list is unchanged")
    func row3() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        let many = await rig.run(trip("make_trip_list", ["places": names((1...17).map { "地点\($0)" })]))
        #expect(many.code == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": names(["古文化街", "  "])])) == .invalidFields)
        let blank = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "  "])]))
        #expect(blank.code == .invalidFields)
        #expect(await rig.order() == ["古文化街", "五大道"])
    }

    @Test("F-15b row 4: remove index, remove by name, move, then replace out of range changes nothing")
    func row4() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区"])]))
        #expect(await rig.run(trip("edit_trip_list", ["action": "remove", "index": 2])).data["changed"] == "removed")
        #expect(await rig.order() == ["古文化街", "天津之眼", "瓷房子", "意式风情区"])
        #expect(await rig.run(trip("edit_trip_list", ["action": "remove", "name": "古文化街"])).ok)
        #expect(await rig.order() == ["天津之眼", "瓷房子", "意式风情区"])
        let moved = await rig.run(trip("edit_trip_list", ["action": "move", "index": 3, "to_index": 1]))
        #expect(moved.data["changed"] == "moved")
        #expect(await rig.order() == ["意式风情区", "天津之眼", "瓷房子"])
        #expect(await rig.planner.current.stops.map(\.index) == [1, 2, 3])
        let out = await rig.run(trip("edit_trip_list", ["action": "replace", "index": 9, "name": "五大道"]))
        #expect(out.code == .outOfRange)
        #expect(await rig.order() == ["意式风情区", "天津之眼", "瓷房子"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasSuffix("action=replace ok=no") })
    }

    @Test("F-15b row 5: a name matching two stops is AMBIGUOUS; any action but add/clear on an empty list is NO_TRIP_LIST")
    func row5() async {
        let rig = await TripRig()
        for action in ["read", "remove", "move"] {
            var args: [String: JSONValue] = ["action": .string(action)]
            if action == "remove" { args["index"] = 1 }
            if action == "move" { args["index"] = 1; args["to_index"] = 2 }
            #expect(await rig.run(trip("edit_trip_list", args)).code == .noTripList)
        }
        #expect(await rig.run(trip("edit_trip_list", ["action": "clear"])).ok)
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "水上公园"])]))
        let both = await rig.run(trip("edit_trip_list", ["action": "remove", "name": "天津"]))
        #expect(both.code == .ambiguous)
        #expect(await rig.order() == ["天津之眼", "天津水上公园"])
    }

    @Test("F-15b row 6: an add whose lookup is slow returns OPTIONS_STALE after make_trip_list replaced the list")
    func row6() async {
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]))
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        let add = Task { await rig.run(trip("edit_trip_list", ["action": "add", "name": "南开大学"])) }
        for _ in 0..<2000 where rig.search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(rig.search.waiting == 1)
        let fresh = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "瓷房子"])]))
        #expect(fresh.ok)
        rig.search.release()
        #expect(await add.value.code == .optionsStale)
        #expect(await rig.order() == ["天津之眼", "瓷房子"])
    }

    @Test("F-15b row 7: nearest reorders the list; the request has the last stop as destination and the others as waypoints")
    func row7() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "古文化街", "瓷房子", "五大道"])]))
        let r = await rig.run(trip("route_trip", [:]))
        #expect(r.ok && r.data["started"] == false)
        #expect(await rig.order() == ["瓷房子", "五大道", "古文化街", "天津之眼"])
        let request = rig.engine.requests.withLock { $0.last }
        #expect(request?.destinationName == "天津之眼")
        #expect(request?.waypoints.map(\.latitude) == [39.02, 39.04, 39.10])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip route stops=4 order=nearest km=156.0 min=244 started=no") })
        #expect(r.data["next"]?.stringValue?.contains("全程约156公里，大约4小时4分钟") == true)
    }

    @Test("F-15b row 8: as_listed keeps the order and the waypoints are in list order")
    func row8() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["天津之眼", "古文化街", "瓷房子", "五大道"])]))
        #expect(await rig.run(trip("route_trip", ["order": "as_listed"])).ok)
        #expect(await rig.order() == ["天津之眼", "古文化街", "瓷房子", "五大道"])
        let request = rig.engine.requests.withLock { $0.last }
        #expect(request?.destinationName == "五大道")
        #expect(request?.waypoints.map(\.latitude) == [39.16, 39.10, 39.02])
    }

    @Test("F-15b row 10: start=false starts nothing and keeps the route; then start=true twice starts exactly once, no new calculation")
    func row10() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "瓷房子"])]))
        _ = await rig.run(trip("route_trip", ["start": false]))
        #expect(!rig.engine.calls.withLock { $0 }.contains { $0.hasPrefix("start") })
        let kept = await rig.nav.current
        #expect(kept.phase == .awaitingRouteSelection && kept.tripRoute)
        // A choice while the trip route is kept changes nothing.
        let choose = await rig.nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(choose.data["status"] == "route_unchanged")
        let first = await rig.run(trip("route_trip", ["start": true]))
        let second = await rig.run(trip("route_trip", ["start": true]))
        #expect(first.ok && first.data["started"] == true && second.ok)
        #expect(first.data["next"]?.stringValue?.contains("已开始模拟导航，第一站是瓷房子") == true)
        let calls = rig.engine.calls.withLock { $0 }
        #expect(calls.filter { $0.hasPrefix("calculate") }.count == 1)
        #expect(calls.filter { $0.hasPrefix("start") }.count == 1)
        #expect(await rig.nav.current.navigating)
    }

    @Test("F-15b row 11: a removed stop makes the start recalculate without it; navigate_to drops the kept route, the list stays")
    func row11() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "瓷房子"])]))
        _ = await rig.run(trip("route_trip", ["order": "as_listed"]))
        _ = await rig.run(trip("edit_trip_list", ["action": "remove", "name": "五大道"]))
        #expect(await rig.run(trip("route_trip", ["order": "as_listed", "start": true])).ok)
        let requests = rig.engine.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.last?.destinationName == "瓷房子" && requests.last?.waypoints.count == 1)
        _ = await rig.nav.execute(tool("exit_navigation_mode"))
        _ = await rig.run(trip("route_trip", ["order": "as_listed"]))
        #expect(await rig.nav.current.tripRoute)
        _ = await rig.nav.execute(tool("navigate_to", ["destination": "天津之眼"]))
        #expect(await !rig.nav.current.tripRoute)
        #expect(await rig.order() == ["古文化街", "瓷房子"])
    }

    @Test("F-15b row 13: one stop is TRIP_TOO_SHORT; an engine failure ROUTE_CALCULATION_FAILED; no confirm START_FAILED, never a start claim")
    func row13() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街"])]))
        #expect(await rig.run(trip("route_trip", [:])).code == .tripTooShort)

        let failing = await TripRig(engine: ScriptedNaviEngine(routes: []))
        _ = await failing.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        #expect(await failing.run(trip("route_trip", [:])).code == .routeCalculationFailed)

        var quick = NovaNav.NavigationTuning()
        quick.startWait = .milliseconds(50)
        let silent = await TripRig(engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)], failStart: true),
                                   tuning: quick, clock: SystemClock())
        _ = await silent.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        let r = await silent.run(trip("route_trip", ["start": true]))
        #expect(r.code == .startFailed)
        #expect(r.data["started"] == nil && !(r.data["next"]?.stringValue?.contains("已开始") ?? false))
        #expect(await !silent.nav.current.navigating)
        #expect(silent.lines.withLock { $0 }.contains { $0.contains("started=no") })
    }

    @Test("F-15b §4 items 4-5: a lookup still running at the limit is a timeout; a missing key is AMAP_WEB_KEY_MISSING")
    func limits() async {
        let clock = ManualClock()
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]), clock: clock)
        let made = Task { await rig.run(trip("make_trip_list", ["places": names(["古文化街", "南开大学"])])) }
        // The fast lookup has returned and the slow one is held; then the 15 s limit passes.
        for _ in 0..<5000 where rig.search.waiting == 0 || rig.search.returned.withLock({ $0 }) == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(16))
        let r = await made.value
        #expect(r.data["count"] == .int(1) && r.data["not_found"] == names(["南开大学"]), "\(r)")
        #expect(rig.lines.withLock { $0 }.contains("trip lookup index=2 ok=no reason=timeout"))
        rig.search.release()
        let noKey = await TripRig(search: TripSearch(tianjin, error: .keyMissing))
        #expect(await noKey.run(trip("make_trip_list", ["places": names(["古文化街"])])).code == .amapWebKeyMissing)
    }

    @Test("F-15b row 12 (controller): the engine's stop-passed events give one trip stop-passed line each, only on a running trip")
    func stopPassedLines() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道", "瓷房子", "天津之眼"])]))
        _ = await rig.run(trip("route_trip", [:]))
        var g = await rig.nav.current.generation
        // Kept, not running: not counted.
        rig.engine.emit(.stopPassed(index: 1, of: 4), generation: g)
        _ = await rig.run(trip("route_trip", ["start": true]))
        g = await rig.nav.current.generation
        rig.engine.emit(.stopPassed(index: 1, of: 4), generation: g)
        rig.engine.emit(.stopPassed(index: 2, of: 4), generation: g)
        rig.engine.emit(.stopPassed(index: 2, of: 4), generation: g)
        for _ in 0..<2000 where await rig.nav.current.tripStopsPassed.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await rig.nav.current.tripStopsPassed == [1, 2])
        #expect(rig.lines.withLock { $0 }.filter { $0.hasPrefix("trip stop-passed") }
                == ["trip stop-passed index=1 of=4", "trip stop-passed index=2 of=4"])
    }

    @Test("F-15b §3: TripList renumbers after every change and raises its generation; nearest order from the origin")
    func pure() {
        var list = TripList()
        let a = spot("A", lat: 39.1, lng: 117.2), b = spot("B", lat: 39.2, lng: 117.2), c = spot("C", lat: 39.05, lng: 117.2)
        list.replace([("A", a, nil), ("B", b, nil), ("C", c, nil)])
        #expect(list.generation == 1)
        list.reorder(TripOrder.nearest(from: origin, [a, b, c].map(\.coordinate)))
        #expect(list.stops.map(\.place.name) == ["C", "A", "B"] && list.stops.map(\.index) == [1, 2, 3] && list.generation == 2)
        list.reorder([0, 1, 2])
        #expect(list.generation == 2)
        #expect(TripNameMatch.accepts(asked: "海河", found: "海河观光") && !TripNameMatch.accepts(asked: "盘山", found: "饭店"))
    }
}
