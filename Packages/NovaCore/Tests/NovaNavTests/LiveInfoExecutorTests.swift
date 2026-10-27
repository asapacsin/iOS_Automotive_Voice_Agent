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
    var error: AmapWebError?

    func adcode(at coordinate: GeoCoordinate) async throws -> String? { "440402" }

    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        if let error { throw error }
        return PlaceAddress(formatted: "广东省珠海市香洲区情侣中路", district: "香洲区", road: "情侣中路")
    }
}

struct DeniedLocation: LocationProvider {
    func latestFix() async -> LocationFix? { nil }
    func authorization() async -> LocationAuthorization { .denied }
}

struct FixedLocation: LocationProvider {
    func latestFix() async -> LocationFix? {
        LocationFix(coordinate: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02),
                    horizontalAccuracyMeters: 10, timestamp: NovaInstant(milliseconds: 0))
    }
}

@Suite("T-041 F-18 live info")
struct LiveInfoExecutorTests {
    func executor(_ weather: FakeWeather?, location: any LocationProvider = FixedLocation(),
                  geocoder: FakeGeocoder = FakeGeocoder()) async -> LiveInfoExecutor {
        let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                       location: location, clock: ManualClock())
        return LiveInfoExecutor(navigation: nav, weather: weather, geocoder: geocoder, location: location)
    }

    let here: [String: JSONValue] = ["kind": "current_location"]

    @Test("F-16a 「我现在在哪？」 answers the regeo address, province trimmed, source device")
    func currentLocation() async {
        let r = await ask(await executor(FakeWeather()), here)
        #expect(r.ok && r.data["address"] == "珠海市香洲区情侣中路" && r.data["road"] == "情侣中路")
        #expect(r.data["source"] == "device")
    }

    @Test("F-16a demo source is named as such")
    func currentLocationDemo() async {
        let demo = SwitchableLocationProvider(device: NoLocation(), demo: FixedLocation(), useDevice: { false })
        let r = await ask(await executor(FakeWeather(), location: demo), here)
        #expect(r.ok && r.data["source"] == "demo" && r.data["next"]?.stringValue?.contains("演示起点") == true)
    }

    @Test("F-16a §8: denied, no fix, regeo failure and key problems each name their cause")
    func currentLocationFailures() async {
        #expect(await ask(await executor(FakeWeather(), location: DeniedLocation()), here).code == .locationPermissionDenied)
        #expect(await ask(await executor(FakeWeather(), location: DeniedLocation())).code == .locationPermissionDenied)
        #expect(await ask(await executor(FakeWeather(), location: NoLocation()), here).code == .noLocation)
        #expect(await ask(await executor(FakeWeather(), geocoder: FakeGeocoder(error: .timeout)), here).code == .noLocation)
        #expect(await ask(await executor(FakeWeather(), geocoder: FakeGeocoder(error: .keyRejected)), here).code
            == .amapWebKeyMissing)
        let r = await ask(await executor(FakeWeather(), location: DeniedLocation()), here)
        #expect(r.advice != nil && r.data["address"] == nil)
    }

    @Test("F-16a switchable source follows the setting per request")
    func switchable() async {
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let p = SwitchableLocationProvider(device: DeniedLocation(), demo: FixedLocation(), useDevice: { flag.on })
        #expect(p.source == .device)
        #expect(await p.authorization() == .denied)
        #expect(await p.latestFix() == nil)
        flag.on = false
        #expect(p.source == .demo)
        #expect(await p.authorization() == .authorized)
        #expect(await p.latestFix() != nil)
    }

    @Test("trimProvince keeps addresses without a province or city")
    func trim() {
        #expect(LiveInfoExecutor.trimProvince("广东省珠海市香洲区") == "珠海市香洲区")
        #expect(LiveInfoExecutor.trimProvince("北京市朝阳区") == "北京市朝阳区")
        #expect(LiveInfoExecutor.trimProvince("广西壮族自治区南宁市青秀区") == "南宁市青秀区")
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
