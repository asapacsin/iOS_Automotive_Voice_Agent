import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

struct FakeWeather: WeatherService {
    var error: AmapWebError?

    func weather(adcode: String, forecast: Bool) async throws -> WeatherReport {
        if let error { throw error }
        return WeatherReport(adcode: adcode, summary: .object(["text": "晴", "temperature": "26"]))
    }
}

struct FakeGeocoder: ReverseGeocoder {
    func adcode(at coordinate: GeoCoordinate) async throws -> String? { "440402" }
}

struct FixedLocation: LocationProvider {
    func latestFix() async -> LocationFix? {
        LocationFix(coordinate: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02),
                    horizontalAccuracyMeters: 10, timestamp: NovaInstant(milliseconds: 0))
    }
}

@Suite("T-041 F-18 live info")
struct LiveInfoExecutorTests {
    func executor(_ weather: FakeWeather?, location: any LocationProvider = FixedLocation()) async -> LiveInfoExecutor {
        let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                       location: location, clock: ManualClock())
        return LiveInfoExecutor(navigation: nav, weather: weather, geocoder: FakeGeocoder(), location: location)
    }

    func ask(_ e: LiveInfoExecutor, _ args: [String: JSONValue] = ["kind": "weather"]) async -> ToolResult {
        await e.execute(tool("query_live_info", args))
    }

    @Test("weather here answers only from the returned data")
    func weatherHere() async {
        let r = await ask(await executor(FakeWeather()))
        #expect(r.ok && r.data["weather"]?["text"] == "晴")
    }

    @Test("F-18 §8: each failure names its real cause")
    func codes() async {
        #expect(await ask(await executor(nil)).code == .amapWebKeyMissing)
        #expect(await ask(await executor(FakeWeather(error: .keyMissing))).code == .amapWebKeyMissing)
        #expect(await ask(await executor(FakeWeather(error: .keyRejected))).code == .amapWebKeyMissing)
        #expect(await ask(await executor(FakeWeather(error: .quota))).code == .liveInfoQuota)
        #expect(await ask(await executor(FakeWeather(), location: NoLocation())).code == .noLocation)
        #expect(await ask(await executor(FakeWeather()), ["kind": "weather", "where": "destination"]).code == .noDestination)
    }

    @Test("F-18 timeout → honest LIVE_INFO_UNAVAILABLE with advice, nothing claimed")
    func timeout() async {
        let r = await ask(await executor(FakeWeather(error: .timeout)))
        #expect(!r.ok && r.code == .liveInfoUnavailable && r.advice != nil && r.data["weather"] == nil)
    }

    @Test("route_traffic while not navigating is refused")
    func notNavigating() async {
        let r = await ask(await executor(FakeWeather()), ["kind": "route_traffic"])
        #expect(!r.ok)
    }
}
