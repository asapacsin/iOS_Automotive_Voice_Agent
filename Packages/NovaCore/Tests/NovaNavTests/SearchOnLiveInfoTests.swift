import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaNav

final class CountingWeather: WeatherService, @unchecked Sendable {
    let calls = Mutex(0)
    func weather(adcode: String, forecast: Bool) async throws -> WeatherReport {
        calls.withLock { $0 += 1 }
        return try await FakeWeather().weather(adcode: adcode, forecast: forecast)
    }
}

@Suite("T-046d F-18 §16 item 9 query_live_info with search on")
struct SearchOnLiveInfoTests {
    @Test("Row 9: kind=weather or place_details with the setting on: LIVE_INFO_UNAVAILABLE, no Amap call; off unchanged")
    func removedKinds() async {
        let weather = CountingWeather()
        let location = FixedLocation()
        let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                       location: location, clock: ManualClock())
        let on = LiveInfoExecutor(webSearch: true, navigation: nav, weather: weather, geocoder: FakeGeocoder(), location: location)
        for args: [String: JSONValue] in [["kind": "weather", "where": "上海", "day": "tomorrow"],
                                          ["kind": "place_details", "target": "destination"]] {
            let r = await on.execute(ToolCall(id: CallID("c")!, name: "query_live_info", arguments: .object(args)))
            #expect(r.code == .liveInfoUnavailable)
        }
        #expect(weather.calls.withLock { $0 } == 0)
        let time = await on.execute(ToolCall(id: CallID("t")!, name: "query_live_info", arguments: ["kind": "current_time"]))
        #expect(time.ok)
        let off = LiveInfoExecutor(navigation: nav, weather: weather, geocoder: FakeGeocoder(), location: location)
        _ = await off.execute(ToolCall(id: CallID("w")!, name: "query_live_info", arguments: ["kind": "weather", "where": "上海"]))
        #expect(weather.calls.withLock { $0 } == 1)
    }
}
