import Foundation
import NovaKit

public enum CoordinateDatum: String, Sendable, Hashable {
    /// GPS / CoreLocation.
    case wgs84
    /// Amap (all Amap calls take GCJ-02).
    case gcj02
}

public struct GeoCoordinate: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double
    public let datum: CoordinateDatum

    public init(latitude: Double, longitude: Double, datum: CoordinateDatum) {
        self.latitude = latitude
        self.longitude = longitude
        self.datum = datum
    }
}

public struct RouteID: Sendable, Hashable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public struct RouteRequest: Sendable, Hashable {
    public let destination: GeoCoordinate
    public let destinationName: String
    /// F-15b §47 item 1 (T-040s): from an `abroad` trip or `navigate_to abroad=true`; the route then comes from
    /// OSRM instead of 高德.
    public let abroad: Bool

    public init(destination: GeoCoordinate, destinationName: String, abroad: Bool = false) {
        self.destination = destination
        self.destinationName = destinationName
        self.abroad = abroad
    }
}

/// F-15b §26 (T-040n): one driving time from an origin to a destination (高德 `/v3/distance type=1`).
public struct DrivingTime: Sendable, Hashable {
    public let meters: Int
    public let seconds: Int
    public init(meters: Int, seconds: Int) {
        self.meters = meters
        self.seconds = seconds
    }
}

/// F-15b §26 item 5: driving times from many origins to one destination, in `origins` order; nil where 高德 gave
/// none. Throws `AmapWebError` (`.quota` is retried by the caller).
public protocol DrivingTimes: Sendable {
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?]
    /// §36 item 2c (T-040p): true when one `table(_:)` request gives every pair (OSRM); then `TripTimes` makes that
    /// one request instead of one per destination.
    var answersWholeTable: Bool { get }
    /// Every pair of `points` in one request: `[from][to]`, nil where the vendor gave none. Throws `AmapWebError`.
    func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]]
}

public extension DrivingTimes {
    var answersWholeTable: Bool { false }
    func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]] { throw AmapWebError.failed }
}

public struct RouteSummary: Sendable, Hashable {
    public let id: RouteID
    public let lengthMeters: Int
    public let durationSeconds: Int
    public let tollYuan: Int
    public let trafficLights: Int
    public let label: String?
    /// The route's shape, GCJ-02, for the along-route corridor (F-16). Empty when the engine has none.
    public let polyline: [GeoCoordinate]

    public init(id: RouteID, lengthMeters: Int, durationSeconds: Int, tollYuan: Int, trafficLights: Int,
                label: String?, polyline: [GeoCoordinate] = []) {
        self.polyline = polyline
        self.id = id
        self.lengthMeters = lengthMeters
        self.durationSeconds = durationSeconds
        self.tollYuan = tollYuan
        self.trafficLights = trafficLights
        self.label = label
    }
}

public enum NaviMode: String, Sendable, Hashable {
    case gps
    /// `startEmulatorNavi`, indoor simulation only.
    case emulator
}

/// From `updateNaviInfo:` (contracts/navigation.md HUD fields).
public struct NaviInfo: Sendable, Hashable {
    public let iconType: Int
    public let stepDistanceMeters: Int
    public let nextRoadName: String?
    public let remainingMeters: Int
    public let remainingSeconds: Int
    public let currentSpeedKmh: Int?
    /// Road-facility speed limit from the navi info (0 = no data); merged with cameras (navigation.md Overspeed).
    public let facilityLimitKmh: Int

    public init(iconType: Int, stepDistanceMeters: Int, nextRoadName: String?, remainingMeters: Int,
                remainingSeconds: Int, currentSpeedKmh: Int?, facilityLimitKmh: Int = 0) {
        self.iconType = iconType
        self.stepDistanceMeters = stepDistanceMeters
        self.nextRoadName = nextRoadName
        self.remainingMeters = remainingMeters
        self.remainingSeconds = remainingSeconds
        self.currentSpeedKmh = currentSpeedKmh
        self.facilityLimitKmh = facilityLimitKmh
    }
}

/// From `updateCameraInfos:`. A limit of 0 means no data.
public struct CameraInfo: Sendable, Hashable {
    public let distanceMeters: Int
    public let speedLimitKmh: Int

    public init(distanceMeters: Int, speedLimitKmh: Int) {
        self.distanceMeters = distanceMeters
        self.speedLimitKmh = speedLimitKmh
    }
}

