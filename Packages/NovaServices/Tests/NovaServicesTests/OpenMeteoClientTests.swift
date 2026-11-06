import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// F-18 §26 items 2, 4 (T-046o): the Open-Meteo requests and parsing, and 高德 geocoding with coordinates.
@Suite("T-046o F-18 §26 Open-Meteo client")
struct OpenMeteoClientTests {
    static let forecast = """
    {"daily":{"time":["2026-11-06","2026-11-07"],"weather_code":[3,61],"temperature_2m_max":[3.9,2.1],
    "temperature_2m_min":[0.7,-1.2],"precipitation_probability_max":[20,80],"precipitation_sum":[0.0,4.2],
    "wind_speed_10m_max":[12.5,20.1]}}
    """

    @Test("F-18 §26 row 04: the forecast request is item 4 with 2-decimal coordinates; days parsed in order")
    func forecastRequest() async throws {
        let t = WeatherBodyTransport(Self.forecast)
        let days = try await OpenMeteoClient(transport: t).dailyForecast(latitude: 59.91, longitude: 10.75).days
        #expect(t.urls.withLock { $0 } == ["https://api.open-meteo.com/v1/forecast?latitude=59.91&longitude=10.75&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max&timezone=auto&forecast_days=16"])
        #expect(days.map(\.time) == ["2026-11-06", "2026-11-07"])
        #expect(days[1] == DailyForecastDay(time: "2026-11-07", weatherCode: 61, tempMax: 2.1, tempMin: -1.2, rainChance: 80,
                                           rainMm: 4.2, windMaxKmh: 20.1))
    }

    @Test("F-18 §26 row 06: the geocoding request is item 2; results carry name, country and population")
    func geocoding() async throws {
        let t = WeatherBodyTransport("""
        {"results":[{"name":"仙台市","latitude":38.26,"longitude":140.87,"country":"日本","population":1063103},
        {"name":"x","latitude":1,"longitude":2,"country":"日本"}]}
        """)
        let places = try await OpenMeteoClient(transport: t).lookUp("Sendai", country: "JP")
        #expect(t.urls.withLock { $0 } == ["https://geocoding-api.open-meteo.com/v1/search?name=Sendai&countryCode=JP&count=10&language=zh&format=json"])
        #expect(places.count == 2 && places[0].name == "仙台市" && places[0].population == 1_063_103 && places[1].population == nil)
        let none = try await OpenMeteoClient(transport: WeatherBodyTransport("{\"generationtime_ms\":0.1}")).lookUp("Nowhere", country: "JP")
        #expect(none.isEmpty)
    }

    @Test("F-18 §26 row 05: 高德 geocode returns location, formatted_address, city and adcode")
    func amapGeocode() async throws {
        let t = WeatherBodyTransport("""
        {"status":"1","infocode":"10000","geocodes":[{"formatted_address":"福建省厦门市湖里区","province":"福建省","city":"厦门市",
        "adcode":"350206","location":"118.146,24.512"}]}
        """)
        let found = try await AmapWebClient(key: { "k" }, transport: t).lookUp("奥斯陆", country: nil)
        #expect(found == [LookedUpPlace(name: "厦门市", coordinate: GeoCoordinate(latitude: 24.512, longitude: 118.146, datum: .gcj02),
                                        formatted: "福建省厦门市湖里区", adcode: "350206")])
    }
}
