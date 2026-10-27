import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// Answers driving directions; the first request is held until `release()` (a slow network).
final class HeldTransport: HTTPTransport, @unchecked Sendable {
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let count = Mutex(0)

    var isHolding: Bool { held.withLock { $0 != nil } }
    func release() { held.withLock { $0?.resume(); $0 = nil } }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let n = count.withLock { c -> Int in
            c += 1
            return c
        }
        if n == 1 { await withCheckedContinuation { c in held.withLock { $0 = c } } }
        let meters = n == 1 ? 1_000 : 2_000
        let json = """
        {"status":"1","route":{"paths":[{"distance":"\(meters)","duration":"300","tolls":"0","traffic_lights":"2",
        "steps":[{"instruction":"直行","road":"路","polyline":"113.57,22.27;113.58,22.28"}]}]}}
        """
        return (200, Data(json.utf8))
    }
}

@Suite("T-043 Amap Web route engine: stale fetches dropped")
struct AmapRouteEngineTests {
    let origin = GeoCoordinate(latitude: 22.270715, longitude: 113.576726, datum: .gcj02)
    let destination = RouteRequest(destination: GeoCoordinate(latitude: 22.21, longitude: 113.55, datum: .gcj02),
                                   destinationName: "珠海站")

    func engine(_ transport: HeldTransport, drawn: Mutex<[RouteGeometry]>) -> AmapRouteEngine {
        let origin = origin
        return AmapRouteEngine(key: { "k" }, origin: { origin }, transport: transport,
                               onGeometry: { g in drawn.withLock { $0.append(g) } })
    }

    @Test("F-15 §10: after 算了 a late route fetch draws nothing and sends no event")
    func stopThenLateFetch() async {
        let transport = HeldTransport()
        let drawn = Mutex<[RouteGeometry]>([])
        let engine = engine(transport, drawn: drawn)
        let g1 = Generation.initial.next()
        async let calc: Void = engine.calculateRoutes(destination, generation: g1)
        while !transport.isHolding { await Task.yield() }
        await engine.stop(generation: g1)
        transport.release()
        await calc
        #expect(drawn.withLock { $0.last?.routes.isEmpty } == true)
        var events: [NaviEngineEvent] = []
        for await envelope in engine.events {
            events.append(envelope.event)
            if events.count == 1 { break }
        }
        #expect(events == [.naviStopped])
    }

    @Test("a new destination wins over the slower old fetch")
    func newDestinationWins() async {
        let transport = HeldTransport()
        let drawn = Mutex<[RouteGeometry]>([])
        let engine = engine(transport, drawn: drawn)
        let g1 = Generation.initial.next()
        let g2 = g1.next()
        async let old: Void = engine.calculateRoutes(destination, generation: g1)
        while !transport.isHolding { await Task.yield() }
        await engine.calculateRoutes(destination, generation: g2)
        transport.release()
        await old
        #expect(drawn.withLock { $0.last?.routes.first?.summary.lengthMeters } == 2_000)
        var iterator = engine.events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.generation == g2)
    }
}
