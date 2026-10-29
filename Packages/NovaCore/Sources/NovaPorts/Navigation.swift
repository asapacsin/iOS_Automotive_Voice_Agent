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

    public init(destination: GeoCoordinate, destinationName: String) {
        self.destination = destination
        self.destinationName = destinationName
    }
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

    public init(id: String, name: String, address: String?, coordinate: GeoCoordinate, distanceMeters: Int?,
                openingHours: String? = nil, phone: String? = nil) {
        self.openingHours = openingHours
        self.phone = phone
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
    }
}

public enum PlaceSort: String, Sendable {
    case distance, weight
}

/// Amap Web REST place endpoints (`/v3/place/text`, `/around`, `/polygon`, detail).
public protocol PlaceSearch: Sendable {
    func text(_ keywords: String, city: String?) async throws -> [Place]
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place]
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place]
    func detail(id: String) async throws -> Place?
}

public struct WeatherReport: Sendable, Hashable {
    public let adcode: String
    public let summary: JSONValue

    public init(adcode: String, summary: JSONValue) {
        self.adcode = adcode
        self.summary = summary
    }
}

public protocol WeatherService: Sendable {
    func weather(adcode: String, forecast: Bool) async throws -> WeatherReport
}

public protocol ReverseGeocoder: Sendable {
    func adcode(at coordinate: GeoCoordinate) async throws -> String?
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress?
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
}
