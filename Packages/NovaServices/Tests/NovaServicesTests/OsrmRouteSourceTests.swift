import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// OSRM route service stand-in: answers every request with `body` (or throws), recording the URLs. 高德 requests
/// (`restapi.amap.com`) are counted apart.
final class FakeOsrm: HTTPTransport, @unchecked Sendable {
    let urls = Mutex<[String]>([])
    let body: @Sendable (Int) -> String
    let error: URLError?
    init(error: URLError? = nil, body: @escaping @Sendable (Int) -> String = { _ in osrmTwoRoutes() }) {
        self.error = error
        self.body = body
    }
    var osrm: Int { urls.withLock { $0.filter { $0.contains("router.project-osrm.org") }.count } }
    var amap: Int { urls.withLock { $0.filter { $0.contains("/v3/direction/driving") }.count } }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let n = urls.withLock { u -> Int in
            u.append(request.url?.absoluteString ?? "")
            return u.count
        }
        if let error { throw error }
        if request.url?.host?.contains("amap") == true {
            return (200, Data(#"{"status":"1","route":{"paths":[{"distance":"1000","duration":"60","steps":[{"instruction":"直行","road":"A","polyline":"113.5,22.27;113.51,22.27"}]}]}}"#.utf8))
        }
        return (200, Data(body(n).utf8))
    }
}

/// One OSRM step as JSON.
func osrmStep(_ type: String, _ modifier: String? = nil, name: String = "", exit: Int? = nil,
              coords: [[Double]]) -> String {
    var maneuver = #""type":"\#(type)""#
    if let modifier { maneuver += #","modifier":"\#(modifier)""# }
    if let exit { maneuver += #","exit":\#(exit)"# }
    let line = coords.map { "[\($0[0]),\($0[1])]" }.joined(separator: ",")
    return #"{"name":"\#(name)","mode":"driving","maneuver":{\#(maneuver)},"geometry":{"type":"LineString","coordinates":[\#(line)]}}"#
}

/// Two routes; the first has 26 steps east along 35.77 N (depart, 24 right turns onto 空港西通り, arrive).
func osrmTwoRoutes(lat: Double = 35.77) -> String {
    var steps = [osrmStep("depart", "straight", name: "成田", coords: [[140.380, lat], [140.381, lat]])]
    for i in 1...24 {
        let a = 140.380 + Double(i) * 0.001
        steps.append(osrmStep("turn", "right", name: "空港西通り", coords: [[a, lat], [a + 0.001, lat]]))
    }
    steps.append(osrmStep("arrive", coords: [[140.405, lat], [140.405, lat]]))
    let first = #"{"distance":67700.4,"duration":3720.2,"legs":[{"steps":[\#(steps.joined(separator: ","))]}]}"#
    let second = #"{"distance":70000,"duration":4000,"legs":[{"steps":[\#(osrmStep("depart", name: "x", coords: [[140.38, lat], [140.405, lat]])),\#(osrmStep("arrive", coords: [[140.405, lat], [140.405, lat]]))]}]}"#
    return #"{"code":"Ok","routes":[\#(first),\#(second)]}"#
}

@Suite("T-040s F-15b §47 guidance abroad on OSRM routes")
struct OsrmRouteSourceTests {
    let narita = GeoCoordinate(latitude: 35.77, longitude: 140.38, datum: .gcj02)
    let abroad = RouteRequest(destination: GeoCoordinate(latitude: 35.77, longitude: 140.405, datum: .gcj02),
                              destinationName: "浅草寺", abroad: true)

    func engine(_ transport: FakeOsrm, lines: Lines, drawn: Drawn = Drawn(), location: (any LocationUpdates)? = nil)
        -> AmapRouteEngine {
        let from = narita
        return AmapRouteEngine(key: { "k" }, origin: { from }, transport: transport, location: location,
                               clock: ManualClock(), abroadSource: OsrmRouteSource(transport: transport),
                               onLine: { lines.add($0) }, onGeometry: { drawn.append($0) })
    }

    @Test("F-15b row 111: abroad: one OSRM request (the §47 item 2 URL), no 高德; 2 routes, 26 steps; route plan vendor=osrm routes=2")
    func row111() async throws {
        let transport = FakeOsrm()
        let lines = Lines()
        let drawn = Drawn()
        let engine = engine(transport, lines: lines, drawn: drawn)
        var events = engine.events.makeAsyncIterator()
        await engine.calculateRoutes(abroad, generation: Generation.initial.next())
        guard case .routesReady(let routes)? = await events.next()?.event else { Issue.record("no routes"); return }
        #expect(routes.count == 2)
        #expect(routes[0].lengthMeters == 67_700 && routes[0].durationSeconds == 3_720)
        #expect(transport.osrm == 1 && transport.amap == 0)
        let url = try #require(transport.urls.withLock { $0.first })
        #expect(url == "https://router.project-osrm.org/route/v1/driving/140.380000,35.770000;140.405000,35.770000?steps=true&overview=full&geometries=geojson&alternatives=true")
        #expect(drawn.last?.routes.first?.steps.count == 26)
        #expect(drawn.last?.routes.first?.steps[1].road == "空港西通り")
        #expect(drawn.last?.attribution == "路线 © OSRM · 地图数据 © OpenStreetMap")
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.hasPrefix("route plan vendor=osrm routes=2 ms=") == true)
    }

    @Test("F-15b row 114a: a home request goes to 高德 as today, no OSRM request, no attribution; route plan vendor=amap")
    func row114a() async {
        let transport = FakeOsrm()
        let lines = Lines()
        let drawn = Drawn()
        let engine = engine(transport, lines: lines, drawn: drawn)
        var events = engine.events.makeAsyncIterator()
        let home = RouteRequest(destination: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02), destinationName: "珠海站")
        await engine.calculateRoutes(home, generation: Generation.initial.next())
        guard case .routesReady? = await events.next()?.event else { Issue.record("no routes"); return }
        #expect(transport.osrm == 0 && transport.amap == 1)
        #expect(drawn.last?.attribution == nil)
        #expect(lines.all.first?.hasPrefix("route plan vendor=amap routes=1 ms=") == true)
    }

    @Test("F-15b row 114: OSRM times out: route calculation failed (→ ROUTE_CALCULATION_FAILED, then §38 item 2)")
    func row114() async {
        let transport = FakeOsrm(error: URLError(.timedOut))
        let lines = Lines()
        let engine = engine(transport, lines: lines)
        var events = engine.events.makeAsyncIterator()
        await engine.calculateRoutes(abroad, generation: Generation.initial.next())
        guard case .routeCalculationFailed? = await events.next()?.event else { Issue.record("not failed"); return }
        #expect(transport.osrm == 1 && transport.amap == 0)
        #expect(lines.all.first?.hasPrefix("route plan vendor=osrm routes=0 ms=") == true)
        await #expect(throws: AmapWebError.timeout) {
            _ = try await OsrmRouteSource(transport: transport).routes(from: narita, to: abroad.destination, destinationName: "x")
        }
    }

