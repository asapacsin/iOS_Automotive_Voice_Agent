import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §36 item 2b (2026-11-18): place search for trips abroad through Photon, the OpenStreetMap search
/// (`https://photon.komoot.io/api/`, no key). Apple's search on a China-region iPhone returns only places in China
/// (device records 20261118-102820 and -105448: 107 results, all in China, and no centre for "Tokyo, Japan").
///
/// Names come as 「中文名 (English name)」: the English part is searched (OpenStreetMap has few Chinese names) and the
/// Chinese part is the name shown. A few Chinese category words (「酒店」, 「租车」…) become OpenStreetMap tags.
/// Errors come back as `AmapWebError` so the trip planner treats every vendor alike. OpenStreetMap coordinates are
/// WGS-84, equal to GCJ-02 outside China.
public final class PhotonPlaceSearch: AreaPlaceSearch, @unchecked Sendable {
    public static let host = "https://photon.komoot.io/api/"
    public static let timeoutSeconds: Double = 8
    /// Categories searched by tag (OpenStreetMap keys), so 「酒店」 finds hotels in any language.
    static let tags: [String: (q: String, tag: String)] = [
        "酒店": ("hotel", "tourism:hotel"), "宾馆": ("hotel", "tourism:hotel"),
        "租车": ("car rental", "amenity:car_rental"), "租车公司": ("car rental", "amenity:car_rental"),
        "加油站": ("fuel", "amenity:fuel"), "停车场": ("parking", "amenity:parking"),
    ]
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// 「浅草寺 (Senso-ji)」 → shown 浅草寺, searched Senso-ji; a name without brackets is searched as it is.
    static func split(_ name: String) -> (shown: String?, query: String) {
        let s = name.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return (nil, s) }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)].trimmingCharacters(in: .whitespaces)
        let outer = s[..<open].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return (nil, outer) }
        return (outer.isEmpty ? nil : outer, inner)
    }

    public func text(_ keywords: String, city: String?) async throws -> [Place] {
        try await search(keywords, near: nil, limit: 1)
    }

    public func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await search(keywords, near: center, limit: Self.tags[keywords] != nil ? 5 : 1)
    }

    /// Only places within the radius, nearest first (Photon's location is a bias, not a limit).
    public func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await search(keywords, near: center, limit: 10).compactMap { place in
            let d = Self.meters(center, place.coordinate)
            guard d <= Double(radiusMeters) else { return nil }
            return Place(id: place.id, name: place.name, address: place.address, coordinate: place.coordinate,
                         distanceMeters: Int(d.rounded()), city: place.city, district: place.district,
                         countryCode: place.countryCode, kind: place.kind)
        }.sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
    }

    public func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    public func detail(id: String) async throws -> Place? { nil }

    /// The centre of a city abroad ("Tokyo, Japan"); nil when not found or in China (CN, HK, MO, TW).
    public func center(_ city: String) async -> GeoCoordinate? {
        guard let found = try? await search(city, near: nil, limit: 3) else { return nil }
        return found.first { !TripRegion.isChina($0.countryCode) }?.coordinate
    }

    /// F-15b §50 item 3 (T-040v): the centre of a city abroad with its `countrycode`; nil when not found or in China.
    public func area(_ city: String) async -> TripArea? {
        guard let found = try? await search(city, near: nil, limit: 3),
              let place = found.first(where: { !TripRegion.isChina($0.countryCode) }) else { return nil }
        return TripArea(center: place.coordinate, countryCode: place.countryCode)
    }

    /// §50 item 3: a trip lookup restricted to `box` (Photon's `bbox`), `limit` results. The name shown is the found
    /// place's (`TripGround.shownName` rule: the asked Chinese name in brackets only when they share no character).
    public func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place] {
        let (shown, query) = Self.split(keywords)
        let found = try await search(keywords, near: nil, limit: limit, box: box, keepFoundName: true)
        guard Self.tags[query] == nil else { return found }
        return found.map { p in
            Place(id: p.id, name: Self.shownName(asked: shown, found: p.name), address: p.address ?? p.name,
                  coordinate: p.coordinate, distanceMeters: nil, city: p.city, district: p.district,
                  countryCode: p.countryCode, kind: p.kind)
        }
    }

    /// §50 item 3: the found name, with the asked one in brackets only when the two share no character.
    static func shownName(asked: String?, found: String) -> String {
        guard let asked = asked?.trimmingCharacters(in: .whitespaces), !asked.isEmpty, asked != found else { return found }
        return Set(asked).isDisjoint(with: Set(found)) ? "\(found) (\(asked))" : found
    }

    func search(_ keywords: String, near: GeoCoordinate?, limit: Int, box: GeoBox? = nil,
                keepFoundName: Bool = false) async throws -> [Place] {
        let (shown, query) = Self.split(keywords)
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let tag = Self.tags[query] {
            items.append(URLQueryItem(name: "q", value: tag.q))
            items.append(URLQueryItem(name: "osm_tag", value: tag.tag))
        } else {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.5f", near.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.5f", near.longitude)))
        }
        if let box {
            // Photon: `bbox=minLon,minLat,maxLon,maxLat`.
            let v = [box.minLongitude, box.minLatitude, box.maxLongitude, box.maxLatitude].map { String(format: "%.5f", $0) }
            items.append(URLQueryItem(name: "bbox", value: v.joined(separator: ",")))
        }
        var components = URLComponents(string: Self.host)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("NovaDrive/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AmapWebError.timeout
        } catch {
            throw AmapWebError.failed
        }
        if response.status == 429 { throw AmapWebError.quota }
        guard response.status == 200 else { throw AmapWebError.failed }
        let places = try Self.parse(response.body)
        // The Chinese name asked is the name shown, for one named place (not for a category search).
        guard !keepFoundName, let shown, Self.tags[query] == nil else { return places }
        return places.map { p in
            Place(id: p.id, name: shown, address: p.address ?? p.name, coordinate: p.coordinate, distanceMeters: nil,
                  city: p.city, district: p.district, countryCode: p.countryCode, kind: p.kind)
        }
    }

    static func parse(_ body: Data) throws -> [Place] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw AmapWebError.failed }
        return features.compactMap { f in
            guard let props = f["properties"] as? [String: Any],
                  let geometry = f["geometry"] as? [String: Any],
                  let xy = geometry["coordinates"] as? [Double], xy.count == 2 else { return nil }
            let name = (props["name"] as? String) ?? (props["street"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let type = (props["osm_type"] as? String) ?? "X"
            let osmID = (props["osm_id"] as? NSNumber)?.int64Value ?? 0
            let address = [props["city"], props["district"], props["street"], props["housenumber"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            return Place(id: "osm_\(type)\(osmID)", name: name, address: address.isEmpty ? nil : address,
                         coordinate: GeoCoordinate(latitude: xy[1], longitude: xy[0], datum: .gcj02), distanceMeters: nil,
                         city: props["city"] as? String, district: props["district"] as? String,
                         countryCode: (props["countrycode"] as? String)?.uppercased(),
                         // §46 item 6 (T-040r): the kind from the OpenStreetMap tag.
                         kind: PlaceKindMap.osm(key: props["osm_key"] as? String, value: props["osm_value"] as? String))
        }
    }

    static func meters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let r = 6_371_000.0, p = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * p, dLng = (b.longitude - a.longitude) * p
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * p) * cos(b.latitude * p) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
