import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

@Suite("T-040v F-15b §50 item 3 Photon inside the trip area")
struct PhotonAreaTests {
    static let station = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"osm_type":"N","osm_id":7,"osm_key":"railway","osm_value":"station","name":"新宿駅","countrycode":"jp"},"geometry":{"type":"Point","coordinates":[139.7006,35.6896]}},{"type":"Feature","properties":{"osm_type":"N","osm_id":8,"name":"Shinjuku","countrycode":"JP"},"geometry":{"type":"Point","coordinates":[139.70,35.69]}}]}"#

    @Test("T-040v F-15b row 145: a trip lookup sends bbox around the centre and limit=5; the city centre carries its countrycode")
    func row145() async throws {
        let t = StubTransport()
        t.body = Data(Self.station.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let centre = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02)
        let found = try await s.inArea("新宿站 (Shinjuku Station)", box: GeoBox.around(centre), limit: 5)
        #expect(found.count == 2)
        let url = try #require(t.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("bbox=139.21000,35.23000,140.31000,36.13000") && url.contains("limit=5") && url.contains("q=Shinjuku Station"))
        #expect(!url.contains("lat="))
        let area = await s.area("Tokyo, Japan")
        #expect(area?.countryCode == "JP" && area?.center.latitude == 35.6896)
    }

    @Test("T-040v F-15b row 146: the found name is shown, not the asked made-up name; asked in brackets only with no shared character")
    func row146() async throws {
        let t = StubTransport()
        t.body = Data(Self.station.utf8)
        let s = PhotonPlaceSearch(transport: t)
        let found = try await s.inArea("新宿附近車站 (Shinjuku Station)", box: GeoBox.around(GeoCoordinate(latitude: 35.68, longitude: 139.76,
                                                                                                         datum: .gcj02)), limit: 5)
        #expect(found.first?.name == "新宿駅")
        #expect(found.first?.kind == .other)
        #expect(found.last?.name == "Shinjuku (新宿附近車站)")
        #expect(PhotonPlaceSearch.shownName(asked: "浅草寺", found: "金龍山 浅草寺") == "金龍山 浅草寺")
        #expect(PhotonPlaceSearch.shownName(asked: nil, found: "Senso-ji") == "Senso-ji")
    }
}
