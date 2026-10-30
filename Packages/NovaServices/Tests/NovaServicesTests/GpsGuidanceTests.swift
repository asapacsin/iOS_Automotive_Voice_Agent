import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// The phone's fixes, sent by the test.
final class ScriptedFixes: LocationUpdates, @unchecked Sendable {
    private let subscribers = Mutex<[AsyncStream<LocationFix>.Continuation]>([])
    var count: Int { subscribers.withLock { $0.count } }
    func updates() -> AsyncStream<LocationFix> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self)
        subscribers.withLock { $0.append(continuation) }
        return stream
    }
    func send(_ fix: LocationFix) { for c in subscribers.withLock({ $0 }) { c.yield(fix) } }
}

/// First request: a route east along 22.27 N in three steps. Later requests (recalculations): one 100 m north.
final class RouteTransport: HTTPTransport, @unchecked Sendable {
    private let calls = Mutex(0)
    var requests: Int { calls.withLock { $0 } }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let n = calls.withLock { c -> Int in
            c += 1
            return c
        }
        let lat = n == 1 ? "22.27" : "22.2709"
        let json = """
        {"status":"1","route":{"paths":[{"distance":"412","duration":"60","tolls":"0","traffic_lights":"0","steps":[
        {"instruction":"沿A路直行","road":"A路","polyline":"113.500,\(lat);113.501,\(lat);113.502,\(lat)"},
        {"instruction":"右转进入B路","road":"B路","polyline":"113.502,\(lat);113.503,\(lat)"},
        {"instruction":"左转进入C路","road":"C路","polyline":"113.503,\(lat);113.504,\(lat)"}]}]}}
        """
        return (200, Data(json.utf8))
    }
}

@Suite("T-040c F-15a AmapRouteEngine .gps path")
struct GpsGuidanceTests {
    let destination = RouteRequest(destination: GeoCoordinate(latitude: 22.27, longitude: 113.504, datum: .gcj02),
                                   destinationName: "终点")

    func fix(_ lng: Double, north meters: Double = 0, at seconds: Int64) -> LocationFix {
        LocationFix(coordinate: GeoCoordinate(latitude: 22.27 + meters / 111_320, longitude: lng, datum: .gcj02),
                    horizontalAccuracyMeters: 10, timestamp: NovaInstant(milliseconds: seconds * 1000),
                    speedMetersPerSecond: 10)
    }

    struct Rig {
        let engine: AmapRouteEngine
        let fixes: ScriptedFixes
        let transport: RouteTransport
        let drawn: Drawn
        var iterator: AsyncStream<NaviEngineEnvelope>.Iterator

        /// Events until `stop` matches (inclusive).
        mutating func until(_ stop: (NaviEngineEvent) -> Bool) async -> [NaviEngineEnvelope] {
            var out: [NaviEngineEnvelope] = []
            while let envelope = await iterator.next() {
                out.append(envelope)
                if stop(envelope.event) { break }
            }
            return out
        }
    }

    func started(_ generation: Generation) async -> Rig {
        let fixes = ScriptedFixes()
        let transport = RouteTransport()
        let drawn = Drawn()
        let engine = AmapRouteEngine(key: { "k" }, origin: { GeoCoordinate(latitude: 22.27, longitude: 113.5, datum: .gcj02) },
                                     transport: transport, location: fixes, clock: ManualClock(),
                                     onGeometry: { drawn.append($0) })
        var rig = Rig(engine: engine, fixes: fixes, transport: transport, drawn: drawn,
                      iterator: engine.events.makeAsyncIterator())
        await engine.calculateRoutes(destination, generation: generation)
        _ = await rig.until { if case .routesReady = $0 { true } else { false } }
        await engine.start(.gps, generation: generation)
        _ = await rig.until { $0 == .naviStarted }
        while fixes.count == 0 { await Task.yield() }
        return rig
    }

    func texts(_ events: [NaviEngineEnvelope]) -> [String] {
        events.compactMap { if case .guidanceText(let t, _) = $0.event { t } else { nil } }
    }

