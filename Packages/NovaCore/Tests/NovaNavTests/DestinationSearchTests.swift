import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

/// Records every query and center; answers from a script keyed by keywords.
final class RecordingSearch: PlaceSearch, @unchecked Sendable {
    let script: [String: [Place]]
    let corridor: [Place]
    let details: [String: Place]
    let log = Mutex<[String]>([])
    let centers = Mutex<[GeoCoordinate]>([])
    let polygons = Mutex<[[GeoCoordinate]]>([])

    init(_ script: [String: [Place]] = [:], corridor: [Place] = [], details: [String: Place] = [:]) {
        self.script = script
        self.corridor = corridor
        self.details = details
    }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        log.withLock { $0.append("text \(keywords)") }
        return script[keywords] ?? []
    }

    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        log.withLock { $0.append("around \(keywords) \(sort.rawValue)") }
        centers.withLock { $0.append(center) }
        return script[keywords] ?? []
    }

    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] {
        log.withLock { $0.append("polygon \(keywords)") }
        polygons.withLock { $0.append(vertices) }
        return corridor
    }

    func detail(id: String) async throws -> Place? { details[id] }
}

/// The scripted engine, except that the next `stop` can be held until `release()`.
final class HeldStopEngine: NaviEngine, @unchecked Sendable {
    let inner: ScriptedNaviEngine
    private let hold = Mutex(false)
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    init(_ inner: ScriptedNaviEngine) { self.inner = inner }

    var events: AsyncStream<NaviEngineEnvelope> { inner.events }
    var isHolding: Bool { held.withLock { $0 != nil } }
    func holdNextStop() { hold.withLock { $0 = true } }
    func release() { held.withLock { c in defer { c = nil }; return c }?.resume() }

    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        await inner.calculateRoutes(request, generation: generation)
    }
    func selectRoute(_ id: RouteID, generation: Generation) async { await inner.selectRoute(id, generation: generation) }
    func start(_ mode: NaviMode, generation: Generation) async { await inner.start(mode, generation: generation) }
    func stop(generation: Generation) async {
        if hold.withLock({ h in defer { h = false }; return h }) {
            await withCheckedContinuation { c in held.withLock { $0 = c } }
        }
        await inner.stop(generation: generation)
    }
}

struct FixLocation: LocationProvider {
    let fix: LocationFix
    func latestFix() async -> LocationFix? { fix }
}

private let wgsFix = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .wgs84)

/// A straight 12 km route heading east, GCJ-02, one point every ~100 m.
private let line: [GeoCoordinate] = (0...120).map {
    GeoCoordinate(latitude: 22.27, longitude: 113.50 + Double($0) * 0.00097, datum: .gcj02)
}

@Suite("T-042 F-16 destination queries, location and corridor")
struct DestinationSearchTests {
    @Test("F-16 §10 row 1: keyword stripping and the verbatim retry, table-driven")
    func stripping() {
        let table: [(String, String, PlaceSort)] = [
            ("导航去珠海站", "珠海站", .weight), ("带我去附近的加油站", "加油站", .distance),
            ("附近的充电站", "充电站", .distance), ("珠海站", "珠海站", .weight), ("加油站", "加油站", .distance),
            ("我想去横琴口岸吧", "横琴口岸", .weight), ("导航到 拱北口岸。", "拱北口岸", .weight),
            ("导航去", "导航去", .weight),
        ]
        for (text, stripped, sort) in table {
            let q = DestinationQuery(text)
            #expect(q.stripped == stripped && q.sort == sort, "\(text)")
        }
        #expect(DestinationQuery("导航去珠海站").attempts == ["珠海站", "导航去珠海站"])
        #expect(DestinationQuery("珠海站").attempts == ["珠海站"])
    }

