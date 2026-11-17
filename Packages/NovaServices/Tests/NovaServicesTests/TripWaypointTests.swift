import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// Records every request URL; answers a route east along 22.27 N from 113.50 to 113.50 + 4 × `step`.
final class RecordingRouteTransport: HTTPTransport, @unchecked Sendable {
    let urls = Mutex<[URL]>([])
    let step: Double
    init(step: Double = 0.001) { self.step = step }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url!) }
        let p = (0...4).map { String(format: "%.3f,22.27", 113.5 + Double($0) * step) }
        let json = """
        {"status":"1","route":{"paths":[{"distance":"4120","duration":"600","tolls":"0","traffic_lights":"0","steps":[
        {"instruction":"沿A路直行","road":"A路","polyline":"\(p[0]);\(p[1]);\(p[2])"},
        {"instruction":"右转进入B路","road":"B路","polyline":"\(p[2]);\(p[3])"},
        {"instruction":"左转进入C路","road":"C路","polyline":"\(p[3]);\(p[4])"}]}]}}
        """
        return (200, Data(json.utf8))
    }
    func query(_ n: Int, _ name: String) -> String? {
        let url = urls.withLock { $0[n] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// Answers `/v3/distance` with one result per origin; origin 2 has no time.
final class DistanceTransport: HTTPTransport, @unchecked Sendable {
    let urls = Mutex<[URL]>([])
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url!) }
        let json = """
        {"status":"1","results":[{"origin_id":"1","dest_id":"1","distance":"5200","duration":"720"},
        {"origin_id":"3","dest_id":"1","distance":"900","duration":"180"}]}
        """
        return (200, Data(json.utf8))
    }
}

@Suite("T-040n F-15b §26 driving times")
struct TripDrivingTimeTests {
    func at(_ lng: Double) -> GeoCoordinate { GeoCoordinate(latitude: 22.27, longitude: lng, datum: .gcj02) }

    @Test("F-15b §26 item 1: one /v3/distance type=1 request, origins joined by |, times matched by origin_id")
    func distance() async throws {
        let transport = DistanceTransport()
        let client = AmapWebClient(key: { "k" }, transport: transport)
        let times = try await client.drivingTimes(origins: [at(113.5), at(113.6), at(113.7)], destination: at(113.8))
        #expect(times == [DrivingTime(meters: 5200, seconds: 720), nil, DrivingTime(meters: 900, seconds: 180)])
        let url = transport.urls.withLock { $0[0] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/v3/distance")
        #expect(items.first { $0.name == "type" }?.value == "1")
        #expect(items.first { $0.name == "origins" }?.value?.components(separatedBy: "|").count == 3)
    }
}

@Suite("T-040j F-15b §12 place photos")
struct TripPhotoParseTests {
    @Test("F-15b row 19: the detail's first photos[].url is kept, an http link as https; no photos is nil")
    func parse() {
        let body: [String: Any] = ["pois": [
            ["id": "B1", "name": "古文化街", "location": "117.19,39.14",
             "photos": [["titile": "门口", "url": "http://store.is.autonavi.com/showpic/a.jpg"], ["title": "", "url": "https://x.cn/b.jpg"]]],
            ["id": "B2", "name": "五大道", "location": "117.20,39.11", "photos": [Any]()],
            ["id": "B3", "name": "瓷房子", "location": "117.20,39.12"],
        ]]
        let places = AmapWebClient.places(body)
        #expect(places.map { $0.photoURL?.absoluteString } == ["https://store.is.autonavi.com/showpic/a.jpg", nil, nil])
    }
}
