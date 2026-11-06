import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// Answers every request with one body and records the query.
final class WeatherBodyTransport: HTTPTransport, @unchecked Sendable {
    let body: String
    let urls = Mutex<[String]>([])
    init(_ body: String) { self.body = body }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url?.absoluteString ?? "") }
        return (200, Data(body.utf8))
    }
}

@Suite("T-046k F-18 §23 Amap forecast by date")
struct AmapWeatherTests {
    static let shuffled = """
    {"status":"1","infocode":"10000","forecasts":[{"city":"横琴","casts":[
    {"date":"2026-11-07","dayweather":"小雨","daytemp":"21","nighttemp":"16"},
    {"date":"2026-11-05","dayweather":"晴","daytemp":"26","nighttemp":"19"},
    {"date":"2026-11-06","dayweather":"多云","daytemp":"24","nighttemp":"18"}]}]}
    """

    @Test("F-18 §23 row 3: casts in shuffled order are picked by date, not position; a missing date throws")
    func byDate() async throws {
        let transport = WeatherBodyTransport(Self.shuffled)
        let client = AmapWebClient(key: { "k" }, transport: transport)
        let report = try await client.weather(adcode: "440404", day: WeatherDay(offset: 2, date: "2026-11-07"))
        #expect(report.summary["date"] == "2026-11-07" && report.summary["weather_day"] == "小雨")
        #expect(report.summary["day"] == "day_after")
        let tomorrow = try await client.weather(adcode: "440404", day: WeatherDay(offset: 1, date: "2026-11-06"))
        #expect(tomorrow.summary["weather_day"] == "多云")
        await #expect(throws: WeatherForecastMissing(date: "2026-11-08")) {
            try await client.weather(adcode: "440404", day: WeatherDay(offset: 3, date: "2026-11-08"))
        }
        #expect(transport.urls.withLock { $0 }.allSatisfy { $0.contains("extensions=all") })
    }
}
