import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §26 items 2, 4 (T-046o): Open-Meteo forecast and geocoding, no key. Free API: non-commercial, data
/// CC BY 4.0 (credited in 设置). Nothing from the response reaches diagnostics (I-8).
public struct OpenMeteoClient: DailyForecastService, PlaceLookup {
    public static let forecastHost = "https://api.open-meteo.com"
    public static let geocodingHost = "https://geocoding-api.open-meteo.com"
    static let currentVariables = "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
    static let hourly = "temperature_2m,weather_code,precipitation_probability"
    static let daily = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max"

    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    /// §26 item 4: the time limit is the same as 高德's (`AmapWebClient`, 4 s).
    public init(transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(4)) {
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    /// §26 item 4: the caller rounds the coordinates to 2 decimals; they are written with 2 decimals here too.
    /// §27 item 1, §28 item 5: `current=`, then `hourly=`, then `daily=`, in one call.
    public func dailyForecast(latitude: Double, longitude: Double) async throws -> DailyForecast {
        let url = Self.forecastHost + "/v1/forecast?latitude=\(String(format: "%.2f", latitude))&longitude=\(String(format: "%.2f", longitude))"
            + "&current=\(Self.currentVariables)&hourly=\(Self.hourly)&daily=\(Self.daily)&timezone=auto&forecast_days=16"
        let body = try await get(url)
        return DailyForecast(days: Self.days(body), current: Self.current(body), hours: Self.hours(body),
                             utcOffsetSeconds: (body["utc_offset_seconds"] as? NSNumber)?.intValue)
    }

    /// §27 item 2: a missing or unreadable `current` (no `time` or no `temperature_2m`) is nil, never an error.
    static func current(_ body: [String: Any]) -> CurrentWeather? {
        guard let c = body["current"] as? [String: Any], let time = c["time"] as? String,
              let temperature = (c["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        func number(_ key: String) -> Double? { (c[key] as? NSNumber)?.doubleValue }
        return CurrentWeather(time: time, temperature: temperature, feelsLike: number("apparent_temperature"),
                              humidity: number("relative_humidity_2m"), weatherCode: number("weather_code").map { Int($0) },
                              windKmh: number("wind_speed_10m"))
    }

    /// §28 item 5: a missing or unreadable `hourly` block is `[]`, never an error.
    static func hours(_ body: [String: Any]) -> [HourlyForecast] {
        guard let hourly = body["hourly"] as? [String: Any], let times = hourly["time"] as? [String] else { return [] }
        func column(_ key: String) -> [Double?] { ((hourly[key] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue } }
        let temp = column("temperature_2m"), code = column("weather_code"), chance = column("precipitation_probability")
        func at(_ c: [Double?], _ i: Int) -> Double? { i < c.count ? c[i] : nil }
        return times.indices.map { i in
            HourlyForecast(time: times[i], weatherCode: at(code, i).map { Int($0) }, temperature: at(temp, i), rainChance: at(chance, i))
        }
    }

    static func days(_ body: [String: Any]) -> [DailyForecastDay] {
        guard let daily = body["daily"] as? [String: Any], let times = daily["time"] as? [String] else { return [] }
        func column(_ key: String) -> [Double?] {
            ((daily[key] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        let code = column("weather_code"), high = column("temperature_2m_max"), low = column("temperature_2m_min")
        let chance = column("precipitation_probability_max"), rain = column("precipitation_sum")
        let wind = column("wind_speed_10m_max")
        func at(_ c: [Double?], _ i: Int) -> Double? { i < c.count ? c[i] : nil }
        return times.indices.map { i in
            DailyForecastDay(time: times[i], weatherCode: at(code, i).map { Int($0) }, tempMax: at(high, i),
                             tempMin: at(low, i), rainChance: at(chance, i), rainMm: at(rain, i), windMaxKmh: at(wind, i))
        }
    }

    /// §26 item 2: `name`, `countryCode`, `count=10`, `language=zh`. An empty result is `[]`.
    public func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        var components = URLComponents(string: Self.geocodingHost + "/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
            + (country.map { [URLQueryItem(name: "countryCode", value: $0)] } ?? [])
            + [URLQueryItem(name: "count", value: "10"), URLQueryItem(name: "language", value: "zh"),
               URLQueryItem(name: "format", value: "json")]
        let body = try await get(components.url!.absoluteString)
        return ((body["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let name = r["name"] as? String, let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            return LookedUpPlace(name: name, country: r["country"] as? String,
                                 coordinate: GeoCoordinate(latitude: lat, longitude: lon, datum: .wgs84),
                                 population: (r["population"] as? NSNumber)?.intValue,
                                 countryCode: r["country_code"] as? String)
        }
    }

    private func get(_ url: String) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw ForecastError.failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw ForecastError.timeout
        } catch {
            throw ForecastError.failed
        }
        guard response.status == 200,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw ForecastError.failed
        }
        return body
    }
}
