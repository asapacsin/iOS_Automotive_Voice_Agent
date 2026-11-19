import Foundation

/// F-15b §50 item 3 (T-040v): the area of a trip abroad: the city's centre and its ISO 3166 country code.
public struct TripArea: Sendable, Hashable {
    public let center: GeoCoordinate
    public let countryCode: String?
    public init(center: GeoCoordinate, countryCode: String?) {
        self.center = center
        self.countryCode = countryCode?.uppercased()
    }
}

/// F-15b §50 item 3: a latitude/longitude box (Photon's `bbox=minLon,minLat,maxLon,maxLat`).
public struct GeoBox: Sendable, Hashable {
    public let minLatitude: Double
    public let minLongitude: Double
    public let maxLatitude: Double
    public let maxLongitude: Double
    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    /// §50 item 3: the centre ± 0.45° latitude and ± 0.55° longitude (about 50 km).
    public static func around(_ c: GeoCoordinate, latitude: Double = 0.45, longitude: Double = 0.55) -> GeoBox {
        GeoBox(minLatitude: c.latitude - latitude, minLongitude: c.longitude - longitude,
               maxLatitude: c.latitude + latitude, maxLongitude: c.longitude + longitude)
    }
}

/// F-15b §50 item 3: a place search that can be restricted to a box (Photon). Results outside the box are not returned.
public protocol AreaPlaceSearch: PlaceSearch {
    func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place]
}

/// F-15b §50 item 1 (T-040v): one place as the model gave it, or as the grounding answer gives it.
public struct TripGroundPlace: Sendable, Hashable {
    public let name: String
    /// The name on maps (English); nil in the model's own list.
    public let english: String?
    public let minutes: Int?
    public let importance: Int
    public init(name: String, english: String? = nil, minutes: Int?, importance: Int) {
        self.name = name
        self.english = english
        self.minutes = minutes
        self.importance = importance
    }
}

/// F-15b §50 item 1: the input values of the grounding request.
public struct TripGroundRequest: Sendable, Hashable {
    public let city: String
    public let days: Int
    public let places: [TripGroundPlace]
    public let wishes: String?
    public let start: String?
    public let end: String?
    public let hotelNear: String?
    public init(city: String, days: Int, places: [TripGroundPlace], wishes: String? = nil, start: String? = nil,
                end: String? = nil, hotelNear: String? = nil) {
        self.city = city
        self.days = days
        self.places = places
        self.wishes = wishes
        self.start = start
        self.end = end
        self.hotelNear = hotelNear
    }
}

/// F-15b §50 item 1: a hotel the grounding answer names for a night (1-based).
public struct TripGroundHotel: Sendable, Hashable {
    public let night: Int
    public let name: String
    public let english: String?
    public init(night: Int, name: String, english: String?) {
        self.night = night
        self.name = name
        self.english = english
    }
}

/// F-15b §50 item 1: the checked JSON answer.
public struct TripGroundAnswer: Sendable, Hashable {
    public let places: [TripGroundPlace]
    public let hotels: [TripGroundHotel]
    public let area: String?
    public init(places: [TripGroundPlace], hotels: [TripGroundHotel], area: String?) {
        self.places = places
        self.hotels = hotels
        self.area = area
    }
}

/// F-15b §50 items 1 and 9: why a grounding answer was not used (`reason=` in `trip ground`).
public enum TripGroundError: String, Error, Sendable, Hashable {
    case notConfigured = "nokey"
    /// §50 item 9: the answer had no search result.
    case noSearch = "nosearch"
    /// Missing or wrong fields, or not JSON.
    case json
    case failed
    case timeout
}

/// F-15b §50 item 1: turns the trip request into real places with web search (Qwen `ground` route).
public protocol TripGrounder: Sendable {
    func ground(_ request: TripGroundRequest) async throws -> TripGroundAnswer
}