    @Test("F-16 the verbatim text is tried once when the stripped query finds nothing")
    func verbatimRetry() async {
        let search = RecordingSearch(["去日月贝": [place("日月贝", 2_000)]])
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 1, seconds: 60)]),
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        let result = await nav.execute(tool("navigate_to", ["destination": "去日月贝"]))
        #expect(result.ok)
        #expect(search.log.withLock { $0 } == ["text 日月贝", "text 去日月贝"])
        let none = await nav.execute(tool("navigate_to", ["destination": "带我去不存在的地方"]))
        #expect(none.code == .noCandidates)
    }

    @Test("F-16 §10 row 4: the fix is converted to GCJ-02 before the Amap call; nearby sorts by distance")
    func converted() async {
        let search = RecordingSearch(["加油站": [place("中石化", 800), place("中石油", 1_200)]])
        let fix = LocationFix(coordinate: wgsFix, horizontalAccuracyMeters: 30, timestamp: .zero)
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: []),
                                       location: FixLocation(fix: fix), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "附近的加油站"]))
        let center = search.centers.withLock { $0 }.first
        #expect(center?.datum == .gcj02 && center != wgsFix)
        #expect(center == CoordinateConverter.gcj02(wgsFix))
        #expect(search.log.withLock { $0 }.first == "around 加油站 distance")
    }

    @Test("F-16 §3: a stale or coarse fix is not used; text search without a city instead")
    func freshness() async {
        let tuning = AmapWebTuning()
        let now = NovaInstant(milliseconds: 20 * 60_000)
        func fix(age: NovaDuration, accuracy: Double) -> LocationFix {
            LocationFix(coordinate: wgsFix, horizontalAccuracyMeters: accuracy, timestamp: now - age)
        }
        #expect(LocationQuality.of(fix(age: .seconds(30), accuracy: 50), at: now, tuning: tuning) == .fresh)
        #expect(LocationQuality.of(fix(age: .seconds(31), accuracy: 50), at: now, tuning: tuning) == .provisional)
        #expect(LocationQuality.of(fix(age: .minutes(10), accuracy: 50), at: now, tuning: tuning) == .provisional)
        #expect(LocationQuality.of(fix(age: .minutes(11), accuracy: 50), at: now, tuning: tuning) == nil)
        #expect(LocationQuality.of(fix(age: .zero, accuracy: 2_001), at: now, tuning: tuning) == nil)

        let search = RecordingSearch(["珠海站": [place("珠海站", 3_000)]])
        let clock = ManualClock(start: now)
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: []),
                                       location: FixLocation(fix: fix(age: .minutes(11), accuracy: 10)), clock: clock)
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(search.log.withLock { $0 } == ["text 珠海站"])
    }

    @Test("F-16 corridor: closed polygon of at most 64 vertices, 500 m around the route")
    func corridor() {
        let polygon = AlongRouteCorridor.polygon(line)
        #expect(polygon.count >= 4 && polygon.count <= 64)
        #expect(polygon.first == polygon.last)
        #expect(polygon.allSatisfy { $0.datum == .gcj02 })
        let projection = AlongRouteCorridor.Projection(origin: line[0])
        let ring = polygon.map(projection.forward)
        // Every vertex lies about 500 m off the line (straight route: exactly).
        for p in ring { #expect(abs(abs(p.y) - 500) < 1) }

        // A winding route with many points still fits the vertex limit.
        let winding = (0...2_000).map { i -> GeoCoordinate in
            let t = Double(i) / 50
            return GeoCoordinate(latitude: 22.27 + sin(t) * 0.01, longitude: 113.5 + Double(i) * 0.0002, datum: .gcj02)
        }
        let big = AlongRouteCorridor.polygon(winding)
        #expect(big.count <= 64 && big.count >= 4)
        #expect(AlongRouteCorridor.polygon([line[0]]).isEmpty)
    }
}

@Suite("T-046 F-18 along_route and place_details")
struct AlongRouteTests {
    func navigating(_ search: RecordingSearch) async -> NavigationController {
        let engine = ScriptedNaviEngine(routes: [RouteSummary(id: RouteID(1), lengthMeters: 12_000, durationSeconds: 900,
                                                              tollYuan: 0, trafficLights: 3, label: nil, polyline: line)])
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        return nav
    }

    @Test("F-18 along_route when not navigating → NOT_NAVIGATING")
    func notNavigating() async {
        let nav = NavigationController(search: RecordingSearch(), engine: ScriptedNaviEngine(routes: []),
                                       location: NoLocation(), clock: ManualClock())
        let result = await nav.alongRoute(category: "fuel")
        #expect(result.code == .notNavigating)
    }

