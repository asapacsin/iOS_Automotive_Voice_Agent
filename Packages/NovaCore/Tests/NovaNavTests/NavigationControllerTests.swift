import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

/// Answers like the SDK: routes after a calculation, started after a start, stopped after a stop.
final class ScriptedNaviEngine: NaviEngine {
    let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation
    let routes: [RouteSummary]
    let calls = Mutex<[String]>([])
    let failStart: Bool

    init(routes: [RouteSummary], failStart: Bool = false) {
        (events, continuation) = AsyncStream.makeStream()
        self.routes = routes
        self.failStart = failStart
    }

    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        calls.withLock { $0.append("calculate \(request.destinationName)") }
        continuation.yield(NaviEngineEnvelope(generation: generation,
                                              event: routes.isEmpty ? .routeCalculationFailed(code: 2) : .routesReady(routes)))
    }

    func selectRoute(_ id: RouteID, generation: Generation) async {
        calls.withLock { $0.append("select \(id.rawValue)") }
    }

    func start(_ mode: NaviMode, generation: Generation) async {
        calls.withLock { $0.append("start \(mode.rawValue)") }
        if !failStart { continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStarted)) }
    }

    func stop(generation: Generation) async {
        calls.withLock { $0.append("stop") }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStopped))
    }

    /// A late callback of an old request.
    func emit(_ event: NaviEngineEvent, generation: Generation) {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: event))
    }
}

struct FixedSearch: PlaceSearch {
    var places: [Place]
    var error: AmapWebError?

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        if let error { throw error }
        return places
    }

    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await text(keywords, city: nil)
    }

    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

struct NoLocation: LocationProvider {
    func latestFix() async -> LocationFix? { nil }
}

func place(_ name: String, _ meters: Int) -> Place {
    Place(id: name, name: name, address: "\(name)地址",
          coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02), distanceMeters: meters)
}

func route(_ id: Int, meters: Int, seconds: Int, toll: Int = 0, lights: Int = 5) -> RouteSummary {
    RouteSummary(id: RouteID(id), lengthMeters: meters, durationSeconds: seconds, tollYuan: toll,
                 trafficLights: lights, label: nil)
}

func tool(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(id: CallID("c1")!, name: name, arguments: .object(args))
}

@Suite("T-040/T-041 F-15 navigation flow")
struct NavigationControllerTests {
    let stations = [place("珠海站", 3_000), place("珠海北站", 9_000), place("珠海站公交站", 2_500)]
    let routes = [route(1, meters: 12_300, seconds: 1_500, toll: 5), route(2, meters: 10_100, seconds: 1_800),
                  route(3, meters: 15_000, seconds: 1_400, toll: 10, lights: 2)]

    func controller(_ engine: ScriptedNaviEngine, search: FixedSearch? = nil,
                    clock: ManualClock = ManualClock()) async -> NavigationController {
        let nav = NavigationController(search: search ?? FixedSearch(places: stations), engine: engine,
                                       location: NoLocation(), clock: clock)
        await nav.start()
        return nav
    }

    @Test("W8 / F-15a row 10 (T-040h): 导航去珠海站 → 第一个 starts on the recommended route; 换最快的 → 结束导航")
    func happyPath() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = await controller(engine)

        let listed = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(listed.ok && listed.data["status"] == "candidates_listed" && listed.data["count"] == .int(3))
        #expect(await nav.current.phase == .awaitingDestinationSelection)

        // The place is the request: guidance starts at once on the recommended (first) route, no route list.
        let started = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(started.ok && started.data["status"] == "navigation_started")
        #expect(await nav.current.phase == .navigating)
        #expect(await nav.current.destination?.name == "珠海站")
        #expect(await nav.current.selectedRoute == RouteID(1))
        guard case .array(let others)? = started.data["alternatives"] else { Issue.record("no alternatives"); return }
        #expect(others.count == 2)
        // Route 3 is faster: one short offer, never all routes read.
        #expect(started.data["next"]?.stringValue?.contains("还有一条更快的，要换吗？") == true)

        // F-15a row 12: 换最快的 replaces the route of the same trip.
        let again = await nav.execute(tool("choose_navigation_option", ["preference": "recommended"]))
        #expect(again.ok && again.data["status"] == "route_unchanged")
        let faster = await nav.execute(tool("choose_navigation_option", ["preference": "fastest"]))
        #expect(faster.ok && faster.data["status"] == "route_changed")
        #expect(faster.data["next"]?.stringValue?.contains("已换成最快的路线") == true)
        let changed = await nav.current
        #expect(changed.phase == .navigating && changed.selectedRoute == RouteID(3))
        #expect(engine.calls.withLock { $0.filter { $0.hasPrefix("calculate") }.count } == 1)

