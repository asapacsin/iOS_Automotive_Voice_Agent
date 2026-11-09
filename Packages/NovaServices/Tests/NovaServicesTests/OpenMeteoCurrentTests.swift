import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// F-18 §27 items 1-2 (T-046p, in T-046q): the temperature now in the same Open-Meteo call.
@Suite("T-046q F-18 §28 (T-046p §27) Open-Meteo current block")
struct OpenMeteoCurrentTests {
    static let daily = """
    "daily":{"time":["2026-11-06","2026-11-07"],"weather_code":[3,61],"temperature_2m_max":[3.9,2.1],
    "temperature_2m_min":[0.7,-1.2],"precipitation_probability_max":[20,80],"precipitation_sum":[0.0,4.2],
    "wind_speed_10m_max":[12.5,20.1]}
    """

    @Test("T-046q F-18 §28 (T-046p §27) row 1: the forecast URL has current= before daily=, one call")
    func row1() async throws {
        let t = WeatherBodyTransport("{\(Self.daily)}")
        _ = try await OpenMeteoClient(transport: t).dailyForecast(latitude: 59.91, longitude: 10.75)
        #expect(t.urls.withLock { $0 } == ["https://api.open-meteo.com/v1/forecast?latitude=59.91&longitude=10.75&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m&hourly=temperature_2m,weather_code,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max&timezone=auto&forecast_days=16"])
    }

    @Test("F-18 §27 row 2: the current block is read beside the days")
    func row2() async throws {
        let t = WeatherBodyTransport("""
        {"current":{"time":"2026-11-06T06:00","interval":900,"temperature_2m":0.9,"apparent_temperature":-2.2,
        "relative_humidity_2m":81,"weather_code":1,"wind_speed_10m":4.3},\(Self.daily)}
        """)
        let f = try await OpenMeteoClient(transport: t).dailyForecast(latitude: 59.91, longitude: 10.75)
        #expect(f.current == CurrentWeather(time: "2026-11-06T06:00", temperature: 0.9, feelsLike: -2.2, humidity: 81,
                                            weatherCode: 1, windKmh: 4.3))
        #expect(f.days.map(\.time) == ["2026-11-06", "2026-11-07"])
    }

    @Test("F-18 §27 row 3: no current, or current without temperature_2m, is nil with the days, no error")
    func row3() async throws {
        let none = try await OpenMeteoClient(transport: WeatherBodyTransport("{\(Self.daily)}"))
            .dailyForecast(latitude: 59.91, longitude: 10.75)
        #expect(none.current == nil && none.days.count == 2)
        let partial = try await OpenMeteoClient(transport: WeatherBodyTransport("""
        {"current":{"time":"2026-11-06T06:00","apparent_temperature":-2.2,"relative_humidity_2m":81},\(Self.daily)}
        """)).dailyForecast(latitude: 59.91, longitude: 10.75)
        #expect(partial.current == nil && partial.days.count == 2)
    }
}
