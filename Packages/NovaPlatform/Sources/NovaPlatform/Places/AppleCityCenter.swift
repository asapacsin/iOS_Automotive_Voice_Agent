#if canImport(MapKit)
import CoreLocation
import Foundation
import MapKit
import NovaKit
import NovaPorts

/// F-15b §36 item 2a (2026-11-18): the centre of an abroad trip's city ("Tokyo, Japan") for Apple's place search.
/// Apple's geocoder first, then Apple's address search; a result in China (CN, HK, MO, TW) is never used, since the
/// trip is abroad. 8 s each; nil when neither finds the city.
public enum AppleCityCenter {
    public static func find(_ city: String) async -> GeoCoordinate? {
        if let c = await geocode(city) { return c }
        return await addressSearch(city)
    }

    private static func usable(_ code: String?, _ c: CLLocationCoordinate2D) -> GeoCoordinate? {
        guard !TripRegion.isChina(code) else { return nil }
        return GeoCoordinate(latitude: c.latitude, longitude: c.longitude, datum: .gcj02)
    }

    private static func geocode(_ city: String) async -> GeoCoordinate? {
        await withTimeout {
            let marks = try? await CLGeocoder().geocodeAddressString(city)
            for mark in marks ?? [] {
                if let loc = mark.location, let c = usable(mark.isoCountryCode, loc.coordinate) { return c }
            }
            return nil
        }
    }

    private static func addressSearch(_ city: String) async -> GeoCoordinate? {
        await withTimeout {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = city
            request.resultTypes = .address
            nonisolated(unsafe) let search = MKLocalSearch(request: request)
            let items = (try? await search.start())?.mapItems ?? []
            for item in items {
                if let c = usable(item.placemark.isoCountryCode, item.placemark.coordinate) { return c }
            }
            return nil
        }
    }

    private static func withTimeout(_ work: @escaping @Sendable () async -> GeoCoordinate?) async -> GeoCoordinate? {
        await withTaskGroup(of: GeoCoordinate?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
#endif