    @Test("F-15a row 5: guidance texts in order from the fixes, no simulated car, arrival")
    func guidance() async {
        var rig = await started(Generation.initial.next())
        #expect(rig.drawn.last?.car == nil)
        rig.fixes.send(fix(113.5005, at: 1))
        rig.fixes.send(fix(113.5025, at: 2))
        rig.fixes.send(fix(113.5035, at: 3))
        rig.fixes.send(fix(113.5039, at: 4))
        let events = await rig.until { $0 == .arrived }
        #expect(texts(events) == ["右转进入B路", "左转进入C路"])
        let infos = events.compactMap { if case .naviInfo(let i) = $0.event { i } else { nil } }
        #expect(infos.count == 4)
        #expect(infos.first?.nextRoadName == "B路" && infos.first?.currentSpeedKmh == 36)
        #expect(infos.map(\.remainingMeters) == infos.map(\.remainingMeters).sorted(by: >))
        #expect(rig.drawn.last?.car == nil)
    }

    @Test("F-15a row 5: off route → 已偏离路线 and one recalculation per 15 s; the new route replaces the old")
    func reroute() async {
        var rig = await started(Generation.initial.next())
        rig.fixes.send(fix(113.5005, at: 0))
        for t: Int64 in [1, 2, 6] { rig.fixes.send(fix(113.5008, north: 200, at: t)) }
        var events = await rig.until { if case .rerouted = $0 { true } else { false } }
        #expect(texts(events).contains("已偏离路线，正在重新规划。"))
        #expect(events.contains { $0.event == .rerouting })
        guard case .rerouted(let summary)? = events.last?.event else { Issue.record("no reroute"); return }
        #expect(summary != nil)
        #expect(rig.drawn.last?.routes.first?.points.first?.latitude == 22.2709)
        // Off the new route too, but within 15 s of the last recalculation: no second one.
        for t: Int64 in [7, 8, 12] { rig.fixes.send(fix(113.5010, north: 300, at: t)) }
        // Then 16 s after it: the second one.
        for t: Int64 in [13, 14, 22] { rig.fixes.send(fix(113.5012, north: 300, at: t)) }
        events = await rig.until { if case .rerouted = $0 { true } else { false } }
        let reroutings = events.filter { $0.event == .rerouting }.count
        #expect(reroutings == 1)
        #expect(rig.transport.requests == 3)
        // The second one came from the fix at 22 s, after the 6 naviInfo of the fixes at 7…22 s.
        let beforeRerouting = events.prefix { $0.event != .rerouting }
        #expect(beforeRerouting.filter { if case .naviInfo = $0.event { true } else { false } }.count == 6)
    }

    @Test("F-15a §2.5 (T-040h): a route change recalculates from here with new ids while the trip keeps driving")
    func changeFromHere() async {
        let generation = Generation.initial.next()
        var rig = await started(generation)
        let drawnBefore = rig.drawn.last
        guard let routes = await rig.engine.recalculateFromHere(generation: generation), let first = routes.first else {
            Issue.record("no routes"); return
        }
        #expect(first.id.rawValue > 100 && rig.transport.requests == 2)
        // Not drawn and not driven yet: the old trip still answers fixes.
        #expect(rig.drawn.last == drawnBefore)
        rig.fixes.send(fix(113.5005, at: 1))
        _ = await rig.until { if case .naviInfo = $0 { true } else { false } }
        await rig.engine.selectRoute(first.id, generation: generation)
        await rig.engine.start(.gps, generation: generation)
        _ = await rig.until { $0 == .naviStarted }
        #expect(rig.drawn.last?.routes.map(\.summary.id) == [first.id])
        #expect(rig.drawn.last?.routes.first?.points.first?.latitude == 22.2709)
    }

    @Test("F-15a row 5: after a stop, a late fix of the old trip is dropped")
    func oldGeneration() async {
        let g1 = Generation.initial.next()
        var rig = await started(g1)
        let g2 = g1.next()
        await rig.engine.stop(generation: g2)
        _ = await rig.until { $0 == .naviStopped }
        rig.fixes.send(fix(113.5005, at: 1))
        for _ in 0..<50 { await Task.yield() }
        await rig.engine.calculateRoutes(destination, generation: g2.next())
        let next = await rig.until { _ in true }
        guard case .routesReady? = next.first?.event else { Issue.record("\(next)"); return }
    }
}
