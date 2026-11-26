import NovaKit
import NovaNav
import NovaPorts

/// F-15b §71 item 5 (T-040zx): OSRM for a stop in Macau or Hong Kong. 高德's points there are GCJ-02 (as on the
/// mainland), OSRM's are WGS-84: the car and the stop go out converted GCJ-02 → WGS-84, and the route's points come
/// back converted WGS-84 → GCJ-02 for the map and the guidance. Abroad (no shift) the plain source is used instead.
public struct SarRouteSource: RouteSource {
    public let base: any RouteSource
    public init(base: any RouteSource) { self.base = base }

    public var vendor: String { base.vendor }
    public var attribution: String? { base.attribution }

    public func routes(from: GeoCoordinate, to: GeoCoordinate, destinationName: String) async throws -> [PlannedRoute] {
        let routes = try await base.routes(from: CoordinateConverter.wgs84(from), to: CoordinateConverter.wgs84(to),
                                           destinationName: destinationName)
        return routes.map { route in
            PlannedRoute(summary: route.summary,
                         points: route.points.map {
                             CoordinateConverter.gcj02(GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude, datum: .wgs84))
                         },
                         steps: route.steps)
        }
    }
}
