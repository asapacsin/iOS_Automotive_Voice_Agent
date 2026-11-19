import NovaKit

/// One planned route with its geometry, for the map and the guidance (GCJ-02 at home; abroad WGS-84, which equals
/// GCJ-02 outside China, F-15b §36 item 5). Moved here from NovaServices for `RouteSource` (F-15b §47 item 10).
public struct PlannedRoute: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public let instruction: String
        public let road: String?
        /// Index into `points` where this step begins.
        public let startIndex: Int

        public init(instruction: String, road: String?, startIndex: Int) {
            self.instruction = instruction
            self.road = road
            self.startIndex = startIndex
        }
    }

    public let summary: RouteSummary
    public let points: [GeoCoordinate]
    public let steps: [Step]

    public init(summary: RouteSummary, points: [GeoCoordinate], steps: [Step]) {
        self.summary = summary
        self.points = points
        self.steps = steps
    }
}

/// F-15b §47 item 10 (T-040s): where a route request goes. 高德 `/v3/direction/driving` at home, OSRM's route service
/// abroad; the guidance engine takes the source per request. Throws `AmapWebError`.
public protocol RouteSource: Sendable {
    /// `amap` or `osrm`, for the `route plan vendor=` record line (§47 item 9).
    var vendor: String { get }
    /// Shown on the guidance screen while this source's route is used (§47 item 8); nil when none is required.
    var attribution: String? { get }
    /// Up to 3 routes, the recommended one first.
    func routes(from: GeoCoordinate, to: GeoCoordinate, destinationName: String) async throws -> [PlannedRoute]
}
