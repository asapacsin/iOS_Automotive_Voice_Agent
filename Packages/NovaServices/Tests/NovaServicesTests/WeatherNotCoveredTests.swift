import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// Every request times out.
struct TimeoutTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) { throw URLError(.timedOut) }
}

@Suite("T-046r F-18 §29 高德 empty answers and Open-Meteo country codes")
struct WeatherNotCoveredTests {
    @Test("T-046r row 3: status 1 with empty lives or empty forecasts is WeatherNotCovered, not a failure")
    func empty() async {
        let live = AmapWebClient(key: { "k" }, transport: WeatherBodyTransport(#"{"status":"1","count":"0","lives":[]}"#))
        await #expect(throws: WeatherNotCovered(adcode: "440400")) {
            try await live.weather(adcode: "440400", day: WeatherDay(offset: 0, date: "2026-11-06", live: true))
        }
        let cast = AmapWebClient(key: { "k" }, transport: WeatherBodyTransport(#"{"status":"1","forecasts":[]}"#))
        await #expect(throws: WeatherNotCovered(adcode: "440400")) {
            try await cast.weather(adcode: "440400", day: WeatherDay(offset: 1, date: "2026-11-07"))
        }
        let noCasts = AmapWebClient(key: { "k" }, transport: WeatherBodyTransport(#"{"status":"1","forecasts":[{"city":"澳门","casts":[]}]}"#))
        await #expect(throws: WeatherNotCovered(adcode: "820000")) {
            try await noCasts.weather(adcode: "820000", day: WeatherDay(offset: 1, date: "2026-11-07"))
        }
    }

    @Test("T-046r row 4: a timeout is still AmapWebError.timeout")
    func timeout() async {
        let client = AmapWebClient(key: { "k" }, transport: TimeoutTransport())
        await #expect(throws: AmapWebError.timeout) {
            try await client.weather(adcode: "440400", day: WeatherDay(offset: 0, date: "2026-11-06", live: true))
        }
    }

    @Test("T-046r row 5: Open-Meteo geocoding without countryCode; results carry country_code")
    func countryCode() async throws {
        let t = WeatherBodyTransport(#"{"results":[{"name":"上海","latitude":31.22222,"longitude":121.45806,"country":"中国","country_code":"CN","population":24874500}]}"#)
        let places = try await OpenMeteoClient(transport: t).lookUp("Shanghai", country: nil)
        #expect(places.first?.countryCode == "CN" && places.first?.name == "上海")
        let url = t.urls.withLock { $0 }.first ?? ""
        #expect(url.contains("name=Shanghai") && !url.contains("countryCode") && url.contains("count=10") && url.contains("language=zh"))
    }
}