public enum NaviEngineEvent: Sendable, Hashable {
    case routesReady([RouteSummary])
    case routeCalculationFailed(code: Int)
    case naviStarted
    case naviInfo(NaviInfo)
    case cameraInfo([CameraInfo])
    case guidanceText(String, GuidanceID)
    case arrived
    case naviStopped
    /// F-15a 真实导航: off route, a new route is being calculated from the current fix.
    case rerouting
    /// The recalculation finished: the new route, or nil when it failed and the old route stays.
    case rerouted(RouteSummary?)
}

/// Every engine event carries the generation of the request it answers; stale ones are dropped.
public struct NaviEngineEnvelope: Sendable, Hashable {
    public let generation: Generation
    public let event: NaviEngineEvent

    public init(generation: Generation, event: NaviEngineEvent) {
        self.generation = generation
        self.event = event
    }
}

/// Amap Navi SDK behind a protocol; the SDK lives only in NovaNavAmap (I-9).
public protocol NaviEngine: Sendable {
    var events: AsyncStream<NaviEngineEnvelope> { get }
    func calculateRoutes(_ request: RouteRequest, generation: Generation) async
    func selectRoute(_ id: RouteID, generation: Generation) async
    func start(_ mode: NaviMode, generation: Generation) async
    func stop(generation: Generation) async
    /// F-15a §2.5 (T-040h) 真实导航 route change: routes from the current position to the trip's destination, with
    /// ids unused by earlier calculations, for `selectRoute` + `start`. The trip keeps driving its route meanwhile.
    /// nil when it fails or the engine cannot recalculate.
    func recalculateFromHere(generation: Generation) async -> [RouteSummary]?
}

public extension NaviEngine {
    func recalculateFromHere(generation: Generation) async -> [RouteSummary]? { nil }
}

public struct LocationFix: Sendable, Hashable {
    public let coordinate: GeoCoordinate
    public let horizontalAccuracyMeters: Double
    public let timestamp: NovaInstant
    /// F-16b: ground speed and course; nil when unknown (the adapter maps CoreLocation's negative values to nil).
    public let speedMetersPerSecond: Double?
    public let courseDegrees: Double?

    public init(coordinate: GeoCoordinate, horizontalAccuracyMeters: Double, timestamp: NovaInstant,
                speedMetersPerSecond: Double? = nil, courseDegrees: Double? = nil) {
        self.coordinate = coordinate
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
    }
}

/// F-16b: every new fix of the current source, for the map's 我的位置 marker.
public protocol LocationUpdates: Sendable {
    func updates() -> AsyncStream<LocationFix>
}

public protocol LocationProvider: Sendable {
    func latestFix() async -> LocationFix?
    /// F-16a: whether the position may be read at all (denied → `LOCATION_PERMISSION_DENIED`).
    func authorization() async -> LocationAuthorization
    /// F-16a: the phone's own position, or the fixed demo start point.
    var source: LocationSource { get }
}

public enum LocationAuthorization: Sendable, Hashable {
    case notDetermined, authorized, denied
}

public enum LocationSource: String, Sendable, Hashable {
    case device, demo
}

public extension LocationProvider {
    func authorization() async -> LocationAuthorization { .authorized }
    var source: LocationSource { .device }
}

/// F-16a: the regeo address of a point, for 「我现在在哪？」.
public struct PlaceAddress: Sendable, Hashable {
    public let formatted: String
    public let district: String?
    public let road: String?

    public init(formatted: String, district: String?, road: String?) {
        self.formatted = formatted
        self.district = district
        self.road = road
    }
}

public struct Place: Sendable, Hashable {
    public let id: String
    public let name: String
    public let address: String?
    public let coordinate: GeoCoordinate
    public let distanceMeters: Int?
    /// From the place detail only (F-18 place_details); nil when Amap gives none.
    public let openingHours: String?
    public let phone: String?
    /// F-16 §14 item 7: Amap's `cityname` and `adname`; nil when Amap gives none.
    public let city: String?
    public let district: String?
    /// F-15b §12 item 1 (T-040j): the first `photos[].url` of the place detail; nil when there is none.
    public let photoURL: URL?
    /// F-15b §41 (T-040o): ISO 3166 code from Apple's search (`placemark.isoCountryCode`); nil from 高德.
    public let countryCode: String?
    /// F-15b §46 item 6 (T-040r): the kind of place, from Photon's `osm_key`/`osm_value` or 高德's `type`; nil when unknown.
    public let kind: PlaceKind?

    public init(id: String, name: String, address: String?, coordinate: GeoCoordinate, distanceMeters: Int?,
                openingHours: String? = nil, phone: String? = nil, city: String? = nil, district: String? = nil,
                photoURL: URL? = nil, countryCode: String? = nil, kind: PlaceKind? = nil) {
        self.kind = kind
        self.photoURL = photoURL
        self.countryCode = countryCode
        self.city = city
        self.district = district
        self.openingHours = openingHours
        self.phone = phone
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
    }
}