    @Test("F-18 along_route lists corridor places over the kept guidance; 算了 closes only the list")
    func keptGuidance() async {
        let search = RecordingSearch(["珠海站": [place("珠海站", 3_000)]],
                                     corridor: [place("中石化A", 900), place("中石化B", 4_000)])
        let nav = await navigating(search)
        #expect(await nav.current.navigating)
        let listed = await nav.alongRoute(category: "fuel")
        #expect(listed.ok && listed.data["status"] == "along_route_listed" && listed.data["count"] == .int(2))
        #expect(search.log.withLock { $0 }.last == "polygon 加油站")
        var snapshot = await nav.current
        #expect(snapshot.navigating && snapshot.listOpen && snapshot.places.count == 2)
        let closed = await nav.execute(tool("exit_navigation_mode"))
        #expect(closed.data["status"] == "list_closed_guidance_kept")
        snapshot = await nav.current
        #expect(snapshot.navigating && !snapshot.listOpen && snapshot.places.isEmpty)
    }

    @Test("F-18 along_route with nothing found keeps the guidance and says so")
    func noneFound() async {
        let nav = await navigating(RecordingSearch(["珠海站": [place("珠海站", 3_000)]]))
        let result = await nav.alongRoute(category: "toilet")
        #expect(result.code == .noResults)
        #expect(await nav.current.navigating)
        #expect(await nav.alongRoute(category: "news").code == .invalidArgument)
    }

    @Test("F-18 an explicit pick from the along-route list replaces the route (old guidance stops first)")
    func pickReplaces() async {
        let search = RecordingSearch(["珠海站": [place("珠海站", 3_000)]], corridor: [place("中石化A", 900), place("B", 2_000)])
        let nav = await navigating(search)
        _ = await nav.alongRoute(category: "fuel")
        let picked = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(picked.ok && picked.data["destination"] == "中石化A")
        let snapshot = await nav.current
        #expect(snapshot.phase == .awaitingRouteSelection && !snapshot.alongRouteList)
    }

    @Test("F-18 an exit while the along-route pick stops the old guidance wins; the pick is stale")
    func exitDuringPick() async {
        let search = RecordingSearch(["珠海站": [place("珠海站", 3_000)]], corridor: [place("中石化A", 900)])
        let engine = HeldStopEngine(ScriptedNaviEngine(routes: [RouteSummary(
            id: RouteID(1), lengthMeters: 12_000, durationSeconds: 900, tollYuan: 0, trafficLights: 3, label: nil,
            polyline: line)]))
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        _ = await nav.alongRoute(category: "fuel")
        engine.holdNextStop()
        async let picked = nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        while !engine.isHolding { await Task.yield() }
        #expect(await nav.current.alongRouteList == false)
        let exited = await nav.execute(tool("exit_navigation_mode"))
        #expect(exited.data["status"] == "navigation_stopped")
        engine.release()
        #expect(await picked.code == .optionsStale)
        let snapshot = await nav.current
        #expect(snapshot.phase == .idle && snapshot.destination == nil)
    }

    @Test("F-18 place_details answers only from Amap's detail; missing hours are said to be unknown")
    func details() async {
        let detailed = Place(id: "珠海站", name: "珠海站", address: "香洲区", coordinate: line[0], distanceMeters: nil,
                             openingHours: "06:00-23:00", phone: "0756-1234567")
        let search = RecordingSearch(["珠海站": [place("珠海站", 3_000)]], details: ["珠海站": detailed])
        let nav = await navigating(search)
        let result = await nav.placeDetails(target: "destination")
        #expect(result.ok && result.data["opening_hours"] == "06:00-23:00")
        #expect(await nav.placeDetails(target: .int(2)).code == .noOptionsOnScreen)
        let idle = NavigationController(search: search, engine: ScriptedNaviEngine(routes: []), location: NoLocation(),
                                        clock: ManualClock())
        #expect(await idle.placeDetails(target: "destination").code == .noDestination)
        let unknown = NavigationController(search: RecordingSearch(["X": [place("X", 1), place("Y", 2)]]),
                                           engine: ScriptedNaviEngine(routes: []), location: NoLocation(), clock: ManualClock())
        _ = await unknown.execute(tool("navigate_to", ["destination": "X"]))
        #expect(await unknown.placeDetails(target: .int(1)).code == .noResults)
    }
}
