import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// Answers by URL path: the search, then each summary key; a missing path is a 404; `timeout` throws a timed-out error.
final class WikiTransport: HTTPTransport, @unchecked Sendable {
    var bodies: [String: String] = [:]
    var timeout = false
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        if timeout { throw URLError(.timedOut) }
        let path = request.url?.path ?? ""
        let key = path.hasSuffix("/search/page") ? "search" : String(path.split(separator: "/").last ?? "")
        guard let body = bodies[key.removingPercentEncoding ?? key] else { return (404, Data()) }
        return (200, Data(body.utf8))
    }
}

@Suite("T-040r F-15b §46 Wikipedia photos abroad and the kind of place")
struct WikipediaPhotosTests {
    static let senso = GeoCoordinate(latitude: 35.7148, longitude: 139.7967, datum: .gcj02)

    static func search(_ keys: [String]) -> String {
        #"{"pages":["# + keys.map { #"{"id":1,"key":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",") + "]}"
    }

    static func summary(lat: Double?, lon: Double? = nil, thumb: String?) -> String {
        var parts: [String] = [#""type":"standard""#]
        if let lat, let lon { parts.append(#""coordinates":{"lat":\#(lat),"lon":\#(lon)}"#) }
        if let thumb { parts.append(#""thumbnail":{"source":"\#(thumb)","width":330,"height":220}"#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    @Test("F-15b row 105: 「浅草寺 (Senso-ji)」: one search for Senso-ji, one summary 0.2 km away; its thumbnail; 5 s; User-Agent")
    func row105() async throws {
        let t = WikiTransport()
        t.bodies = ["search": Self.search(["Sensō-ji"]),
                    "Sensō-ji": Self.summary(lat: 35.7148, lon: 139.7944, thumb: "https://upload.wikimedia.org/a/330px-Senso.jpg")]
        let url = try await WikipediaPhotos(transport: t).photo(asked: "浅草寺 (Senso-ji)", near: Self.senso)
        #expect(url?.absoluteString == "https://upload.wikimedia.org/a/330px-Senso.jpg")
        #expect(t.requests.count == 2)
        let first = try #require(t.requests.first?.url?.absoluteString)
        #expect(first.hasPrefix("https://en.wikipedia.org/w/rest.php/v1/search/page?") && first.contains("q=Senso-ji") && first.contains("limit=3"))
        #expect(t.requests[1].url?.absoluteString.hasPrefix("https://en.wikipedia.org/api/rest_v1/page/summary/") == true)
        #expect(t.requests.allSatisfy { $0.timeoutInterval == 5 && $0.value(forHTTPHeaderField: "User-Agent") == "NovaDrive/1.0 (iOS)" })
    }

    @Test("F-15b §46 item 1: a name with no English part (租车) asks Wikipedia nothing")
    func noEnglishName() async throws {
        let t = WikiTransport()
        let url = try await WikipediaPhotos(transport: t).photo(asked: "租车", near: Self.senso)
        #expect(url == nil)
        #expect(t.requests.isEmpty)
    }

    @Test("F-15b row 106: first result without coordinates, second 370 km away, third 0.5 km: the third's photo")
    func row106() async throws {
        let t = WikiTransport()
        t.bodies = ["search": Self.search(["Song", "Namesake", "Right"]),
                    "Song": Self.summary(lat: nil, thumb: "https://upload.wikimedia.org/song.jpg"),
                    "Namesake": Self.summary(lat: 34.70, lon: 135.50, thumb: "https://upload.wikimedia.org/osaka.jpg"),
                    "Right": Self.summary(lat: 35.7193, lon: 139.7967, thumb: "https://upload.wikimedia.org/right.jpg")]
        let url = try await WikipediaPhotos(transport: t).photo(asked: "浅草寺 (Senso-ji)", near: Self.senso)
        #expect(url?.absoluteString == "https://upload.wikimedia.org/right.jpg")
        #expect(t.requests.count == 4)
    }

    @Test("F-15b row 107: no result within 2 km → nil in at most 4 requests; a search timeout throws after 1 request")
    func row107() async throws {
        let t = WikiTransport()
        t.bodies = ["search": Self.search(["A", "B", "C", "D"]),
                    "A": Self.summary(lat: 36.0, lon: 139.7967, thumb: "https://upload.wikimedia.org/a.jpg"),
                    "B": Self.summary(lat: nil, thumb: nil),
                    "C": Self.summary(lat: 35.7148, lon: 139.7967, thumb: nil),
                    "D": Self.summary(lat: 35.7148, lon: 139.7967, thumb: "https://upload.wikimedia.org/d.jpg")]
        let none = try await WikipediaPhotos(transport: t).photo(asked: "浅草寺 (Senso-ji)", near: Self.senso)
        #expect(none == nil)
        #expect(t.requests.count == 4)

        let slow = WikiTransport()
        slow.timeout = true
        await #expect(throws: AmapWebError.timeout) {
            try await WikipediaPhotos(transport: slow).photo(asked: "浅草寺 (Senso-ji)", near: Self.senso)
        }
        #expect(slow.requests.count == 1)
    }

    @Test("F-15b row 107: an empty search and an http thumbnail made secure")
    func secure() async throws {
        let t = WikiTransport()
        t.bodies = ["search": #"{"pages":[]}"#]
        #expect(try await WikipediaPhotos(transport: t).photo(asked: "Nowhere", near: Self.senso) == nil)
        #expect(WikipediaPhotos.photo(Data(Self.summary(lat: 35.7148, lon: 139.7967, thumb: "http://upload.wikimedia.org/x.jpg").utf8),
                                      near: Self.senso)?.absoluteString == "https://upload.wikimedia.org/x.jpg")
    }

    @Test("F-15b row 109: Photon osm_key/osm_value → temple, hotel, airport, rental, other; 高德 type → kind")
    func row109() throws {
        let tags: [(String, String, PlaceKind)] = [("amenity", "place_of_worship", .temple), ("tourism", "hotel", .hotel),
                                                   ("aeroway", "aerodrome", .airport), ("amenity", "car_rental", .rental),
                                                   ("highway", "bus_stop", .other), ("tourism", "museum", .museum),
                                                   ("tourism", "viewpoint", .tower), ("leisure", "park", .park),
                                                   ("shop", "mall", .shop), ("amenity", "restaurant", .food)]
        for (key, value, kind) in tags { #expect(PlaceKindMap.osm(key: key, value: value) == kind) }
        #expect(PlaceKindMap.osm(key: nil, value: nil) == nil)
        let body = #"{"features":[{"properties":{"osm_type":"W","osm_id":1,"name":"Sensō-ji","countrycode":"JP","osm_key":"amenity","osm_value":"place_of_worship"},"geometry":{"coordinates":[139.7967,35.7148]}},{"properties":{"osm_type":"N","osm_id":2,"name":"X"},"geometry":{"coordinates":[139.7,35.7]}}]}"#
        let places = try PhotonPlaceSearch.parse(Data(body.utf8))
        #expect(places.map(\.kind) == [.temple, nil])
        #expect(PlaceKindMap.amap(type: "风景名胜;寺庙道观;寺庙道观") == .temple)
        #expect(PlaceKindMap.amap(type: "交通设施服务;机场相关;飞机场") == .airport)
        #expect(PlaceKindMap.amap(type: "住宿服务;宾馆酒店;五星级宾馆") == .hotel)
        #expect(PlaceKindMap.amap(type: "风景名胜;公园广场;公园") == .park)
        #expect(PlaceKindMap.amap(type: "") == nil)
        let amap = AmapWebClient.places(["pois": [["id": "B1", "name": "大悲院", "location": "117.2,39.1", "type": "风景名胜;寺庙道观;寺庙道观"]]])
        #expect(amap.first?.kind == .temple)
    }
}
