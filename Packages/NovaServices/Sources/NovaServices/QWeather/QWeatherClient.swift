import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §31 (T-046t): 和风天气 city lookup and v1 weather (current, daily, hourly) at coordinates, latitude first.
/// Every request has `lang=zh`, weather requests `localTime=true`, and the `X-QW-Api-Key` header; the account's own
/// host. Nothing from an answer reaches diagnostics (I-8).
///
/// Units: temperatures must be °C and precipitation mm. 和风's v1 pages give wind in m/s, so m/s is converted to
/// km/h (×3.6); any other unit is a parse failure (§31 item 3).
public final class QWeatherClient: ViewForecastService, @unchecked Sendable {
    private let host: @Sendable () -> String?
    private let key: @Sendable () -> String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// §31 item 2: lookups kept until the app quits; §31 item 10: weather answers kept 10 minutes.
    private var places: [String: [LookedUpPlace]] = [:]
    private var answers: [String: (at: Date, body: Data)] = [:]
    static let weatherTTL: TimeInterval = 600

    public init(host: @escaping @Sendable () -> String?, key: @escaping @Sendable () -> String?,
                transport: any HTTPTransport = URLSessionTransport(), timeout: NovaDuration = .seconds(4),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.key = key
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
        self.now = now
    }

    // MARK: Lookup (§31 item 2)

