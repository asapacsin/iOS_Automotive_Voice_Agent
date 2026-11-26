import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import NovaNav

/// F-15b §47 item 2: at most one OSRM demo-server request per second, shared by the route service and the §36 item
/// 2c table (usage policy: github.com/Project-OSRM/osrm-backend/wiki/Api-usage-policy).
public actor OsrmThrottle {
    private let clock: any NovaClock
    private var next: NovaInstant?

    public init(clock: any NovaClock = SystemClock()) { self.clock = clock }

    /// Waits until a second has passed since the previous request began, then books this one.
    public func admit() async {
        let now = clock.now
        let start = next.map { max($0, now) } ?? now
        next = start + .seconds(1)
        if start > now { try? await clock.sleep(until: start) }
    }
}

/// F-15b §47 items 2–4 (T-040s): driving routes abroad from OSRM's route service
/// (`router.project-osrm.org/route/v1/driving/<lng,lat>;<lng,lat>?steps=true&overview=full&geometries=geojson&
/// alternatives=true`, no key): up to 3 routes, 8 s limit, no retry. Each step's sentence comes from the copied zh-Hans
/// osrm-text-instructions templates (`OsrmInstructions`). Coordinates are WGS-84, used as they are abroad (equal to
/// GCJ-02 outside China, §36 item 5). Errors come back as `AmapWebError`.
public final class OsrmRouteSource: RouteSource, @unchecked Sendable {
    public static let host = "https://router.project-osrm.org/route/v1/driving/"
    public static let timeoutSeconds: Double = 8
    public static let attributionText = "路线 © OSRM · 地图数据 © OpenStreetMap"
    private let transport: any HTTPTransport
    private let throttle: OsrmThrottle?

    public init(transport: any HTTPTransport = URLSessionTransport(connectTimeout: .seconds(8)),
                throttle: OsrmThrottle? = nil) {
        self.transport = transport
        self.throttle = throttle
    }

    public var vendor: String { "osrm" }
    public var attribution: String? { Self.attributionText }

    public func routes(from: GeoCoordinate, to: GeoCoordinate, destinationName: String) async throws -> [PlannedRoute] {
        // F-15b §71 item 5 (T-040zx): a 高德 (GCJ-02) point in Macau/Hong Kong goes to OSRM as WGS-84; abroad unchanged.
        let path = [from, to].map { SpecialRegion.inDeltaBox($0) ? CoordinateConverter.wgs84($0) : $0 }.map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }.joined(separator: ";")
        guard var components = URLComponents(string: Self.host + path) else { throw AmapWebError.failed }
        components.queryItems = [
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "alternatives", value: "true"),
        ]
        guard let url = components.url else { throw AmapWebError.failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("NovaDrive/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        await throttle?.admit()
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AmapWebError.timeout
        } catch {
            throw AmapWebError.failed
        }
        if response.status == 429 { throw AmapWebError.quota }
        guard response.status == 200 else { throw AmapWebError.failed }
        return try Self.parse(response.body, destinationName: destinationName)
    }

    /// §47 item 3: each OSRM route as a `PlannedRoute` (steps' geometry joined, `startIndex` where each begins;
    /// toll and traffic lights unknown → 0). `code` must be `Ok`.
    static func parse(_ body: Data, destinationName: String) throws -> [PlannedRoute] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (root["code"] as? String) == "Ok" else { throw AmapWebError.failed }
        let routes = (root["routes"] as? [[String: Any]]) ?? []
        return routes.prefix(3).enumerated().map { index, route in
            var points: [GeoCoordinate] = []
            var steps: [PlannedRoute.Step] = []
            let legs = (route["legs"] as? [[String: Any]]) ?? []
            for (legIndex, leg) in legs.enumerated() {
                for step in (leg["steps"] as? [[String: Any]]) ?? [] {
                    let road = OsrmInstructions.wayName(step)
                    let text = OsrmInstructions.compile(step, legIndex: legIndex, legCount: legs.count,
                                                        waypointName: legIndex == legs.count - 1 ? destinationName : nil)
                    steps.append(PlannedRoute.Step(instruction: text, road: road.isEmpty ? nil : road,
                                                   startIndex: points.count))
                    let coordinates = ((step["geometry"] as? [String: Any])?["coordinates"] as? [[Any]]) ?? []
                    for pair in coordinates {
                        guard pair.count >= 2, let lng = (pair[0] as? NSNumber)?.doubleValue,
                              let lat = (pair[1] as? NSNumber)?.doubleValue else { continue }
                        // §71 item 5: back to GCJ-02 for the map inside China's box (unchanged abroad).
                        let p = GeoCoordinate(latitude: lat, longitude: lng, datum: .wgs84)
                        points.append(SpecialRegion.inDeltaBox(p) ? CoordinateConverter.gcj02(p)
                                      : GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02))
                    }
                }
            }
            let meters = Int(((route["distance"] as? NSNumber)?.doubleValue ?? 0).rounded())
            let seconds = Int(((route["duration"] as? NSNumber)?.doubleValue ?? 0).rounded())
            let summary = RouteSummary(id: RouteID(index + 1), lengthMeters: meters, durationSeconds: seconds,
                                       tollYuan: 0, trafficLights: 0, label: nil, polyline: points)
            return PlannedRoute(summary: summary, points: points, steps: steps)
        }
    }
}
