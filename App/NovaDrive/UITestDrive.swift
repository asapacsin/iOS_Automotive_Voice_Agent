import NovaKit
import NovaNav
import NovaPorts

/// T-048: launch argument for the simulator drive test. No keys, no microphone, no network: a scripted
/// place search and route engine behind the real `NavigationController`, so the 驾驶 screen runs
/// search → pick → route → navigate exactly as with Amap.
enum UITestDrive {
    static let argument = "-uitest-scripted-drive"
    static var enabled: Bool { CommandLine.arguments.contains(argument) }

    static let places = [
        Place(id: "P1", name: "珠海站", address: "香洲区友谊路",
              coordinate: GeoCoordinate(latitude: 22.2152, longitude: 113.5497, datum: .gcj02), distanceMeters: 6_200),
        Place(id: "P2", name: "珠海北站", address: "香洲区金鼎",
              coordinate: GeoCoordinate(latitude: 22.3846, longitude: 113.5486, datum: .gcj02), distanceMeters: 15_800),
    ]

    static let routes = [
        RouteSummary(id: RouteID(1), lengthMeters: 7_100, durationSeconds: 1_080, tollYuan: 0, trafficLights: 9, label: "推荐"),
        RouteSummary(id: RouteID(2), lengthMeters: 8_300, durationSeconds: 1_260, tollYuan: 0, trafficLights: 6, label: "红绿灯少"),
    ]
}

struct ScriptedPlaceSearch: PlaceSearch {
    func text(_ keywords: String, city: String?) async throws -> [Place] { UITestDrive.places }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        UITestDrive.places
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { UITestDrive.places.first { $0.id == id } }
}

/// Answers like the SDK: routes after a calculation, started after a start, stopped after a stop.
final class ScriptedRouteEngine: NaviEngine, Sendable {
    let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream() }

    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .routesReady(UITestDrive.routes)))
    }

    func selectRoute(_ id: RouteID, generation: Generation) async {}

    func start(_ mode: NaviMode, generation: Generation) async {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStarted))
    }

    func stop(generation: Generation) async {
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStopped))
    }
}
