import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

@Suite("F-15b §36 item 2b Photon place search abroad")
struct PhotonPlaceSearchTests {
    static let senso = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"osm_type":"W","osm_id":123,"name":"金龍山 浅草寺","countrycode":"JP","city":"台東区","street":"浅草"},"geometry":{"type":"Point","coordinates":[139.7955265,35.7134032]}}]}"#

    @Test("「浅草寺 (Senso-ji)」 searches Senso-ji near the centre and shows 浅草寺, JP, WGS-84 as is")
    func named() async throws {
        let t = StubTransport()
        t.body = Data(Self.senso.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let found = try await s.around("浅草寺 (Senso-ji)", center: GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02),
                                       radiusMeters: 100_000, sort: .weight)
        #expect(found.count == 1 && found[0].name == "浅草寺" && found[0].countryCode == "JP" && found[0].id == "osm_W123")
        #expect(abs(found[0].coordinate.latitude - 35.7134032) < 1e-9)
        let url = try #require(t.requests.first?.url?.absoluteString)
        #expect(url.contains("q=Senso-ji") && url.contains("lat=35.68000") && url.contains("lon=139.76000") && url.contains("limit=1"))
    }

    @Test("Name splitting: full-width brackets, no brackets, empty inner")
    func split() {
        #expect(PhotonPlaceSearch.split("东京晴空塔（Tokyo Skytree）") == ("东京晴空塔", "Tokyo Skytree"))
        #expect(PhotonPlaceSearch.split("Ginza") == (nil, "Ginza"))
        #expect(PhotonPlaceSearch.split("银座 ()") == (nil, "银座"))
    }

    @Test("「酒店」 is a tourism:hotel tag search; 「租车」 amenity:car_rental; names kept from OpenStreetMap")
    func tags() async throws {
        let t = StubTransport()
        t.body = Data(Self.senso.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let c = GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02)
        let hotels = try await s.aroundOnly("酒店", center: c, radiusMeters: 3_000, sort: .distance)
        #expect(hotels.first?.name == "金龍山 浅草寺")
        _ = try await s.around("租车", center: c, radiusMeters: 3_000, sort: .distance)
        let urls = t.requests.compactMap { $0.url?.absoluteString.removingPercentEncoding }
        #expect(urls[0].contains("osm_tag=tourism:hotel") && urls[0].contains("q=hotel"))
        #expect(urls[1].contains("osm_tag=amenity:car_rental"))
    }

    @Test("City centre: a result in China is never the centre; 429 is quota; bad JSON is failed")
    func centreAndErrors() async {
        let t = StubTransport()
        t.body = Data(#"{"features":[{"properties":{"name":"东京","countrycode":"CN"},"geometry":{"coordinates":[113.0,23.0]}},{"properties":{"name":"東京都","countrycode":"JP"},"geometry":{"coordinates":[139.69,35.69]}}]}"#.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let c = await s.center("Tokyo, Japan")
        #expect(c?.longitude == 139.69)
        t.status = 429
        await #expect(throws: AmapWebError.quota) { try await s.text("x", city: nil) }
        t.status = 200
        t.body = Data("nope".utf8)
        await #expect(throws: AmapWebError.failed) { try await s.text("x", city: nil) }
    }
}

@Suite("F-15b row 84f Photon")
struct PhotonRow84fTests {
    @Test("F-15b row 84f: 「浅草寺 (Senso-ji)」 searched as Senso-ji, shown 浅草寺; 429 → quota; a CN result is never the centre")
    func row84f() async throws {
        let t = StubTransport()
        t.body = Data(PhotonPlaceSearchTests.senso.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let found = try await s.text("浅草寺 (Senso-ji)", city: nil)
        #expect(found.first?.name == "浅草寺")
        let url = try #require(t.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("q=Senso-ji") && !url.contains("浅草寺"))
        t.status = 429
        await #expect(throws: AmapWebError.quota) { try await s.around("浅草寺 (Senso-ji)", center: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02), radiusMeters: 1_000, sort: .weight) }
        t.status = 200
        t.body = Data(#"{"features":[{"properties":{"name":"东京","countrycode":"CN"},"geometry":{"coordinates":[113.0,23.0]}}]}"#.utf8)
        #expect(await s.center("Tokyo, Japan") == nil)
    }
}