    /// `location=<name>[&range=<country, lower case>]&number=1&lang=zh`. No entry or HTTP 400 is `.notFound`.
    public func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        let cacheKey = name + "|" + (country ?? "")
        if let hit = lock.withLock({ places[cacheKey] }) { return hit }
        var items = [URLQueryItem(name: "location", value: name)]
        if let country { items.append(URLQueryItem(name: "range", value: country.lowercased())) }
        items += [URLQueryItem(name: "number", value: "1"), URLQueryItem(name: "lang", value: "zh")]
        let body = try Self.json(await get("/geo/v2/city/lookup", items, lookup: true), lookup: true)
        let found: [LookedUpPlace] = ((body["location"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let name = r["name"] as? String, let lat = Self.number(r["lat"]), let lon = Self.number(r["lon"]) else { return nil }
            return LookedUpPlace(name: name, country: Self.country(r),
                                 coordinate: GeoCoordinate(latitude: lat, longitude: lon, datum: .wgs84))
        }
        guard !found.isEmpty else { throw QWeatherError.notFound }
        lock.withLock { places[cacheKey] = found }
        return found
    }

    /// 和风 lists 香港 and 澳门 under country 中国; `adm1` (or the id prefix 10132/10133) names them (§29 item 1).
    static func country(_ r: [String: Any]) -> String? {
        let country = r["country"] as? String
        guard country == "中国" else { return country }
        let adm1 = r["adm1"] as? String ?? "", id = r["id"] as? String ?? ""
        if adm1.hasPrefix("香港") || id.hasPrefix("10132") { return "香港" }
        if adm1.hasPrefix("澳门") || id.hasPrefix("10133") { return "澳门" }
        return country
    }

    // MARK: Weather (§31 item 3)

    public func forecast(latitude: Double, longitude: Double, request: ForecastRequest) async throws -> DailyForecast {
        let at = "/\(String(format: "%.2f", latitude))/\(String(format: "%.2f", longitude))"
        let common = [URLQueryItem(name: "localTime", value: "true"), URLQueryItem(name: "lang", value: "zh")]
        switch request {
        case .now:
            // §28 item 2: sent at the same time; a failed daily request leaves `today` out.
            let dailyItems = [URLQueryItem(name: "days", value: "1")] + common
            async let current = get("/weather/v1/current" + at, common)
            async let daily = get("/weather/v1/daily" + at, dailyItems)
            let today = try? await daily
            let currentBody = try await current
            let reading = try Self.current(Self.json(currentBody))
            keep("/weather/v1/current" + at, common, currentBody)
            let days = today.flatMap { try? Self.days(Self.json($0)) } ?? []
            if let today, !days.isEmpty { keep("/weather/v1/daily" + at, dailyItems, today) }
            return DailyForecast(days: days, current: reading)
        case .day:
            let items = [URLQueryItem(name: "days", value: "10")] + common
            let data = try await get("/weather/v1/daily" + at, items)
            let days = try Self.days(Self.json(data))
            keep("/weather/v1/daily" + at, items, data)
            return DailyForecast(days: days)
        case .hours:
            let items = [URLQueryItem(name: "hours", value: "240")] + common
            let data = try await get("/weather/v1/hourly" + at, items)
            let (hours, offset) = try Self.hours(Self.json(data))
            keep("/weather/v1/hourly" + at, items, data)
            return DailyForecast(days: [], hours: hours, utcOffsetSeconds: offset)
        }
    }

    // MARK: Parsing

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// `{value, unit}`; nil when missing. A unit other than `units` is a parse failure.
    static func measure(_ v: Any?, _ units: [String: Double]) throws -> Double? {
        guard let o = v as? [String: Any] else { return nil }
        guard let value = number(o["value"]) else { return nil }
        guard let unit = o["unit"] as? String, let factor = units[unit] else { throw QWeatherError.parse }
        return value * factor
    }
    static let celsius = ["°C": 1.0]
    static let kmh = ["km/h": 1.0, "m/s": 3.6]
    static let mm = ["mm": 1.0]

    static func text(_ v: Any?) -> String? { ((v as? [String: Any])?["condition"] as? [String: Any])?["text"] as? String }

    static func windKmh(_ v: Any?) throws -> Double? { try measure(((v as? [String: Any])?["wind"] as? [String: Any])?["speed"], kmh) }

    static func current(_ body: [String: Any]) throws -> CurrentWeather {
        guard let temperature = try measure(body["temperature"], celsius) else { throw QWeatherError.parse }
        let time = ["obsTime", "updateTime", "observationTime"].lazy.compactMap { body[$0] as? String }.first
        return CurrentWeather(time: time.map(localClock) ?? "", temperature: temperature,
                              feelsLike: try measure(body["feelsLike"], celsius),
                              humidity: number(body["humidity"]).map { ($0 * 100).rounded() }, weatherCode: nil,
                              windKmh: try windKmh(body), text: text(body))
    }

    static func days(_ body: [String: Any]) throws -> [DailyForecastDay] {
        guard let days = body["days"] as? [[String: Any]], !days.isEmpty else { throw QWeatherError.parse }
        return try days.map { d in
            guard let start = d["forecastStartTime"] as? String, start.count >= 10 else { throw QWeatherError.parse }
            let day = d["daytime"] as? [String: Any], night = d["nighttime"] as? [String: Any]
            func precipitation(_ part: [String: Any]?) -> [String: Any]? { part?["precipitation"] as? [String: Any] }
            let chances = [precipitation(day), precipitation(night)].compactMap { number($0?["probability"]) }
            let amounts = try [precipitation(day), precipitation(night)].compactMap { try measure($0?["amount"], mm) }
            let winds = try [day, night].compactMap { try windKmh($0) }
            return DailyForecastDay(time: String(start.prefix(10)), weatherCode: nil,
                                    tempMax: try measure(d["temperatureMax"], celsius), tempMin: try measure(d["temperatureMin"], celsius),
                                    rainChance: chances.max().map { ($0 * 100).rounded() }, rainMm: amounts.isEmpty ? nil : amounts.reduce(0, +),
                                    windMaxKmh: winds.max(), dayText: text(day), nightText: text(night))
        }
    }

    static func hours(_ body: [String: Any]) throws -> ([HourlyForecast], Int?) {
        guard let hours = body["hours"] as? [[String: Any]], !hours.isEmpty else { throw QWeatherError.parse }
        var offset: Int?
        let list = try hours.map { h in
            guard let time = h["forecastTime"] as? String, time.count >= 16 else { throw QWeatherError.parse }
            if offset == nil { offset = utcOffset(time) }
            let chance = number((h["precipitation"] as? [String: Any])?["probability"]).map { ($0 * 100).rounded() }
            return HourlyForecast(time: localClock(time), weatherCode: nil, temperature: try measure(h["temperature"], celsius),
                                  rainChance: chance, text: text(h))
        }
        return (list, offset)
    }

    /// `yyyy-MM-ddTHH:mm` of an ISO time on the place's clock (localTime=true), dropping any offset.
    static func localClock(_ iso: String) -> String { String(iso.prefix(16)) }

    /// The `±HH:MM` after the minutes (`2026-11-13T15:00+09:00` → 32400); `Z` or none is nil.
    static func utcOffset(_ iso: String) -> Int? {
        let rest = iso.dropFirst(16).drop { $0 == ":" || $0.isNumber || $0 == "." }
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let digits = rest.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)) else { return nil }
        return (sign == "+" ? 1 : -1) * (h * 3600 + m * 60)
    }

    // MARK: Network

    private func get(_ path: String, _ items: [URLQueryItem], lookup: Bool = false) async throws -> Data {
        guard let host = host().map(QWeatherHostName.normalized), !host.isEmpty, let key = key(), !key.isEmpty else {
            throw QWeatherError.noKey
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        guard let url = components.url else { throw QWeatherError.noKey }
        let cacheKey = url.absoluteString
        if !lookup, let hit = lock.withLock({ answers[cacheKey] }), now().timeIntervalSince(hit.at) < Self.weatherTTL { return hit.body }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "X-QW-Api-Key")
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw QWeatherError.timeout
        } catch {
            throw QWeatherError.failed
        }
        if lookup && response.status == 400 { throw QWeatherError.notFound }
        guard response.status == 200 else { throw QWeatherError.http(response.status) }
        _ = try Self.json(response.body, lookup: lookup)
        return response.body
    }

    /// I-3: only an answer whose content parsed is kept; expired entries are dropped.
    private func keep(_ path: String, _ items: [URLQueryItem], _ body: Data) {
        guard let url = url(path, items) else { return }
        let at = now()
        lock.withLock {
            answers = answers.filter { at.timeIntervalSince($0.value.at) < Self.weatherTTL }
            // A reused answer keeps its first time, so it still expires 10 minutes after it was fetched.
            if answers[url.absoluteString] == nil { answers[url.absoluteString] = (at, body) }
        }
    }

    private func url(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard let host = host().map(QWeatherHostName.normalized), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        return components.url
    }

    /// The answer as a JSON object; a lookup `code` other than "200" is not-found (400/404) or `http`.
    static func json(_ data: Data, lookup: Bool = false) throws -> [String: Any] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QWeatherError.parse }
        if lookup, let code = body["code"] as? String, code != "200" {
            throw code == "404" || code == "400" ? QWeatherError.notFound : QWeatherError.http(Int(code) ?? 0)
        }
        return body
    }
}

/// The same normalisation as `QWeatherHost` (NovaAgent), for hosts saved before it existed.
enum QWeatherHostName {
    static func normalized(_ input: String) -> String {
        var h = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where h.lowercased().hasPrefix(scheme) { h = String(h.dropFirst(scheme.count)) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
}
