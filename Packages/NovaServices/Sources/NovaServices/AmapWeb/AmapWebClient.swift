import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// Amap Web service REST (`restapi.amap.com`, contracts/api-contracts.md): place search, reverse
/// geocoding and weather. All coordinates are GCJ-02. Status codes only reach diagnostics (I-8).
public struct AmapWebClient: PlaceSearch, ReverseGeocoder, WeatherService {
    public static let host = "https://restapi.amap.com"

    private let key: @Sendable () -> String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    /// `key` is read per request, so a key saved in 设置 works without a restart.
    public init(key: @escaping @Sendable () -> String?, transport: any HTTPTransport = URLSessionTransport(),
                timeout: NovaDuration = .seconds(4)) {
        self.key = key
        self.transport = transport
        self.timeout = Double(timeout.milliseconds) / 1000
    }

    // MARK: PlaceSearch

    public func text(_ keywords: String, city: String?) async throws -> [Place] {
        var query = ["keywords": keywords, "offset": "10", "page": "1", "extensions": "base"]
        if let city { query["city"] = city }
        return Self.places(try await get("/v3/place/text", query))
    }

    public func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        let found = Self.places(try await get("/v3/place/around", [
            "keywords": keywords, "location": Self.lngLat(center), "radius": String(radiusMeters),
            "sortrule": sort.rawValue, "offset": "10", "page": "1", "extensions": "base",
        ]))
        // A destination outside the radius (another city) is still a destination: fall back to a text search.
        return found.isEmpty ? try await text(keywords, city: nil) : found
    }

    public func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] {
        Self.places(try await get("/v3/place/polygon", [
            "keywords": keywords, "polygon": vertices.map(Self.lngLat).joined(separator: "|"),
            "offset": String(AmapWebTuning().corridorPageSize),
        ]))
    }

    public func detail(id: String) async throws -> Place? {
        Self.places(try await get("/v3/place/detail", ["id": id, "extensions": "all"])).first
    }

    // MARK: ReverseGeocoder

    public func adcode(at coordinate: GeoCoordinate) async throws -> String? {
        let body = try await get("/v3/geocode/regeo", ["location": Self.lngLat(coordinate)])
        let component = (body["regeocode"] as? [String: Any])?["addressComponent"] as? [String: Any]
        return component?["adcode"] as? String
    }

    /// F-16a: `formatted_address` plus district and street; Amap sends `[]` for an empty field.
    public func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        let body = try await get("/v3/geocode/regeo", ["location": Self.lngLat(coordinate)])
        return Self.address(body)
    }

    static func address(_ body: [String: Any]) -> PlaceAddress? {
        guard let regeocode = body["regeocode"] as? [String: Any],
              let formatted = regeocode["formatted_address"] as? String, !formatted.isEmpty else { return nil }
        let component = regeocode["addressComponent"] as? [String: Any]
        let district = component?["district"] as? String
        let street = (component?["streetNumber"] as? [String: Any])?["street"] as? String
        return PlaceAddress(formatted: formatted, district: district?.isEmpty == false ? district : nil,
                            road: street?.isEmpty == false ? street : nil)
    }

    // MARK: WeatherService

    /// `adcode` may also be a city name; it is geocoded first.
    public func weather(adcode: String, forecast: Bool) async throws -> WeatherReport {
        var code = adcode
        if !adcode.allSatisfy(\.isNumber) {
            let body = try await get("/v3/geocode/geo", ["address": adcode])
            guard let first = (body["geocodes"] as? [[String: Any]])?.first, let found = first["adcode"] as? String else {
                throw AmapWebError.failed
            }
            code = found
        }
        let body = try await get("/v3/weather/weatherInfo", ["city": code, "extensions": forecast ? "all" : "base"])
        if forecast {
            guard let cast = ((body["forecasts"] as? [[String: Any]])?.first?["casts"] as? [[String: Any]])?.dropFirst().first,
                  let city = (body["forecasts"] as? [[String: Any]])?.first?["city"] as? String else {
                throw AmapWebError.failed
            }
            return WeatherReport(adcode: code, summary: .object([
                "city": .string(city), "day": "tomorrow",
                "weather_day": .string(cast["dayweather"] as? String ?? ""),
                "temp_high": .string(cast["daytemp"] as? String ?? ""),
                "temp_low": .string(cast["nighttemp"] as? String ?? ""),
            ]))
        }
        guard let live = (body["lives"] as? [[String: Any]])?.first else { throw AmapWebError.failed }
        return WeatherReport(adcode: code, summary: .object([
            "city": .string(live["city"] as? String ?? ""), "day": "today",
            "weather": .string(live["weather"] as? String ?? ""),
            "temperature_c": .string(live["temperature"] as? String ?? ""),
            "wind": .string("\(live["winddirection"] as? String ?? "")风\(live["windpower"] as? String ?? "")级"),
            "humidity": .string(live["humidity"] as? String ?? ""),
        ]))
    }

    // MARK: Transport

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let key = key(), !key.isEmpty else { throw AmapWebError.keyMissing }
        var components = URLComponents(string: Self.host + path)!
        components.queryItems = (query.merging(["key": key, "output": "JSON"]) { a, _ in a })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AmapWebError.timeout
        } catch {
            throw AmapWebError.failed
        }
        guard response.status == 200,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw AmapWebError.failed
        }
        guard body["status"] as? String == "1" else { throw Self.error(infocode: body["infocode"] as? String) }
        return body
    }

    static func error(infocode: String?) -> AmapWebError {
        switch infocode {
        case "10001", "10009", "10010", "10012": .keyRejected
        case "10003", "10004", "10014", "10019", "10020", "10021", "10044", "10045": .quota
        default: .failed
        }
    }

    static func lngLat(_ c: GeoCoordinate) -> String {
        String(format: "%.6f,%.6f", c.longitude, c.latitude)
    }

    /// Amap gives empty fields as `[]`, numbers as strings.
    static func places(_ body: [String: Any]) -> [Place] {
        ((body["pois"] as? [[String: Any]]) ?? []).compactMap { poi in
            guard let id = poi["id"] as? String, let name = poi["name"] as? String,
                  let location = poi["location"] as? String else { return nil }
            let parts = location.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            // Amap gives an empty field as `[]`, so only non-empty strings count. Opening hours sit in
            // `biz_ext.open_time` (or `opentime2`) of a detail with extensions=all.
            let text: (Any?) -> String? = { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let business = poi["biz_ext"] as? [String: Any]
            return Place(id: id, name: name, address: text(poi["address"]),
                         coordinate: GeoCoordinate(latitude: parts[1], longitude: parts[0], datum: .gcj02),
                         distanceMeters: (poi["distance"] as? String).flatMap { Int($0) },
                         openingHours: text(business?["open_time"]) ?? text(business?["opentime2"]),
                         phone: text(poi["tel"]))
        }
    }
}
