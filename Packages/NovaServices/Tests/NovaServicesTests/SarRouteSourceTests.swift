import Foundation
import Synchronization
import Testing
import NovaKit
import NovaNav
import NovaPorts
@testable import NovaServices

/// OSRM route stand-in: keeps what it was asked and answers one straight route in WGS-84.
private final class RecordingSource: RouteSource, @unchecked Sendable {
    let asked = Mutex<[(GeoCoordinate, GeoCoordinate)]>([])
    var vendor: String { "osrm" }
    var attribution: String? { "© OpenStreetMap" }
    func routes(from: GeoCoordinate, to: GeoCoordinate, destinationName: String) async throws -> [PlannedRoute] {
        asked.withLock { $0.append((from, to)) }
        let summary = RouteSummary(id: RouteID(1), lengthMeters: 2_700, durationSeconds: 600, tollYuan: 0, trafficLights: 0, label: nil)
        return [PlannedRoute(summary: summary, points: [from, to], steps: [])]
    }
}

@Suite("T-040zx F-15b §71 item 5 guidance to a Macau stop on OSRM with GCJ-02 → WGS-84")
struct SarRouteSourceTests {
    @Test("T-040zx F-15b §71 row 341 (guidance): the car and the stop go to OSRM as WGS-84; the route comes back as GCJ-02")
    func shift() async throws {
        let base = RecordingSource()
        let source = SarRouteSource(base: base)
        let car = GeoCoordinate(latitude: 22.215, longitude: 113.55, datum: .gcj02)
        let stop = GeoCoordinate(latitude: 22.197, longitude: 113.540, datum: .gcj02)
        let routes = try await source.routes(from: car, to: stop, destinationName: "大三巴牌坊")
        let (from, to) = try #require(base.asked.withLock { $0.first })
        #expect(from.datum == .wgs84 && to.datum == .wgs84)
        #expect(abs(from.latitude - car.latitude) + abs(from.longitude - car.longitude) > 0.003)
        let back = try #require(routes.first?.points.last)
        #expect(back.datum == .gcj02 && abs(back.latitude - stop.latitude) < 1e-7 && abs(back.longitude - stop.longitude) < 1e-7)
        #expect(source.vendor == "osrm" && source.attribution == "© OpenStreetMap")
    }
}
