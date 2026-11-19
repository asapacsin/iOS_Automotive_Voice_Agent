import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// Answers by path: the body for the first key the URL path contains; records URL and API key header.
final class QWeatherTransport: HTTPTransport, @unchecked Sendable {
    var bodies: [String: (Int, String)]
    var error: URLError.Code?
    let urls = Mutex<[String]>([])
    let keys = Mutex<[String?]>([])
    init(_ bodies: [String: (Int, String)] = [:], error: URLError.Code? = nil) { self.bodies = bodies; self.error = error }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url?.absoluteString ?? "") }
        keys.withLock { $0.append(request.value(forHTTPHeaderField: "X-QW-Api-Key")) }
        if let error { throw URLError(error) }
        let path = request.url?.path ?? ""
        guard let hit = bodies.first(where: { path.contains($0.key) })?.value else { return (404, Data()) }
        return (hit.0, Data(hit.1.utf8))
    }
}

@Suite("T-046t F-18 §31 和风天气 client")
struct QWeatherClientTests {
    static let current = """
    {"condition":{"text":"少云","code":"102"},"temperature":{"value":31.71,"unit":"°C"},"feelsLike":{"value":33.64,"unit":"°C"},
    "humidity":0.69,"wind":{"direction":{"degree":226,"compass":"sw"},"speed":{"value":4.75,"unit":"m/s"},"scale":3}}
    """
    static func day(_ date: String, _ high: Double) -> String {
        """
        {"forecastStartTime":"\(date)T07:00+08:00","temperatureMax":{"value":\(high),"unit":"°C"},"temperatureMin":{"value":21.2,"unit":"°C"},
        "daytime":{"condition":{"text":"小雨","code":"305"},"wind":{"speed":{"value":5,"unit":"m/s"}},
          "precipitation":{"amount":{"value":0.75,"unit":"mm"},"probability":0.64,"type":"rain"}},
        "nighttime":{"condition":{"text":"多云","code":"151"},"wind":{"speed":{"value":3,"unit":"m/s"}},
          "precipitation":{"amount":{"value":0.25,"unit":"mm"},"probability":0.2,"type":"rain"}}}
        """
    }
    static let daily = "{\"days\":[\(day("2026-11-13", 29.94)),\(day("2026-11-14", 27.1))]}"
    static let hourly = """
    {"hours":[{"forecastTime":"2026-11-13T15:00+09:00","condition":{"text":"阴","code":"104"},"temperature":{"value":12.6,"unit":"°C"},
    "precipitation":{"probability":0.31}},{"forecastTime":"2026-11-13T16:00+09:00","condition":{"text":"小雨","code":"305"},
    "temperature":{"value":11.4,"unit":"°C"},"precipitation":{"probability":0.6}}]}
    """
    static let lookup = """
    {"code":"200","location":[{"name":"东京","id":"B00","lat":"35.68","lon":"139.76","adm1":"东京都","adm2":"东京","country":"日本","tz":"Asia/Tokyo","rank":"11"}]}
    """

    func client(_ t: QWeatherTransport, host: String? = "https://abc123.qweatherapi.com/", key: String? = "k1") -> QWeatherClient {
        QWeatherClient(host: { host }, key: { key }, transport: t)
    }

