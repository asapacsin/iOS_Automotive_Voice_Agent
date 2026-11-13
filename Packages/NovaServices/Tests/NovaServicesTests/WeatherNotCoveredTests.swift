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

@Suite("T-046r F-18 §29 Open-Meteo country codes")
struct WeatherNotCoveredTests {
    @Test("T-046r row 5: Open-Meteo geocoding without countryCode; results carry country_code")
    func countryCode() async throws {
        let t = WeatherBodyTransport(#"{"results":[{"name":"上海","latitude":31.22222,"longitude":121.45806,"country":"中国","country_code":"CN","population":24874500}]}"#)
        let places = try await OpenMeteoClient(transport: t).lookUp("Shanghai", country: nil)
        #expect(places.first?.countryCode == "CN" && places.first?.name == "上海")
        let url = t.urls.withLock { $0 }.first ?? ""
        #expect(url.contains("name=Shanghai") && !url.contains("countryCode") && url.contains("count=10") && url.contains("language=zh"))
    }
}