extension Place {
    /// The same place with `photoURL` (F-15b §12).
    public func with(photoURL: URL?) -> Place {
        Place(id: id, name: name, address: address, coordinate: coordinate, distanceMeters: distanceMeters,
              openingHours: openingHours, phone: phone, city: city, district: district, photoURL: photoURL, countryCode: countryCode,
              kind: kind)
    }
}

/// F-15b §46 item 6 (T-040r): the kind of a place, for the card placeholder's icon and colours.
public enum PlaceKind: String, Sendable, Hashable, Codable, CaseIterable {
    case temple, tower, park, museum, hotel, airport, rental, shop, food, other

    /// The SF Symbol of the placeholder (§46 item 6).
    public var symbol: String {
        switch self {
        case .temple: return "building.columns"
        case .tower: return "binoculars"
        case .park: return "leaf"
        case .museum: return "building.2"
        case .hotel: return "bed.double"
        case .airport: return "airplane"
        case .rental: return "car"
        case .shop: return "bag"
        case .food: return "fork.knife"
        case .other: return "mappin.and.ellipse"
        }
    }
}

/// F-15b §46 items 1–3 (T-040r): a photo link for a stop abroad. nil when no page fits; throws when unreachable.
public protocol PlacePhotoSource: Sendable {
    /// `asked` is the name as written (「中文名 (English name)」); `near` is the stop.
    func photo(asked: String, near: GeoCoordinate) async throws -> URL?
}

public enum PlaceSort: String, Sendable {
    case distance, weight
}

/// Amap Web REST place endpoints (`/v3/place/text`, `/around`, `/polygon`, detail).
/// F-15b §4 item 6: one name the model asked for, and 高德's results for it (at most 5).
public struct PlaceChoice: Sendable, Hashable {
    public let asked: String
    public let city: String?
    public let candidates: [Place]
    public init(asked: String, city: String?, candidates: [Place]) {
        self.asked = asked
        self.city = city
        self.candidates = candidates
    }
}

/// Thrown by a `PlacePicker` with no key: recorded as `reason=nokey`.
public struct PlacePickerNotConfigured: Error, Equatable {
    public init() {}
}

/// F-15b §4 item 6 (owner 2026-11-17): a text model picks which result each asked name means.
public protocol PlacePicker: Sendable {
    /// One answer per choice, in order: the 0-based candidate index, or nil for none of them. Throws when there is
    /// no usable answer.
    func pick(_ choices: [PlaceChoice]) async throws -> [Int?]
    /// F-15b §59 item 3 (T-040zl): the model id written on every `trip pick` line.
    var model: String { get }
}

public extension PlacePicker {
    var model: String { "unknown" }
}

/// F-15b §36 (T-040o): which place search a trip uses. China here is the mainland, Hong Kong, Macau and Taiwan
/// (高德's coverage); everything else is `abroad` (Apple's search).
public enum TripRegion: String, Sendable, Hashable, Codable {
    case china, abroad

    /// §36 item 3: country codes that count as China.
    public static let chinaCodes: Set<String> = ["CN", "HK", "MO", "TW"]

    /// nil (高德 gives no code) counts as China.
    public static func isChina(_ countryCode: String?) -> Bool {
        guard let code = countryCode?.uppercased(), !code.isEmpty else { return true }
        return chinaCodes.contains(code)
    }
}

public protocol PlaceSearch: Sendable {
    func text(_ keywords: String, city: String?) async throws -> [Place]
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place]
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place]
    func detail(id: String) async throws -> Place?
    /// F-16 §14 item 1: `/v3/place/text` limited to `city` (`citylimit=true`) when `cityLimit` is set.
    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place]
    /// F-16 §14 item 1: `/v3/place/around` only, with no nationwide fallback when nothing is in the radius.
    func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place]
}

public extension PlaceSearch {
    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        try await text(keywords, city: city)
    }
    func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await around(keywords, center: center, radiusMeters: radiusMeters, sort: sort)
    }
}

/// F-18 §23 item 2: which day a weather call means. `offset` 0–3 from the phone's date; `date` is that day as
/// `yyyy-MM-dd` on the phone clock, the value Amap's `casts[].date` must equal.
public struct WeatherDay: Sendable, Hashable {
    public static let names = ["today", "tomorrow", "day_after", "day_after_next"]
    public let offset: Int
    public let date: String
    /// F-18 §28 item 2: true is 高德's live report (`extensions=base`); false is that date's `casts` entry,
    /// today included (item 3).
    public let live: Bool

