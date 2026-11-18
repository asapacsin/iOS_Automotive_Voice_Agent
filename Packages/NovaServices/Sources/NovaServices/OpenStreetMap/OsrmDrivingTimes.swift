import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §36 item 2c (T-040p): driving times abroad from the OSRM table service
/// (`router.project-osrm.org/table/v1/driving/<lng,lat;…>?annotations=duration,distance`, no key). 高德 refuses abroad
/// times (`/v3/distance` 20011, `/v3/direction/driving` 10045). One request gives every pair; 8 s limit, no retry;
/// `TripTimes` keeps at most one in flight (usage policy: at most 1 request per second,
/// github.com/Project-OSRM/osrm-backend/wiki/Api-usage-policy). Errors come back as `AmapWebError`. Coordinates are
/// WGS-84, equal to GCJ-02 outside China.
public final class OsrmDrivingTimes: DrivingTimes, @unchecked Sendable {
    public static let host = "https://router.project-osrm.org/table/v1/driving/"
    public static let timeoutSeconds: Double = 8
    private let transport: any HTTPTransport
    /// F-15b §47 item 2: shared with `OsrmRouteSource` (1 request per second in all).
    private let throttle: OsrmThrottle?

    public init(transport: any HTTPTransport = URLSessionTransport(connectTimeout: .seconds(8)),
                throttle: OsrmThrottle? = nil) {
        self.transport = transport
        self.throttle = throttle
    }

    public var answersWholeTable: Bool { true }

    /// The §26 per-destination form, from the same one table request.
    public func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        let all = try await table(origins + [destination])
        return origins.indices.map { all[$0][origins.count] }
    }

    public func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]] {
        guard points.count >= 2 else { return points.map { _ in [nil] } }
        let path = points.map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }.joined(separator: ";")
        guard var components = URLComponents(string: Self.host + path) else { throw AmapWebError.failed }
        components.queryItems = [URLQueryItem(name: "annotations", value: "duration,distance")]
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
        return try Self.parse(response.body, count: points.count)
    }

    /// `durations[i][j]` seconds and `distances[i][j]` meters; `null` → nil. `code` must be `Ok`.
    static func parse(_ body: Data, count: Int) throws -> [[DrivingTime?]] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (root["code"] as? String) == "Ok",
              let durations = root["durations"] as? [Any], durations.count == count else { throw AmapWebError.failed }
        let distances = root["distances"] as? [Any]
        return try (0..<count).map { (i: Int) throws -> [DrivingTime?] in
            guard let row = durations[i] as? [Any], row.count == count else { throw AmapWebError.failed }
            let distanceRow = (distances?[safe: i] as? [Any]) ?? []
            return (0..<count).map { (j: Int) -> DrivingTime? in
                guard let seconds = (row[j] as? NSNumber)?.doubleValue else { return nil }
                let meters = ((distanceRow[safe: j]) as? NSNumber)?.doubleValue ?? 0
                return DrivingTime(meters: Int(meters.rounded()), seconds: Int(seconds.rounded()))
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
