import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// A transport that throws (row 84c: the OSRM request times out).
private final class FailingTransport: HTTPTransport, @unchecked Sendable {
    let error: any Error
    private(set) var calls = 0
    init(_ error: any Error) { self.error = error }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        calls += 1
        throw error
    }
}

@Suite("F-15b §36 item 2c OSRM driving times abroad")
struct OsrmDrivingTimesTests {
    static let table = #"{"code":"Ok","durations":[[0,600.4,null],[590,0,300],[1200,310,0]],"distances":[[0,8000,null],[7900,0,4000],[15000,4100,0]]}"#
    static let points = [GeoCoordinate(latitude: 35.7148, longitude: 139.7967, datum: .gcj02),
                         GeoCoordinate(latitude: 35.6586, longitude: 139.7454, datum: .gcj02),
                         GeoCoordinate(latitude: 35.7101, longitude: 139.8107, datum: .gcj02)]

    @Test("F-15b row 84b: one /table request with lng,lat;… and annotations=duration,distance, 8 s limit; null pair is nil")
    func oneRequest() async throws {
        let t = StubTransport()
        t.body = Data(Self.table.utf8)
        let osrm = OsrmDrivingTimes(transport: t)
        #expect(osrm.answersWholeTable)
        let m = try await osrm.table(Self.points)
        #expect(t.requests.count == 1)
        let request = try #require(t.requests.first)
        let url = try #require(request.url?.absoluteString.removingPercentEncoding)
        #expect(url.hasPrefix("https://router.project-osrm.org/table/v1/driving/139.796700,35.714800;139.745400,35.658600;139.810700,35.710100"))
        #expect(url.contains("annotations=duration,distance"))
        #expect(request.timeoutInterval == 8)
        #expect(m[0][1] == DrivingTime(meters: 8000, seconds: 600))
        #expect(m[0][2] == nil)
        #expect(m[2][1] == DrivingTime(meters: 4100, seconds: 310))
    }

    @Test("F-15b row 84c: timeout → AmapWebError.timeout once (no retry); 429 → quota; code≠Ok or a short row → failed")
    func errors() async {
        let timeout = FailingTransport(URLError(.timedOut))
        await #expect(throws: AmapWebError.timeout) { try await OsrmDrivingTimes(transport: timeout).table(Self.points) }
        #expect(timeout.calls == 1)
        let t = StubTransport()
        t.status = 429
        await #expect(throws: AmapWebError.quota) { try await OsrmDrivingTimes(transport: t).table(Self.points) }
        t.status = 200
        t.body = Data(#"{"code":"NoRoute","durations":[]}"#.utf8)
        await #expect(throws: AmapWebError.failed) { try await OsrmDrivingTimes(transport: t).table(Self.points) }
        t.body = Data(#"{"code":"Ok","durations":[[0,1],[1,0],[2,2]]}"#.utf8)
        await #expect(throws: AmapWebError.failed) { try await OsrmDrivingTimes(transport: t).table(Self.points) }
    }

    @Test("The §26 per-destination form comes from the same one table")
    func perDestination() async throws {
        let t = StubTransport()
        t.body = Data(#"{"code":"Ok","durations":[[0,10,20],[11,0,30],[21,31,0]],"distances":[[0,100,200],[110,0,300],[210,310,0]]}"#.utf8)
        let times = try await OsrmDrivingTimes(transport: t).drivingTimes(origins: Array(Self.points.prefix(2)), destination: Self.points[2])
        #expect(times == [DrivingTime(meters: 200, seconds: 20), DrivingTime(meters: 300, seconds: 30)])
        #expect(t.requests.count == 1)
    }
}