    public init(offset: Int, date: String, live: Bool = false) {
        self.offset = offset
        self.date = date
        self.live = live
    }

    public var name: String { Self.names[min(max(offset, 0), Self.names.count - 1)] }
}


/// F-18 §26 item 11: one day of a provider-neutral daily forecast. `time` is `yyyy-MM-dd` in the place's own zone.
public struct DailyForecastDay: Sendable, Hashable {
    public let time: String
    public let weatherCode: Int?
    public let tempMax: Double?
    public let tempMin: Double?
    public let rainChance: Double?
    public let rainMm: Double?
    public let windMaxKmh: Double?
    /// F-18 §31 item 3: 和风's own words (`daytime`/`nighttime.condition.text`); nil for Open-Meteo (WMO code).
    public let dayText: String?
    public let nightText: String?

    public init(time: String, weatherCode: Int?, tempMax: Double?, tempMin: Double?, rainChance: Double?,
                rainMm: Double?, windMaxKmh: Double?, dayText: String? = nil, nightText: String? = nil) {
        self.dayText = dayText
        self.nightText = nightText
        self.time = time
        self.weatherCode = weatherCode
        self.tempMax = tempMax
        self.tempMin = tempMin
        self.rainChance = rainChance
        self.rainMm = rainMm
        self.windMaxKmh = windMaxKmh
    }
}

/// F-18 §27 item 2: the weather now at the place. `time` is `yyyy-MM-ddTHH:mm` on the place's own clock.
public struct CurrentWeather: Sendable, Hashable {
    public let time: String
    public let temperature: Double
    public let feelsLike: Double?
    public let humidity: Double?
    public let weatherCode: Int?
    public let windKmh: Double?
    /// F-18 §31 item 3: 和风's `condition.text`. `time` may be "" (和风's current has no update time).
    public let text: String?

    public init(time: String, temperature: Double, feelsLike: Double?, humidity: Double?, weatherCode: Int?,
                windKmh: Double?, text: String? = nil) {
        self.text = text
        self.time = time
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.humidity = humidity
        self.weatherCode = weatherCode
        self.windKmh = windKmh
    }
}

/// F-18 §28 item 4: one hour of the forecast. `time` is `yyyy-MM-ddTHH:mm` on the place's own clock.
public struct HourlyForecast: Sendable, Hashable {
    public let time: String
    public let weatherCode: Int?
    public let temperature: Double?
    public let rainChance: Double?
    /// F-18 §31 item 3: 和风's `condition.text`.
    public let text: String?

    public init(time: String, weatherCode: Int?, temperature: Double?, rainChance: Double?, text: String? = nil) {
        self.text = text
        self.time = time
        self.weatherCode = weatherCode
        self.temperature = temperature
        self.rainChance = rainChance
    }
}

/// F-18 §26 item 11, §28 item 5: the days, an optional current block and the hours (missing or unreadable: nil / []).
public struct DailyForecast: Sendable, Hashable {
    public let days: [DailyForecastDay]
    public let current: CurrentWeather?
    public let hours: [HourlyForecast]
    /// The place's offset from UTC (`utc_offset_seconds`), for its own clock (§28 item 4).
    public let utcOffsetSeconds: Int?

    public init(days: [DailyForecastDay], current: CurrentWeather? = nil, hours: [HourlyForecast] = [],
                utcOffsetSeconds: Int? = nil) {
        self.days = days
        self.current = current
        self.hours = hours
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

/// F-18 §26 item 11: a daily forecast port (Open-Meteo in NovaServices). `days[0]` is the place's own today.
public protocol DailyForecastService: Sendable {
    /// Coordinates are already rounded by the caller (§26 item 4).
    func dailyForecast(latitude: Double, longitude: Double) async throws -> DailyForecast
}

/// F-18 §31 item 3 (T-046t): what one view asks of 和风: `now` (current + daily?days=1), `day` (daily?days=10),
/// `hours` (hourly?hours=240).
public enum ForecastRequest: String, Sendable, Hashable { case now, day, hours }

/// F-18 §31 (T-046t): 和风天气, the first weather source. Lookup failures are `QWeatherError`.
public protocol ViewForecastService: PlaceLookup {
    func forecast(latitude: Double, longitude: Double, request: ForecastRequest) async throws -> DailyForecast
}

/// F-18 §31 items 5, 7: why 和风 did not answer. `notFound` (no `location`, or 400) never falls back.
public enum QWeatherError: Error, Sendable, Hashable {
    case noKey, timeout, failed, notFound, parse
    case http(Int)

    public var reason: String {
        switch self {
        case .noKey: "nokey"
        case .timeout: "timeout"
        case .failed: "failed"
        case .notFound: "not_found"
        case .parse: "parse"
        case .http(let s): "http\(s)"
        }
    }
}

/// F-18 §26 item 4: a forecast call that timed out or failed. No response text (I-8).
public enum ForecastError: Error, Sendable, Hashable {
    case timeout
    case failed
}

/// F-18 §30 item 4 (T-046s): how many attempts the last Open-Meteo request of a weather call took (1 or 2). The
/// weather call sets one with `$current.withValue`; the client writes it. Numbers only (I-8).
public final class ForecastAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    public var last: Int { lock.withLock { value } }
    public func set(_ n: Int) { lock.withLock { value = n } }
    @TaskLocal public static var current: ForecastAttempts?
}

/// F-18 §26 item 2: one place a name lookup found.
public struct LookedUpPlace: Sendable, Hashable {
    /// 高德's `city` or Open-Meteo's `name`.
    public let name: String
    /// Open-Meteo's `country` (foreign places only).
    public let country: String?
    public let coordinate: GeoCoordinate?
    /// 高德's `formatted_address`.
    public let formatted: String?
    /// 高德's adcode.
    public let adcode: String?
    /// Open-Meteo's `population`.
    public let population: Int?
    /// F-18 §29 item 3: Open-Meteo's `country_code` (two capital letters).
    public let countryCode: String?

