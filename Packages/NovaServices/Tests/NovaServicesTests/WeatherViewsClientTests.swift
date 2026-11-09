import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// F-18 §28 items 2, 3, 5 (T-046q): 高德's live report with its time, today's cast with night weather, and the hours.
@Suite("T-046q F-18 §28 weather clients")
struct WeatherViewsClientTests {
    @Test("T-046q F-18 §28 row 1: 高德 live is extensions=base with time from reporttime; today's cast is all with weather_night")
    func amap() async throws {
        let base = WeatherBodyTransport("""
        {"status":"1","infocode":"10000","lives":[{"city":"香洲区","weather":"多云","temperature":"22","winddirection":"东北",
        "windpower":"6","humidity":"54","reporttime":"2026-11-09 18:00:00"}]}
        """)
        let live = try await AmapWebClient(key: { "k" }, transport: base)
            .weather(adcode: "440402", day: WeatherDay(offset: 0, date: "2026-11-09", live: true))
        #expect(live.summary["time"] == "18:00" && live.summary["temperature_c"] == "22" && live.summary["wind"] == "东北风6级")
        #expect(live.summary["day"] == "now" && base.urls.withLock { $0 }.allSatisfy { $0.contains("extensions=base") })
        let all = WeatherBodyTransport("""
        {"status":"1","infocode":"10000","forecasts":[{"city":"香洲区","casts":[
        {"date":"2026-11-09","dayweather":"多云","nightweather":"晴","daytemp":"24","nighttemp":"18"}]}]}
        """)
        let cast = try await AmapWebClient(key: { "k" }, transport: all)
            .weather(adcode: "440402", day: WeatherDay(offset: 0, date: "2026-11-09"))
        #expect(cast.summary["weather_day"] == "多云" && cast.summary["weather_night"] == "晴" && cast.summary["temp_high"] == "24")
        #expect(cast.summary["temperature_c"] == nil && all.urls.withLock { $0 }.allSatisfy { $0.contains("extensions=all") })
    }

    @Test("T-046q F-18 §28 row 8: one Open-Meteo URL with current, hourly, daily in order; hours and offset read; none is []")
    func openMeteo() async throws {
        let t = WeatherBodyTransport("""
        {"utc_offset_seconds":3600,"hourly":{"time":["2026-11-09T00:00","2026-11-09T01:00"],"temperature_2m":[1.4,0.6],
        "weather_code":[3,61],"precipitation_probability":[10,55]},"daily":{"time":["2026-11-09"],"weather_code":[3]}}
        """)
        let f = try await OpenMeteoClient(transport: t).dailyForecast(latitude: 59.91, longitude: 10.75)
        let url = try #require(t.urls.withLock { $0 }.first)
        let c = try #require(url.range(of: "&current=")), h = try #require(url.range(of: "&hourly=temperature_2m,weather_code,precipitation_probability"))
        let d = try #require(url.range(of: "&daily=")), z = try #require(url.range(of: "&timezone=auto&forecast_days=16"))
        #expect(c.lowerBound < h.lowerBound && h.lowerBound < d.lowerBound && d.lowerBound < z.lowerBound)
        #expect(f.hours == [HourlyForecast(time: "2026-11-09T00:00", weatherCode: 3, temperature: 1.4, rainChance: 10),
                            HourlyForecast(time: "2026-11-09T01:00", weatherCode: 61, temperature: 0.6, rainChance: 55)])
        #expect(f.utcOffsetSeconds == 3600)
        let none = try await OpenMeteoClient(transport: WeatherBodyTransport(#"{"daily":{"time":["2026-11-09"]}}"#))
            .dailyForecast(latitude: 59.91, longitude: 10.75)
        #expect(none.hours.isEmpty && none.current == nil)
    }
}
