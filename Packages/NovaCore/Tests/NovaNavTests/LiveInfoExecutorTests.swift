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

/// A fix with a chosen accuracy and timestamp (the test clock starts at 0).
struct AgedLocation: LocationProvider {
    var accuracy: Double = 10
    var timestamp = NovaInstant(milliseconds: 0)

    func latestFix() async -> LocationFix? {
        LocationFix(coordinate: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .wgs84),
                    horizontalAccuracyMeters: accuracy, timestamp: timestamp)
    }
}

struct FailingAdcodeGeocoder: ReverseGeocoder {
    var error: AmapWebError

    func adcode(at coordinate: GeoCoordinate) async throws -> String? { throw error }
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? { nil }
}

@Suite("T-041 F-18 live info")
struct LiveInfoExecutorTests {
    func executor(_ weather: FakeWeather?, location: any LocationProvider = FixedLocation(),
                  geocoder: any ReverseGeocoder = FakeGeocoder(), clock: ManualClock = ManualClock()) async
        -> LiveInfoExecutor {
        let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                       location: location, clock: clock)
        return LiveInfoExecutor(navigation: nav, weather: weather, geocoder: geocoder, location: location)
    }

    let here: [String: JSONValue] = ["kind": "current_location"]

    @Test("F-16a 「我现在在哪？」 answers the regeo address, province trimmed, source device")
    func currentLocation() async {
        let r = await ask(await executor(FakeWeather()), here)
        #expect(r.ok && r.data["address"] == "珠海市香洲区情侣中路" && r.data["road"] == "情侣中路")
        #expect(r.data["source"] == "device")
    }

    @Test("F-16a §4 result shape: address, district, road, accuracy_m, source, fix_age_s")
    func currentLocationShape() async {
        let clock = ManualClock(start: NovaInstant(milliseconds: 12_000))
        let r = await ask(await executor(FakeWeather(), location: AgedLocation(accuracy: 35.4), clock: clock), here)
        #expect(r.ok)
        #expect(r.data["district"] == "香洲区")
        #expect(r.data["accuracy_m"] == .int(35))
        #expect(r.data["fix_age_s"] == .int(12))
        #expect(r.data["source"] == "device")
        #expect(r.data["address"] != nil && r.data["road"] != nil && r.data["next"] != nil)
    }

    @Test("F-16a §4: a stale (> 10 min) or coarse (> 2000 m) fix is refused as NO_LOCATION")
    func currentLocationStaleOrCoarse() async {
        let clock = ManualClock(start: NovaInstant(milliseconds: 11 * 60_000))
        #expect(await ask(await executor(FakeWeather(), location: AgedLocation(), clock: clock), here).code
            == .noLocation)
        #expect(await ask(await executor(FakeWeather(), location: AgedLocation(accuracy: 2500)), here).code
            == .noLocation)
    }

    @Test("F-18 §8: weather here with a failed regeo is NO_LOCATION, a rejected key stays a key problem")
    func weatherHereRegeoFailure() async {
        #expect(await ask(await executor(FakeWeather(), geocoder: FailingAdcodeGeocoder(error: .timeout))).code
            == .noLocation)
        #expect(await ask(await executor(FakeWeather(), geocoder: FailingAdcodeGeocoder(error: .failed))).code
            == .noLocation)
        #expect(await ask(await executor(FakeWeather(), geocoder: FailingAdcodeGeocoder(error: .keyRejected))).code
            == .amapWebKeyMissing)
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
        // Municipality named twice: one name kept.
        #expect(LiveInfoExecutor.trimProvince("北京市北京市朝阳区") == "北京市朝阳区")
        // No city right after the province: left as written.
        #expect(LiveInfoExecutor.trimProvince("广东省香洲区情侣路市场") == "广东省香洲区情侣路市场")
        #expect(LiveInfoExecutor.trimProvince("珠海市香洲区省道") == "珠海市香洲区省道")
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

/// A device source with a live stream (F-16b T-044b).
struct StreamingLocation: LocationProvider, LocationUpdates {
    let state = LocationFixState(clock: ManualClock(), permission: .authorized)
    func latestFix() async -> LocationFix? { state.latest }
    func updates() -> AsyncStream<LocationFix> { state.updates() }
}

@Suite("T-044b F-16b switchable updates")
struct SwitchableUpdatesTests {
    @Test("F-16b updates: the switchable source streams the device's fixes, or the demo fix once")
    func switchable() async {
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let device = StreamingLocation()
        let p = SwitchableLocationProvider(device: device, demo: FixedLocation(), useDevice: { flag.on })
        var live = p.updates().makeAsyncIterator()
        let moved = LocationFix(coordinate: GeoCoordinate(latitude: 22.3, longitude: 113.6, datum: .wgs84),
                                horizontalAccuracyMeters: 5, timestamp: .zero, speedMetersPerSecond: 3, courseDegrees: 90)
        device.state.receive(moved)
        #expect(await live.next() == moved)
        // The source is read per call: after the switch a new subscription gets the demo point, then ends.
        flag.on = false
        var demo = p.updates().makeAsyncIterator()
        #expect(await demo.next() == (await FixedLocation().latestFix()))
        #expect(await demo.next() == nil)
        let none = SwitchableLocationProvider(device: NoLocation(), demo: FixedLocation(), useDevice: { true })
        var empty = none.updates().makeAsyncIterator()
        #expect(await empty.next() == nil)
    }
}