    @Test("F-15b §47 item 6: an OSRM answer that is not Ok (NoRoute) fails the calculation")
    func noRoute() async {
        let transport = FakeOsrm(body: { _ in #"{"code":"NoRoute","message":"Impossible route between points"}"# })
        let engine = engine(transport, lines: Lines())
        var events = engine.events.makeAsyncIterator()
        await engine.calculateRoutes(abroad, generation: Generation.initial.next())
        guard case .routeCalculationFailed? = await events.next()?.event else { Issue.record("not failed"); return }
    }

    @Test("F-15b row 113: off route during an OSRM route: one OSRM recalculation, guidance goes on; route recalc vendor=osrm")
    func row113() async {
        let fixes = ScriptedFixes()
        // Recalculations answer a route 100 m north.
        let transport = FakeOsrm(body: { n in n == 1 ? osrmTwoRoutes() : osrmTwoRoutes(lat: 35.7709) })
        let lines = Lines()
        let drawn = Drawn()
        let engine = engine(transport, lines: lines, drawn: drawn, location: fixes)
        var events = engine.events.makeAsyncIterator()
        let g = Generation.initial.next()
        await engine.calculateRoutes(abroad, generation: g)
        _ = await events.next()
        await engine.start(.gps, generation: g)
        while fixes.count == 0 { await Task.yield() }
        func fix(_ lng: Double, north: Double = 0, at s: Int64) -> LocationFix {
            LocationFix(coordinate: GeoCoordinate(latitude: 35.77 + north / 111_320, longitude: lng, datum: .wgs84),
                        horizontalAccuracyMeters: 10, timestamp: NovaInstant(milliseconds: s * 1000), speedMetersPerSecond: 10)
        }
        fixes.send(fix(140.3805, at: 0))
        for t: Int64 in [1, 2, 6] { fixes.send(fix(140.3808, north: 200, at: t)) }
        var rerouted: RouteSummary??
        while let envelope = await events.next() {
            if case .rerouted(let summary) = envelope.event { rerouted = summary; break }
        }
        #expect(rerouted != nil && rerouted! != nil)
        #expect(transport.osrm == 2 && transport.amap == 0)
        #expect(lines.all.contains { $0.hasPrefix("route recalc vendor=osrm ms=") })
        #expect(drawn.last?.routes.first?.points.first?.latitude == 35.7709)
        #expect(drawn.last?.attribution == "路线 © OSRM · 地图数据 © OpenStreetMap")
    }

    // MARK: §47 item 4 the copied zh-Hans templates

    func step(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("F-15b row 112: turn right onto 空港西通り, roundabout exit 2, arrive: the copied zh-Hans templates")
    func row112() {
        let turn = step(osrmStep("turn", "right", name: "空港西通り", coords: []))
        let roundabout = step(osrmStep("roundabout", "right", exit: 2, coords: []))
        let arrive = step(osrmStep("arrive", coords: []))
        // zh-Hans.json v5.turn.right.name, v5.roundabout.default.exit.default with ordinalize 2, v5.arrive.default.*.
        #expect(OsrmInstructions.compile(turn) == "右转，驶入空港西通り")
        #expect(OsrmInstructions.compile(roundabout) == "进入环岛后从第二出口驶出")
        #expect(OsrmInstructions.compile(arrive, waypointName: "浅草寺") == "您已到达浅草寺")
        #expect(OsrmInstructions.compile(arrive) == "您已经到达您的个目的地")
        // Each sentence is the file's own text, filled in.
        #expect(OsrmZhHans.json.contains(#""name": "右转，驶入{way_name}""#))
        #expect(OsrmZhHans.json.contains(#""default": "进入环岛后从{exit_number}出口驶出""#))
        #expect(OsrmZhHans.json.contains(#""named": "您已到达{waypoint_name}""#))
    }

    @Test("F-15b §47 item 4: codes the templates do not cover use the library's fallback")
    func fallbacks() {
        // An unknown type is a `turn`; an unknown modifier is the type's default with the modifier word.
        #expect(OsrmInstructions.compile(step(osrmStep("weird", "left", coords: []))) == "左转")
        #expect(OsrmInstructions.compile(step(osrmStep("turn", "slight left", name: "A", coords: []))) == "稍向左转弯，驶入A")
        // name and ref: 「name（ref）」; ref alone when the name is empty.
        #expect(OsrmInstructions.wayName(["name": "首都高速", "ref": "C1"]) == "首都高速（C1）")
        #expect(OsrmInstructions.wayName(["name": "", "ref": "E51;E52"]) == "E51")
        // A ferry uses the mode template.
        #expect(OsrmInstructions.compile(["mode": "ferry", "name": "",
                                          "maneuver": ["type": "turn", "modifier": "straight"]]) == "乘坐轮渡")
    }

    @Test("F-15b §47 item 2: requests through the shared throttle start at least 1 s apart")
    func throttle() async {
        let clock = ManualClock()
        let throttle = OsrmThrottle(clock: clock)
        await throttle.admit()
        let second = Task { await throttle.admit(); return clock.now }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .seconds(1))
        let at = await second.value
        #expect(at.milliseconds >= 1000)
    }
}