        let stopped = await nav.execute(tool("exit_navigation_mode"))
        #expect(stopped.data["status"] == "navigation_stopped")
        #expect(stopped.data["next"] == "说一句：已结束导航。")  // F-05a §6 (T-016e): implicit confirmation
        let snapshot = await nav.current
        #expect(snapshot.phase == .idle && snapshot.routes.isEmpty && snapshot.destination == nil)
    }

    @Test("F-15: route preferences pick the matching route")
    func preferences() async {
        for (preference, expected) in [("fastest", 3), ("shortest", 2), ("no_toll", 2), ("fewest_lights", 3)] {
            let engine = ScriptedNaviEngine(routes: routes)
            let nav = await controller(engine, search: FixedSearch(places: [place("珠海站", 3_000)]))
            let one = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
            #expect(one.data["status"] == "navigation_started", "a single result starts on the recommended route")
            _ = await nav.execute(tool("choose_navigation_option", ["preference": .string(preference)]))
            #expect(await nav.current.selectedRoute == RouteID(expected), "\(preference)")
        }
    }

    @Test("F-15: 算了 on a list cancels the selection and clears the route")
    func cancelList() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = await controller(engine)
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        let cancelled = await nav.execute(tool("exit_navigation_mode"))
        #expect(cancelled.data["status"] == "navigation_selection_cancelled")
        #expect(await nav.current.routes.isEmpty)
        let none = await nav.execute(tool("exit_navigation_mode"))
        #expect(none.data["status"] == "no_navigation_active")
    }

    @Test("F-15: index out of range, nearest, name match and stale list")
    func choices() async {
        let clock = ManualClock()
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = await controller(engine, clock: clock)
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(await nav.execute(tool("choose_navigation_option", ["index": .int(5)])).code == .outOfRange)
        #expect(await nav.execute(tool("choose_navigation_option", ["name": "珠海"])).code == .ambiguous)
        #expect(await nav.execute(tool("choose_navigation_option", ["preference": "fastest"])).code
            == .preferenceNotForDestinations)
        clock.advance(by: .seconds(121))
        #expect(await nav.execute(tool("choose_navigation_option", ["index": .int(1)])).code == .optionsStale)
        #expect(await nav.current.phase == .idle)

        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["preference": "nearest"]))
        #expect(await nav.current.destination?.name == "珠海站公交站")
    }

    @Test("F-15: no candidates, missing key, failed routes and failed start are honest failures")
    func failures() async {
        let none = await controller(ScriptedNaviEngine(routes: routes), search: FixedSearch(places: []))
        #expect(await none.execute(tool("navigate_to", ["destination": "火星"])).code == .noCandidates)

        let noKey = await controller(ScriptedNaviEngine(routes: routes),
                                     search: FixedSearch(places: [], error: .keyMissing))
        #expect(await noKey.execute(tool("navigate_to", ["destination": "珠海站"])).code == .amapWebKeyMissing)

        let noRoutes = await controller(ScriptedNaviEngine(routes: []))
        _ = await noRoutes.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(await noRoutes.execute(tool("choose_navigation_option", ["index": .int(1)])).code
            == .routeCalculationFailed)

        let clock = ManualClock()
        let stuckEngine = ScriptedNaviEngine(routes: routes, failStart: true)
        let stuck = await controller(stuckEngine, clock: clock)
        _ = await stuck.execute(tool("navigate_to", ["destination": "珠海站"]))
        // T-040h: picking the place starts guidance on the recommended route.
        async let start = stuck.execute(tool("choose_navigation_option", ["index": .int(1)]))
        // Wait until the start itself waits (the routes wait comes and goes before it).
        while !stuckEngine.calls.withLock({ $0.contains { $0.hasPrefix("start") } }) || clock.pendingSleepers == 0 {
            await Task.yield()
        }
        // A second pick in the same turn while the first start waits: refused, no second start.
        let second = await stuck.execute(tool("choose_navigation_option", ["preference": "recommended"]))
        #expect(!second.ok && second.code == .optionsNotReady)
        clock.advance(by: .seconds(9))
        #expect(await start.code == .startFailed)
        #expect(stuckEngine.calls.withLock { $0.filter { $0.hasPrefix("start") }.count } == 1)
        #expect(stuckEngine.calls.withLock { $0.last } == "stop")
        let failed = await stuck.current
        #expect(failed.phase == .idle && failed.routes.isEmpty)
    }

    @Test("F-15: a stale engine callback after cancel changes nothing")
    func staleCallback() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = await controller(engine)
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        let old = await nav.current.generation
        _ = await nav.execute(tool("exit_navigation_mode"))
        engine.emit(.naviStarted, generation: old)
        engine.emit(.routesReady(routes), generation: old)
        for _ in 0..<20 { await Task.yield() }
        let snapshot = await nav.current
        #expect(snapshot.phase == .idle && snapshot.routes.isEmpty)
    }

    @Test("F-18 route_traffic: remaining distance and time while navigating, NOT_NAVIGATING otherwise")
    func routeStatus() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = await controller(engine)
        #expect(await nav.routeStatus().code == .notNavigating)
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        let generation = await nav.current.generation
        engine.emit(.naviInfo(NaviInfo(iconType: 2, stepDistanceMeters: 300, nextRoadName: "迎宾南路",
                                       remainingMeters: 8_400, remainingSeconds: 960, currentSpeedKmh: 40)),
                    generation: generation)
        while await nav.current.info == nil { await Task.yield() }
        let status = await nav.routeStatus()
        #expect(status.ok && status.data["remaining_km"] == .double(8.4) && status.data["remaining_min"] == .int(16))
        #expect(status.data["next_road"] == "迎宾南路")
    }
}

