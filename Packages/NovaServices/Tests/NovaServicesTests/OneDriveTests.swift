import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// Answers every driving-directions request at once with one short route.
struct InstantTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let json = """
        {"status":"1","route":{"paths":[{"distance":"5000","duration":"600","tolls":"0","traffic_lights":"2",
        "steps":[{"instruction":"直行","road":"路","polyline":"113.57,22.27;113.60,22.30"}]}]}}
        """
        return (200, Data(json.utf8))
    }
}

/// Every geometry the engine drew, in order.
final class DrawnAll: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RouteGeometry] = []
    func append(_ g: RouteGeometry) { lock.withLock { items.append(g) } }
    var all: [RouteGeometry] { lock.withLock { items } }
}

@Suite("T-040g F-15a §9 one drive at a time")
struct OneDriveTests {
    let destination = RouteRequest(destination: GeoCoordinate(latitude: 22.30, longitude: 113.60, datum: .gcj02),
                                   destinationName: "珠海站")

    @Test("F-15a row 15: after stop no car position reaches the map; a new trip on the same engine drives once")
    func stoppedDriveDrawsNothing() async throws {
        let drawn = DrawnAll()
        let origin = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02)
        let engine = AmapRouteEngine(key: { "k" }, origin: { origin }, transport: InstantTransport(),
                                     onGeometry: { drawn.append($0) })
        var events = engine.events.makeAsyncIterator()
        func trip(_ generation: Generation) async throws {
            await engine.calculateRoutes(destination, generation: generation)
            var ready: RouteSummary?
            while ready == nil, let envelope = await events.next() {
                if envelope.generation == generation, case .routesReady(let routes) = envelope.event { ready = routes.first }
            }
            guard let first = ready else { Issue.record("no routes"); return }
            await engine.selectRoute(first.id, generation: generation)
            await engine.start(.emulator, generation: generation)
        }
        let g1 = Generation.initial.next()
        try await trip(g1)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(drawn.all.contains { $0.car != nil })
        await engine.stop(generation: g1)
        let afterStop = drawn.all.count
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(drawn.all.dropFirst(afterStop).allSatisfy { $0.car == nil })
        #expect(drawn.all.last?.car == nil)
        // A second trip: one car, moving forward, never back at the first trip's place.
        let g2 = g1.next().next()
        try await trip(g2)
        try await Task.sleep(for: .milliseconds(2_300))
        let cars = drawn.all.dropFirst(afterStop).compactMap(\.car)
        #expect(!cars.isEmpty)
        #expect(zip(cars, cars.dropFirst()).allSatisfy { $1.longitude >= $0.longitude })
        await engine.stop(generation: g2)
    }
}
