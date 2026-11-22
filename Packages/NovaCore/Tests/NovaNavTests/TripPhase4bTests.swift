import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// The OSRM table stand-in (F-15b §36 item 2c): one request answers every pair (seconds by latitude, `byLine`), or
/// times out. `perDestination` counts the §26 高德-style requests, which must stay 0 abroad.
final class FakeOsrm: DrivingTimes, @unchecked Sendable {
    let fail: Bool
    let tables = Mutex<[Int]>([])
    let perDestination = Mutex(0)
    init(fail: Bool = false) { self.fail = fail }
    var answersWholeTable: Bool { true }
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        perDestination.withLock { $0 += 1 }
        throw AmapWebError.failed
    }
    func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]] {
        tables.withLock { $0.append(points.count) }
        if fail { throw AmapWebError.timeout }
        return points.map { a in points.map { b in byLine(a, b).map { DrivingTime(meters: $0 * 10, seconds: $0) } } }
    }
}

/// Every 高德 call recorded (row 84d: none abroad).
final class AmapSpy: PlaceSearch, @unchecked Sendable {
    let calls = Mutex<[String]>([])
    func text(_ keywords: String, city: String?) async throws -> [Place] { calls.withLock { $0.append(keywords) }; return [] }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        calls.withLock { $0.append(keywords) }
        return []
    }
    func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        calls.withLock { $0.append(keywords) }
        return []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { calls.withLock { $0.append(keywords) }; return [] }
    func detail(id: String) async throws -> Place? { nil }
}

private let tokyoHere = GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02)
private let fourSights = ["浅草寺", "东京塔", "皇居", "银座"]

private func osrmRig(_ osrm: FakeOsrm) async -> (TripRig, FakeDrivingTimes) {
    let amap = FakeDrivingTimes(byLine)
    let rig = await TripRig(search: TripSearch(tokyo), times: TripTimes(service: amap, clock: ManualClock(), retryDelay: .milliseconds(1)),
                            here: tokyoHere, abroad: FakeApple(tokyo),
                            abroadTimes: TripTimes(service: osrm, clock: ManualClock()))
    return (rig, amap)
}

private func navigate(_ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("n1")!, name: "navigate_to", arguments: .object(args))
}

@Suite("T-040p F-15b §36 items 2c–2d: OSRM times and plain searches abroad")
struct TripPhase4bTests {
    // MARK: §36 item 2c OSRM

    @Test("F-15b §36 item 2c: two different OSRM tables back to back are at least 1 request per second apart")
    func osrmRate() async {
        let osrm = FakeOsrm()
        let times = TripTimes(service: osrm, clock: ManualClock(), minGap: .milliseconds(300))
        let a = TripTimes.Node(key: "a", coordinate: tokyoHere)
        let b = TripTimes.Node(key: "b", coordinate: GeoCoordinate(latitude: 35.71, longitude: 139.8, datum: .gcj02))
        let c = TripTimes.Node(key: "c", coordinate: GeoCoordinate(latitude: 35.72, longitude: 139.8, datum: .gcj02))
        let began = ContinuousClock.now
        let first = await times.table(start: a, stops: [b])
        let second = await times.table(start: a, stops: [c])
        #expect(first != nil && second != nil)
        #expect(osrm.tables.withLock { $0 } == [2, 2])
        #expect(ContinuousClock.now - began >= .milliseconds(300))
    }

    @Test("F-15b §36 item 2c: at home §26 is unchanged: 高德 per destination, no OSRM, vendor=amap")
    func homeUnchanged() async {
        let osrm = FakeOsrm()
        let amap = FakeDrivingTimes(byLine)
        let rig = await TripRig(times: TripTimes(service: amap, clock: ManualClock(), retryDelay: .milliseconds(1)),
                                abroadTimes: TripTimes(service: osrm, clock: ManualClock()))
        let r = await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼"]), "city": "天津"]))
        #expect(r.ok)
        #expect(osrm.tables.withLock { $0 }.isEmpty)
        #expect(amap.requests.withLock { $0 } > 0)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip times vendor=amap") })
    }

    @Test("F-15b §36 item 2c: the OSRM table is cached; a second table of the same places makes no request")
    func cached() async {
        let osrm = FakeOsrm()
        let times = TripTimes(service: osrm, clock: ManualClock())
        let nodes = [TripTimes.Node(key: "a", coordinate: tokyoHere),
                     TripTimes.Node(key: "b", coordinate: GeoCoordinate(latitude: 35.71, longitude: 139.8, datum: .gcj02))]
        let first = await times.table(start: nil, stops: nodes)
        let second = await times.table(start: nil, stops: nodes)
        #expect(first?.requests == 1 && second?.requests == 0)
        #expect(second?.time(0, 1) == 100)
        #expect(osrm.tables.withLock { $0 } == [2])
    }

