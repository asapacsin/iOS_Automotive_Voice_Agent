import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// Records every request URL; answers a route east along 22.27 N from 113.50 to 113.50 + 4 × `step`.
final class RecordingRouteTransport: HTTPTransport, @unchecked Sendable {
    let urls = Mutex<[URL]>([])
    let step: Double
    init(step: Double = 0.001) { self.step = step }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url!) }
        let p = (0...4).map { String(format: "%.3f,22.27", 113.5 + Double($0) * step) }
        let json = """
        {"status":"1","route":{"paths":[{"distance":"4120","duration":"600","tolls":"0","traffic_lights":"0","steps":[
        {"instruction":"沿A路直行","road":"A路","polyline":"\(p[0]);\(p[1]);\(p[2])"},
        {"instruction":"右转进入B路","road":"B路","polyline":"\(p[2]);\(p[3])"},
        {"instruction":"左转进入C路","road":"C路","polyline":"\(p[3]);\(p[4])"}]}]}}
        """
        return (200, Data(json.utf8))
    }
    func query(_ n: Int, _ name: String) -> String? {
        let url = urls.withLock { $0[n] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

@Suite("T-040i F-15b §6 route engine waypoints")
struct TripWaypointTests {
    let start = GeoCoordinate(latitude: 22.27, longitude: 113.5, datum: .gcj02)
    func at(_ lng: Double, lat: Double = 22.27) -> GeoCoordinate { GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02) }

    @Test("F-15b row 9: 3 waypoints go as lng,lat;lng,lat;lng,lat at 6 decimals; with none the URL is as before")
    func row9() async {
        let transport = RecordingRouteTransport()
        let origin = start
        let engine = AmapRouteEngine(key: { "k" }, origin: { origin }, transport: transport)
        let g = Generation.initial.next()
        await engine.calculateRoutes(RouteRequest(destination: at(113.504), destinationName: "终点",
                                                  waypoints: [at(113.5011111), at(113.502, lat: 22.2712345678), at(113.503)]),
                                     generation: g)
        #expect(transport.query(0, "waypoints") == "113.501111,22.270000;113.502000,22.271235;113.503000,22.270000")
        await engine.calculateRoutes(RouteRequest(destination: at(113.504), destinationName: "终点"), generation: g.next())
        let plain = transport.urls.withLock { $0[1].absoluteString }
        #expect(plain == AmapWebClient.host + "/v3/direction/driving?key=k&origin=113.500000,22.270000"
                + "&destination=113.504000,22.270000&strategy=10&extensions=base")
        // §6 item 2: more than 16 is not sent.
        await engine.calculateRoutes(RouteRequest(destination: at(113.504), destinationName: "终点",
                                                  waypoints: Array(repeating: at(113.501), count: 17)), generation: g.next().next())
        #expect(transport.urls.withLock { $0.count } == 2)
    }

    @Test("F-15b row 12: stops 1-2 passed, then off route: the recalculation has stop 3 as its only waypoint; stop-passed for 1 and 2")
    func row12() async {
        let fixes = ScriptedFixes()
        // Stops about 1 km apart, so the 100 m rule (§6 item 3) does not reach the next one.
        let transport = RecordingRouteTransport(step: 0.01)
        let origin = start
        let engine = AmapRouteEngine(key: { "k" }, origin: { origin }, transport: transport, location: fixes, clock: ManualClock())
        var events = engine.events.makeAsyncIterator()
        func until(_ stop: (NaviEngineEvent) -> Bool) async -> [NaviEngineEvent] {
            var out: [NaviEngineEvent] = []
            while let e = await events.next() {
                out.append(e.event)
                if stop(e.event) { break }
            }
            return out
        }
        let g = Generation.initial.next()
        await engine.calculateRoutes(RouteRequest(destination: at(113.54), destinationName: "终点",
                                                  waypoints: [at(113.51), at(113.52), at(113.53)]), generation: g)
        _ = await until { if case .routesReady = $0 { true } else { false } }
        await engine.start(.gps, generation: g)
        _ = await until { $0 == .naviStarted }
        while fixes.count == 0 { await Task.yield() }
        func fix(_ lng: Double, north: Double = 0, at s: Int64) -> LocationFix {
            LocationFix(coordinate: GeoCoordinate(latitude: 22.27 + north / 111_320, longitude: lng, datum: .gcj02),
                        horizontalAccuracyMeters: 10, timestamp: NovaInstant(milliseconds: s * 1000), speedMetersPerSecond: 10)
        }
        fixes.send(fix(113.5105, at: 1))
        fixes.send(fix(113.5205, at: 2))
        for t: Int64 in [3, 4, 8] { fixes.send(fix(113.5206, north: 200, at: t)) }
        let seen = await until { if case .rerouted = $0 { true } else { false } }
        let passed = seen.compactMap { if case .stopPassed(let i, let of) = $0 { "\(i)/\(of)" } else { nil } }
        #expect(passed == ["1/4", "2/4"])
        #expect(transport.urls.withLock { $0.count } == 2)
        #expect(transport.query(1, "waypoints") == "113.530000,22.270000")
        #expect(transport.query(1, "destination") == "113.540000,22.270000")
    }
}

@Suite("T-040j F-15b §12 place photos")
struct TripPhotoParseTests {
    @Test("F-15b row 19: the detail's first photos[].url is kept, an http link as https; no photos is nil")
    func parse() {
        let body: [String: Any] = ["pois": [
            ["id": "B1", "name": "古文化街", "location": "117.19,39.14",
             "photos": [["titile": "门口", "url": "http://store.is.autonavi.com/showpic/a.jpg"], ["title": "", "url": "https://x.cn/b.jpg"]]],
            ["id": "B2", "name": "五大道", "location": "117.20,39.11", "photos": [Any]()],
            ["id": "B3", "name": "瓷房子", "location": "117.20,39.12"],
        ]]
        let places = AmapWebClient.places(body)
        #expect(places.map { $0.photoURL?.absoluteString } == ["https://store.is.autonavi.com/showpic/a.jpg", nil, nil])
    }
}
