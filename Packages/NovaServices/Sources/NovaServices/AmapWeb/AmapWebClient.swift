import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaNav
import NovaPorts

/// Amap Web service REST (`restapi.amap.com`, contracts/api-contracts.md): place search, reverse
/// geocoding and weather. All coordinates are GCJ-02. Status codes only reach diagnostics (I-8).
public struct AmapWebClient: PlaceInfoSearch, ReverseGeocoder, PlaceLookup, DrivingTimes {
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

    /// F-16 §14 item 1: `citylimit=true` keeps the search inside `city` (the car's adcode).
    public func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        var query = ["keywords": keywords, "offset": "10", "page": "1", "extensions": "base"]
        if let city {
            query["city"] = city
            if cityLimit { query["citylimit"] = "true" }
        }
        return Self.places(try await get("/v3/place/text", query))
    }

    /// F-15b §68 (T-040zu): the same request as `text(_:city:cityLimit:)` (no `city` sends no `city`/`citylimit`); an
    /// error carries 高德's `info`.
    public func textInfo(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        var query = ["keywords": keywords, "offset": "10", "page": "1", "extensions": "base"]
        if let city {
            query["city"] = city
            if cityLimit { query["citylimit"] = "true" }
        }
        let body: [String: Any]
        do {
            body = try await fetch("/v3/place/text", query)
        } catch let error as AmapWebError {
            throw AmapWebFailure(error, info: nil)
        }
        guard body["status"] as? String == "1" else {
            throw AmapWebFailure(Self.error(infocode: body["infocode"] as? String), info: body["info"] as? String)
        }
        return Self.places(body)
    }

    /// F-16 §14 item 1: the radius only; nothing found stays nothing.
    public func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        Self.places(try await get("/v3/place/around", [
            "keywords": keywords, "location": Self.lngLat(center), "radius": String(radiusMeters),
            "sortrule": sort.rawValue, "offset": "10", "page": "1", "extensions": "base",
        ]))
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

    // MARK: DrivingTimes (F-15b §26)

    /// `/v3/distance type=1` (driving): many origins (`|`) to one destination; `distance` (m) and `duration` (s) per
    /// origin, matched by `origin_id` (1-based).
    public func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        guard !origins.isEmpty else { return [] }
        let body = try await get("/v3/distance", [
            "origins": origins.map(Self.lngLat).joined(separator: "|"),
            "destination": Self.lngLat(destination), "type": "1",
        ])
        return Self.drivingTimes(body, count: origins.count)
    }

    static func drivingTimes(_ body: [String: Any], count: Int) -> [DrivingTime?] {
        var out = [DrivingTime?](repeating: nil, count: count)
        for (offset, raw) in ((body["results"] as? [[String: Any]]) ?? []).enumerated() {
            let id = (raw["origin_id"] as? String).flatMap(Int.init) ?? (offset + 1)
            guard (1...count).contains(id),
                  let meters = (raw["distance"] as? String).flatMap(Int.init),
                  let seconds = (raw["duration"] as? String).flatMap(Int.init) else { continue }
            out[id - 1] = DrivingTime(meters: meters, seconds: seconds)
        }
        return out
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

    /// F-16 §14 item 1: adcode and formatted address from one regeo.
    public func region(at coordinate: GeoCoordinate) async throws -> PlaceRegion {
        let body = try await get("/v3/geocode/regeo", ["location": Self.lngLat(coordinate)])
        let component = (body["regeocode"] as? [String: Any])?["addressComponent"] as? [String: Any]
        return PlaceRegion(adcode: component?["adcode"] as? String, formatted: Self.address(body)?.formatted)
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

    // MARK: PlaceLookup

    /// F-18 §26 item 2: `/v3/geocode/geo` with its `location` (longitude,latitude), `formatted_address`, `city` and
    /// adcode. `country` is not sent (高德 is only asked for China, 香港 and 澳门). Amap sends `[]` for an empty field.
    public func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        let body = try await get("/v3/geocode/geo", ["address": name])
        return Self.geocodes(body)
    }

    static func geocodes(_ body: [String: Any]) -> [LookedUpPlace] {
        ((body["geocodes"] as? [[String: Any]]) ?? []).compactMap { g in
            let text: (Any?) -> String? = { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
            guard let adcode = text(g["adcode"]) else { return nil }
            let parts = (text(g["location"]) ?? "").split(separator: ",").compactMap { Double($0) }
            let coordinate = parts.count == 2 ? GeoCoordinate(latitude: parts[1], longitude: parts[0], datum: .gcj02) : nil
            let formatted = text(g["formatted_address"])
            return LookedUpPlace(name: text(g["city"]) ?? text(g["province"]) ?? formatted ?? "", coordinate: coordinate,
                                 formatted: formatted, adcode: adcode)
        }
    }

    // MARK: Transport

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        let body = try await fetch(path, query)
        guard body["status"] as? String == "1" else { throw Self.error(infocode: body["infocode"] as? String) }
        return body
    }

    /// The JSON body, whatever its `status`; transport and parse errors as `AmapWebError`.
    private func fetch(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
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
                         phone: text(poi["tel"]), city: text(poi["cityname"]), district: text(poi["adname"]),
                         // F-15b §12 items 1 and 3 (T-040j): the first `photos[].url` (older docs spell the title
                         // `titile`; only `url` is read), secure links only.
                         photoURL: TripPhotoLink.secure(((poi["photos"] as? [[String: Any]])?.first)?["url"] as? String),
                         // F-15b §46 item 6 (T-040r): the kind from 高德's `type`.
                         kind: PlaceKindMap.amap(type: text(poi["type"])),
                         // F-15b §68 item 1 (T-040zu): the adcode keeps Macau (82) and Hong Kong (81) results.
                         adcode: text(poi["adcode"]),
                         // F-15b §70 item 1 (T-040zw): v3 gives Macau/Hong Kong no adcode; `pname` names the SAR.
                         province: text(poi["pname"]))
        }
    }
}