    @Test("T-046t F-18 §31 row 01: now sends current and daily?days=1 at lat/lon, localTime=true&lang=zh, X-QW-Api-Key; host normalised")
    func now() async throws {
        let t = QWeatherTransport(["/current/": (200, Self.current), "/daily/": (200, Self.daily)])
        let f = try await client(t).forecast(latitude: 22.27, longitude: 113.58, request: .now)
        #expect(Set(t.urls.withLock { $0 }) == ["https://abc123.qweatherapi.com/weather/v1/current/22.27/113.58?localTime=true&lang=zh",
                                                "https://abc123.qweatherapi.com/weather/v1/daily/22.27/113.58?days=1&localTime=true&lang=zh"])
        #expect(t.keys.withLock { $0 } == ["k1", "k1"])
        let c = try #require(f.current)
        #expect(c.text == "少云" && c.temperature == 31.71 && c.feelsLike == 33.64 && c.humidity == 69 && c.time == "")
        #expect(abs((c.windKmh ?? 0) - 17.1) < 0.01)
        #expect(f.days.first?.time == "2026-11-13")
    }

    @Test("T-046t F-18 §31 row 02: daily?days=10 parsed: date of forecastStartTime, day and night words, larger chance ×100, mm summed")
    func daily() async throws {
        let t = QWeatherTransport(["/daily/": (200, Self.daily)])
        let f = try await client(t).forecast(latitude: 22.27, longitude: 113.58, request: .day)
        #expect(t.urls.withLock { $0 } == ["https://abc123.qweatherapi.com/weather/v1/daily/22.27/113.58?days=10&localTime=true&lang=zh"])
        #expect(f.days.map(\.time) == ["2026-11-13", "2026-11-14"])
        let d = f.days[0]
        #expect(d.dayText == "小雨" && d.nightText == "多云" && d.tempMax == 29.94 && d.tempMin == 21.2 && d.rainChance == 64)
        #expect(d.rainMm == 1.0 && d.windMaxKmh == 18)
    }

    @Test("T-046t F-18 §31 row 03: hourly?hours=240: times on the place clock, words, chance ×100, the offset read")
    func hourly() async throws {
        let t = QWeatherTransport(["/hourly/": (200, Self.hourly)])
        let f = try await client(t).forecast(latitude: 35.68, longitude: 139.76, request: .hours)
        #expect(t.urls.withLock { $0 } == ["https://abc123.qweatherapi.com/weather/v1/hourly/35.68/139.76?hours=240&localTime=true&lang=zh"])
        #expect(f.hours.map(\.time) == ["2026-11-13T15:00", "2026-11-13T16:00"] && f.utcOffsetSeconds == 32400)
        #expect(f.hours[1] == HourlyForecast(time: "2026-11-13T16:00", weatherCode: nil, temperature: 11.4, rainChance: 60, text: "小雨"))
        #expect(QWeatherClient.utcOffset("2026-11-13T15:00Z") == nil && QWeatherClient.utcOffset("2026-11-13T15:00-03:30") == -12600)
    }

    @Test("T-046t F-18 §31 row 04: lookup location, range lower case, number=1, lang=zh; a repeat sends no lookup; no range without country")
    func lookup() async throws {
        let t = QWeatherTransport(["/city/lookup": (200, Self.lookup)])
        let c = client(t)
        let places = try await c.lookUp("Tokyo", country: "JP")
        _ = try await c.lookUp("Tokyo", country: "JP")
        #expect(t.urls.withLock { $0 } == ["https://abc123.qweatherapi.com/geo/v2/city/lookup?location=Tokyo&range=jp&number=1&lang=zh"])
        #expect(places.first?.name == "东京" && places.first?.country == "日本" && places.first?.coordinate?.latitude == 35.68)
        _ = try await c.lookUp("Macau", country: nil)
        #expect(t.urls.withLock { $0.last } == "https://abc123.qweatherapi.com/geo/v2/city/lookup?location=Macau&number=1&lang=zh")
    }

    @Test("T-046t F-18 §31 row 05: an empty location list and HTTP 400 are not-found")
    func notFound() async {
        let empty = QWeatherTransport(["/city/lookup": (200, "{\"code\":\"200\",\"location\":[]}")])
        await #expect(throws: QWeatherError.notFound) { try await client(empty).lookUp("Nowhere", country: "JP") }
        let bad = QWeatherTransport(["/city/lookup": (400, "{\"error\":{\"title\":\"NO SUCH LOCATION\"}}")])
        await #expect(throws: QWeatherError.notFound) { try await client(bad).lookUp("Nowhere", country: nil) }
    }

    @Test("T-046t F-18 §31 row 06: no host or key, timeout, 401, 429, 503 and unreadable answers are their reasons")
    func errors() async {
        let ok = QWeatherTransport(["/daily/": (200, Self.daily)])
        await #expect(throws: QWeatherError.noKey) { try await client(ok, key: nil).forecast(latitude: 1, longitude: 2, request: .day) }
        await #expect(throws: QWeatherError.noKey) { try await client(ok, host: "").forecast(latitude: 1, longitude: 2, request: .day) }
        #expect(ok.urls.withLock { $0.isEmpty })
        await #expect(throws: QWeatherError.timeout) {
            try await client(QWeatherTransport(error: .timedOut)).forecast(latitude: 1, longitude: 2, request: .day)
        }
        for status in [401, 429, 503] {
            await #expect(throws: QWeatherError.http(status)) {
                try await client(QWeatherTransport(["/daily/": (status, "{}")])).forecast(latitude: 1, longitude: 2, request: .day)
            }
        }
        await #expect(throws: QWeatherError.parse) {
            try await client(QWeatherTransport(["/daily/": (200, "<html>")])).forecast(latitude: 1, longitude: 2, request: .day)
        }
        // A temperature not in °C is a parse failure.
        let fahrenheit = Self.daily.replacingOccurrences(of: "\"°C\"", with: "\"°F\"")
        await #expect(throws: QWeatherError.parse) {
            try await client(QWeatherTransport(["/daily/": (200, fahrenheit)])).forecast(latitude: 1, longitude: 2, request: .day)
        }
        #expect(QWeatherError.http(429).reason == "http429" && QWeatherError.noKey.reason == "nokey" && QWeatherError.parse.reason == "parse")
    }

    @Test("T-046t F-18 §31 item 10: a weather answer is reused for 10 minutes, then asked again")
    func cache() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let t = QWeatherTransport(["/daily/": (200, Self.daily)])
        let c = QWeatherClient(host: { "h.qweatherapi.com" }, key: { "k" }, transport: t, now: { clock.now })
        _ = try await c.forecast(latitude: 1, longitude: 2, request: .day)
        clock.now = Date(timeIntervalSince1970: 599)
        _ = try await c.forecast(latitude: 1, longitude: 2, request: .day)
        #expect(t.urls.withLock { $0.count } == 1)
        clock.now = Date(timeIntervalSince1970: 600)
        _ = try await c.forecast(latitude: 1, longitude: 2, request: .day)
        #expect(t.urls.withLock { $0.count } == 2)
    }

    @Test("T-046t F-18 §31 review: 澳门/香港 under country 中国 are named from adm1 or id; empty days are a parse failure, not cached")
    func hkmoAndEmpty() async throws {
        let mo = #"{"code":"200","location":[{"name":"澳门","id":"101330101","lat":"22.19","lon":"113.54","adm1":"澳门","country":"中国"}]}"#
        let hk = #"{"code":"200","location":[{"name":"香港","id":"101320101","lat":"22.28","lon":"114.17","adm1":"香港特别行政区","country":"中国"}]}"#
        let zh = #"{"code":"200","location":[{"name":"珠海","id":"101280701","lat":"22.27","lon":"113.58","adm1":"广东省","country":"中国"}]}"#
        for (body, want) in [(mo, "澳门"), (hk, "香港"), (zh, "中国")] {
            let found = try await client(QWeatherTransport(["/lookup": (200, body)])).lookUp("x", country: nil)
            #expect(found.first?.country == want)
        }
        let t = QWeatherTransport(["/daily/": (200, #"{"days":[]}"#)])
        let c = client(t)
        for _ in 0..<2 {
            await #expect(throws: QWeatherError.parse) { try await c.forecast(latitude: 1, longitude: 2, request: .day) }
        }
        #expect(t.urls.withLock { $0.count } == 2)
    }
}