    public init(name: String, country: String? = nil, coordinate: GeoCoordinate?, formatted: String? = nil,
                adcode: String? = nil, population: Int? = nil, countryCode: String? = nil) {
        self.countryCode = countryCode
        self.name = name
        self.country = country
        self.coordinate = coordinate
        self.formatted = formatted
        self.adcode = adcode
        self.population = population
    }
}

/// F-18 §26 item 11: a place-lookup port (高德 `/v3/geocode/geo`, or Open-Meteo geocoding with `country`).
public protocol PlaceLookup: Sendable {
    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace]
}

public protocol ReverseGeocoder: Sendable {
    func adcode(at coordinate: GeoCoordinate) async throws -> String?
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress?
    /// F-16 §14 item 1: the car's adcode and formatted address (its province and city) in one lookup.
    func region(at coordinate: GeoCoordinate) async throws -> PlaceRegion
}

/// F-16 §14 item 1: where the car is, for the city-limited search and the other-city check.
public struct PlaceRegion: Sendable, Hashable {
    public let adcode: String?
    /// Regeo `formatted_address` (starts with the province and city), or nil.
    public let formatted: String?

    public init(adcode: String?, formatted: String?) {
        self.adcode = adcode
        self.formatted = formatted
    }
}

public extension ReverseGeocoder {
    func region(at coordinate: GeoCoordinate) async throws -> PlaceRegion {
        PlaceRegion(adcode: try await adcode(at: coordinate), formatted: try await address(at: coordinate)?.formatted)
    }
}

public struct StaticMapRequest: Sendable, Hashable {
    public let center: GeoCoordinate
    public let zoom: Int
    public let widthPixels: Int
    public let heightPixels: Int
    public let markers: [GeoCoordinate]

    public init(center: GeoCoordinate, zoom: Int, widthPixels: Int, heightPixels: Int, markers: [GeoCoordinate]) {
        self.center = center
        self.zoom = zoom
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.markers = markers
    }
}

/// Amap Web `/v3/staticmap`; returns PNG bytes.
public protocol StaticMapService: Sendable {
    func image(_ request: StaticMapRequest) async throws -> [UInt8]
}

/// Why an Amap Web request gave nothing. Codes only; the response text never leaves the adapter (I-8).
public enum AmapWebError: Error, Sendable, Hashable {
    case keyMissing
    case keyRejected
    case quota
    case timeout
    case failed
    /// F-15b §52 item 11 (T-040zd): the lookup ran out of tries (`search_slow`); never "the place does not exist".
    case slow
}

/// F-15b §62 items 2, 10 (T-040zo): the planner model that writes and reviews a trip plan (`QwenRoute.planner`'s chain, its client
/// in NovaRealtime). One chat completion per round: the system text, then the conversation so far; the answer is the
/// model's text (JSON asked for). Throws `TripPlannerModelError` on an HTTP error; the client moves along `QwenRoute.planner`'s chain on a quota or rate error (F-18 §36, §40).
public protocol TripPlannerModel: Sendable {
    func complete(system: String, messages: [TripPlannerMessage]) async throws -> String
    /// The model id written on every `trip planner round=` line.
    var model: String { get }
}

public struct TripPlannerMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum TripPlannerModelError: Error, Equatable {
    case http(Int)
    case notConfigured
}