    // MARK: §36 item 2d navigate_to abroad

    private func navRig(photon: FakeApple, phone: GeoCoordinate = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .wgs84))
        async -> (NavigationController, AmapSpy, TripLines, TripLines) {
        let amap = AmapSpy()
        let lines = TripLines()
        let fix = LocationFix(coordinate: phone, horizontalAccuracyMeters: 20, timestamp: .zero)
        let nav = NavigationController(search: amap, engine: ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)]),
                                       location: FixLocation(fix: fix), clock: ManualClock(),
                                       onTripLine: { lines.append($0) })
        await nav.start()
        let cities = TripLines()
        await nav.setAbroad(search: photon, center: { city in
            cities.append(city)
            return GeoCoordinate(latitude: 35.6812, longitude: 139.7671, datum: .gcj02)
        })
        return (nav, amap, lines, cities)
    }

    @Test("F-15b row 84d (§51 item 8): 附近的租车 near=here with the phone in Tokyo: one Photon search for 租车 around the phone, no 高德; candidates listed; nav search vendor=photon")
    func row84d() async {
        let rentals = [jp("Toyota Rent a Car", lat: 35.681), jp("Times Car Rental", lat: 35.679)]
        let photon = FakeApple(["租车": rentals])
        let (nav, amap, lines, cities) = await navRig(photon: photon)
        let r = await nav.execute(navigate(["destination": "附近的租车", "near": "here"]))
        #expect(r.ok && r.data["status"] == "candidates_listed" && r.data["count"] == .int(2))
        // 「租车」 is Photon's amenity:car_rental tag search (NovaServices PhotonPlaceSearchTests).
        #expect(photon.asked.withLock { $0 } == ["租车"])
        #expect(photon.centers.withLock { $0 }.map { [$0.latitude, $0.longitude] } == [[35.68, 139.76]])
        #expect(cities.withLock { $0 }.isEmpty)
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(lines.withLock { $0 }.contains { $0.hasPrefix("nav search vendor=photon abroad=yes found=2 ms=") })
    }

    @Test("F-15b §36 item 2d (§51 item 8): a named place abroad (near=place) is searched around its centre; a CN result is dropped")
    func namedAroundCentre() async {
        let photon = FakeApple(["浅草寺 (Senso-ji)": [jp("浅草寺", lat: 35.71), jp("浅草寺", lat: 22.2, lng: 113.5, country: "CN")]])
        let (nav, amap, lines, cities) = await navRig(photon: photon)
        _ = await nav.execute(navigate(["destination": "浅草寺 (Senso-ji)", "near": "place", "near_name": "东京", "near_country": "JP"]))
        #expect(cities.withLock { $0 } == ["东京"])
        #expect(photon.centers.withLock { $0 }.first?.latitude == 35.6812)
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(lines.withLock { $0 }.contains { $0.hasPrefix("nav search vendor=photon abroad=yes found=1 ms=") })
    }

    @Test("F-15b §51 item 1: near=here with the phone in China is the home search (高德); Photon is not asked")
    func noTripDefault() async {
        let photon = FakeApple(["加油站": [jp("ENEOS", lat: 35.70), jp("Shell", lat: 35.69)]])
        let (nav, amap, _, cities) = await navRig(photon: photon, phone: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .wgs84))
        _ = await nav.execute(navigate(["destination": "附近的加油站", "near": "here"]))
        #expect(cities.withLock { $0 }.isEmpty && photon.asked.withLock { $0 }.isEmpty)
        #expect(amap.calls.withLock { $0 }.first == "加油站")
    }

    @Test("F-15b row 84e (§51 item 8): navigate_to near=place without near_name: invalidFields, no lookup")
    func row84e() async {
        let photon = FakeApple([:])
        let (nav, amap, _, cities) = await navRig(photon: photon)
        let r = await nav.execute(navigate(["destination": "浅草寺 (Senso-ji)", "near": "place", "near_country": "JP"]))
        #expect(!r.ok && r.code == .invalidFields)
        #expect(photon.asked.withLock { $0 }.isEmpty && amap.calls.withLock { $0 }.isEmpty && cities.withLock { $0 }.isEmpty)
    }
}
