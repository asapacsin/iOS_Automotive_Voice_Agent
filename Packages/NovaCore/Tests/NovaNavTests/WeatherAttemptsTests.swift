import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// A forecast fake that took two attempts, as `OpenMeteoClient` reports them (F-18 §30 item 4).
final class RetriedForecast: DailyForecastService, @unchecked Sendable {
    func dailyForecast(latitude: Double, longitude: Double) async throws -> DailyForecast {
        ForecastAttempts.current?.set(2)
        return DailyForecast(days: forecastDays())
    }
}

@Suite("T-046s F-18 §30 weather line attempts and ms")
struct WeatherAttemptsTests {
    @Test("T-046s F-18 §30 row 06: Open-Meteo and 高德 lines carry attempts= and ms=; no place, date, coordinate or temperature")
    func weatherLine() async throws {
        let log = LogBox()
        let location = FixedLocation()
        let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []), location: location,
                                       clock: ManualClock())
        let ex = LiveInfoExecutor(navigation: nav, weather: CountingWeather(), geocoder: FakeGeocoder(), location: location,
                                  now: { phoneNov6 }, zone: { shanghai }, amapLookup: RecordingLookup([zhuhaiCity]),
                                  forecastLookup: RecordingLookup([oslo]), forecast: RetriedForecast(),
                                  onWeather: { l in log.lines.withLock { $0.append(l) } })
        _ = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-12"]))
        _ = await ex.execute(weatherCall(["where": "珠海", "day": "tomorrow"]))
        let logs = log.lines.withLock { $0 }
        #expect(logs.count == 2)
        let meteo = try #require(logs.first { $0.source == "open-meteo" }), amap = try #require(logs.first { $0.source == "amap" })
        #expect(meteo.ok && meteo.attempts == 2 && amap.ok && amap.attempts == 1)
        for l in logs {
            let fields = l.line.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
            #expect(fields == ["weather", "source", "ok", "reason", "view", "lookup", "attempts", "ms"], "\(l.line)")
            #expect(l.ms >= 0 && l.line.hasSuffix(" ms=\(l.ms)"))
            for word in ["Oslo", "奥斯陆", "珠海", "2026", "11-12", "59.9", "10.7", "°"] { #expect(!l.line.contains(word)) }
        }
    }
}