/// Holds the first route calculation until `release()`, then answers it late, like a slow network.
final class SlowFirstEngine: NaviEngine {
    let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation
    let routes: [RouteSummary]
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let first = Mutex(true)

    init(routes: [RouteSummary]) {
        (events, continuation) = AsyncStream.makeStream()
        self.routes = routes
    }

    var isHolding: Bool { held.withLock { $0 != nil } }

    func release() { held.withLock { $0?.resume(); $0 = nil } }

    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        if first.withLock({ f in defer { f = false }; return f }) {
            await withCheckedContinuation { c in held.withLock { $0 = c } }
            return  // the late fetch is dropped by the engine (AmapRouteEngine token)
        }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .routesReady(routes)))
    }

    func selectRoute(_ id: RouteID, generation: Generation) async {}
    func start(_ mode: NaviMode, generation: Generation) async {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStarted))
    }
    func stop(generation: Generation) async {}
}

@Suite("F-15 §9 concurrent requests")
struct NavigationRaceTests {
    @Test("a new destination while the old routes calculate: the new one gets its routes")
    func newDestinationDuringCalculation() async {
        let engine = SlowFirstEngine(routes: [route(1, meters: 5_000, seconds: 600)])
        let search = FixedSearch(places: [place("珠海站", 3_000), place("珠海北站", 9_000)])
        let nav = NavigationController(search: search, engine: engine,
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        async let old = nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        while !engine.isHolding { await Task.yield() }
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        let new = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(new.ok && new.data["status"] == "navigation_started")
        engine.release()
        #expect(await old.code == .optionsStale)
        #expect(await nav.current.phase == .navigating)
    }
}

/// Starts once; every later start never reports started (a route change that fails).
final class FirstStartOnlyEngine: NaviEngine {
    let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation
    let routes: [RouteSummary]
    let starts = Mutex(0)

    init(routes: [RouteSummary]) {
        (events, continuation) = AsyncStream.makeStream()
        self.routes = routes
    }

    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .routesReady(routes)))
    }
    func selectRoute(_ id: RouteID, generation: Generation) async {}
    func start(_ mode: NaviMode, generation: Generation) async {
        let n = starts.withLock { n -> Int in n += 1; return n }
        if n == 1 { continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStarted)) }
    }
    func stop(generation: Generation) async {}
}

@Suite("T-040h F-15a route change during the trip")
struct RouteChangeTests {
    @Test("F-15a row 12: a route change that fails keeps the trip on its current route")
    func failedChangeKeepsTrip() async {
        let clock = ManualClock()
        let engine = FirstStartOnlyEngine(routes: [route(1, meters: 12_000, seconds: 1_500),
                                                   route(2, meters: 13_000, seconds: 1_200)])
        let nav = NavigationController(search: FixedSearch(places: [place("珠海站", 3_000)]), engine: engine,
                                       location: NoLocation(), clock: clock)
        await nav.start()
        let started = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(started.data["offer_preference"] == "fastest")
        async let change = nav.execute(tool("choose_navigation_option", ["preference": "fastest"]))
        while engine.starts.withLock({ $0 }) < 2 || clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .seconds(30))
        let result = await change
        #expect(!result.ok && result.code == .startFailed)
        let snapshot = await nav.current
        #expect(snapshot.phase == .navigating && snapshot.selectedRoute == RouteID(1))
    }
}
