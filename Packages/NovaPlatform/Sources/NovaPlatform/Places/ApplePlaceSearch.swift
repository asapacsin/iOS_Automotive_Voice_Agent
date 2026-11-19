#if canImport(MapKit)
import Foundation
import MapKit
import NovaKit
import NovaPorts

/// F-15b §41 (T-040o): Apple's place search for trips abroad (`MKLocalSearch`, no key, no fee). An 8 s limit per
/// search, at most 2 at once, one retry after 1 s when Apple throttles (`MKError.loadingThrottled`). Errors come back
/// as `AmapWebError` so the trip planner treats both vendors alike (`quota` = throttled). Outside China GCJ-02
/// equals WGS-84, so Apple's coordinates are used as they are (§36 item 5).
public final class ApplePlaceSearch: PlaceSearch, @unchecked Sendable {
    public static let timeoutSeconds: Double = 8
    public static let parallel = 2
    private let gate = SearchGate(limit: ApplePlaceSearch.parallel)

    public init() {}

    public func text(_ keywords: String, city: String?) async throws -> [Place] {
        try await search(city.map { "\($0) \(keywords)" } ?? keywords, region: nil)
    }

    public func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        let c = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        let span = Double(max(radiusMeters, 100)) * 2
        return try await search(keywords, region: MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span))
    }

    /// §37 item 4: Apple's region is a hint, so results outside the radius are dropped here.
    public func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let found = try await around(keywords, center: center, radiusMeters: radiusMeters, sort: sort)
        return found.compactMap { place in
            let d = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude).distance(from: here)
            guard d <= Double(radiusMeters) else { return nil }
            return Place(id: place.id, name: place.name, address: place.address, coordinate: place.coordinate,
                         distanceMeters: Int(d.rounded()), city: place.city, district: place.district, countryCode: place.countryCode)
        }.sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
    }

    public func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }

    /// Apple has no place detail by id here (§36 item 7: no photos abroad).
    public func detail(id: String) async throws -> Place? { nil }

    private func search(_ query: String, region: MKCoordinateRegion?) async throws -> [Place] {
        await gate.enter()
        defer { Task { await gate.leave() } }
        do {
            return try await once(query, region: region)
        } catch AmapWebError.quota {
            try? await Task.sleep(for: .seconds(1))
            return try await once(query, region: region)
        }
    }

    private func once(_ query: String, region: MKCoordinateRegion?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if let region {
            request.region = region
            // §36 item 2a: without this Apple still prefers places near the phone (in China) over the trip's city.
            request.regionPriority = .required
        }
        // MKLocalSearch is not Sendable; it is only started and cancelled here, as Apple documents.
        nonisolated(unsafe) let search = MKLocalSearch(request: request)
        return try await withThrowingTaskGroup(of: [Place].self) { group in
            group.addTask {
                do {
                    let response = try await search.start()
                    return response.mapItems.prefix(10).map(Self.place)
                } catch let error as MKError where error.code == .loadingThrottled {
                    throw AmapWebError.quota
                } catch let error as MKError where error.code == .placemarkNotFound {
                    return []
                } catch {
                    throw AmapWebError.failed
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.timeoutSeconds))
                search.cancel()
                throw AmapWebError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    static func place(_ item: MKMapItem) -> Place {
        let mark = item.placemark
        let c = mark.coordinate
        let name = item.name ?? mark.name ?? ""
        // A stable id from the name and the coordinate (Apple gives no public id here).
        let id = "apple_\(name)@\((c.latitude * 10_000).rounded() / 10_000),\((c.longitude * 10_000).rounded() / 10_000)"
        let address = [mark.locality, mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined()
        return Place(id: id, name: name, address: address.isEmpty ? nil : address,
                     coordinate: GeoCoordinate(latitude: c.latitude, longitude: c.longitude, datum: .gcj02),
                     distanceMeters: nil, city: mark.locality, district: mark.subLocality, countryCode: mark.isoCountryCode)
    }
}

/// At most `limit` searches at once.
actor SearchGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty {
            running = max(running - 1, 0)
        } else {
            waiting.removeFirst().resume()
        }
    }
}
#endif
