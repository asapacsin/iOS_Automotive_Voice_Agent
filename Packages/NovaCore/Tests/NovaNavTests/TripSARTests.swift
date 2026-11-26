import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §70 (T-040zw) and §71 (T-040zx): Macau and Hong Kong places on 高德 without a city (kept by adcode, else
/// province; name-checked), drive times touching them on OSRM with WGS-84 points, border legs flagged.

private let abroadLimit = AmapWebFailure(.quota, info: "USER_ABROAD_DAILY_QUERY_OVER_LIMIT")

private func sarSight(_ name: String, city: String) -> JSONValue { ["name": .string(name), "city": .string(city), "minutes": 60] }

/// A 高德 v3 result: no adcode for Macau/Hong Kong, the SAR in `pname`.
private func v3(_ name: String, _ lat: Double, _ lng: Double = 113.55, province: String? = "澳门特别行政区",
                city: String? = nil, adcode: String? = nil) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, city: city ?? province, district: nil, adcode: adcode, province: province)
}

/// OSRM stand-in that records the points of each table request.
final class PointsOsrm: DrivingTimes, @unchecked Sendable {
    let asked = Mutex<[[GeoCoordinate]]>([])
    var answersWholeTable: Bool { true }
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] { throw AmapWebError.failed }
    func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]] {
        asked.withLock { $0.append(points) }
        return points.map { a in points.map { b in DrivingTime(meters: 1000, seconds: Int(abs(a.latitude - b.latitude) * 10_000) + 60) } }
    }
}

/// 高德 times stand-in that records every coordinate it is asked about.
final class AmapTimesSpy: DrivingTimes, @unchecked Sendable {
    let points = Mutex<[GeoCoordinate]>([])
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        points.withLock { $0.append(contentsOf: origins + [destination]) }
        return origins.map { _ in DrivingTime(meters: 1000, seconds: 600) }
    }
}

private struct SARRig {
    let planner: TripPlanner
    let search: AmapLookupSearch
    let osrm = PointsOsrm()
    let amap = AmapTimesSpy()
    let lines = TripLines()
    init(_ answers: [ScriptPlanner.Answer], search: AmapLookupSearch) async {
        let lines = self.lines
        self.search = search
        let clock = ManualClock()
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { nil }, clock: clock, onLine: { lines.append($0) },
                              times: TripTimes(service: amap, clock: clock, retryDelay: .milliseconds(1)),
                              abroadTimes: TripTimes(service: osrm, clock: clock, minGap: .milliseconds(1)),
                              plannerModel: ScriptPlanner(answers))
        await planner.connectCards()
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

@Suite("T-040zw F-15b §70 Macau and Hong Kong results kept by province when 高德 v3 gives no adcode")
struct TripSARProvinceTests {
    @Test("T-040zw F-15b §70 row 329: 大三巴牌坊 with no adcode, pname 澳门特别行政区, kept by province; a 珠海 result (440402) dropped")
    func row329() async {
        let macau = v3("大三巴牌坊", 22.197), zhuhai = mapPlace("大三巴牌坊", 22.27, city: "珠海市", adcode: "440402")
        #expect(SpecialRegion.keptBy(macau, in: .macau) == .province)
        #expect(SpecialRegion.keptBy(zhuhai, in: .macau) == nil)
        let search = AmapLookupSearch(["大三巴牌坊": [zhuhai, macau]])
        let s = sarSight("大三巴牌坊", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        #expect(r.ok, "\(r)")
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.province == "澳门特别行政区" && stop?.place.coordinate.latitude == 22.197)
        #expect(TripPlannerShape.cityOf(macau) == "澳门")
    }

    @Test("T-040zw F-15b §70 row 330: lookup city 澳门 with only a 香港特别行政区 result: not kept; nomatch; dropped=1 kept_by=none")
    func row330() async {
        let search = AmapLookupSearch(["大三巴牌坊": [v3("大三巴牌坊", 22.3, 114.17, province: "香港特别行政区")]])
        let s = sarSight("大三巴牌坊", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        guard case .array(let missed)? = r.data["not_placed"] else { Issue.record("no not_placed: \(r)"); return }
        #expect(missed.first?["reason"] == "not_found")
        #expect(rig.line("trip lookup name=") == ["trip lookup name=大三巴牌坊 city=澳门 info=none dropped=1 kept_by=none"])
    }

    @Test("T-040zw F-15b §70 row 331: a v5-style result with adcode 820002 is kept by adcode, as §68")
    func row331() {
        let p = mapPlace("大三巴牌坊", 22.197, city: "澳门", adcode: "820002")
        #expect(SpecialRegion.keptBy(p, in: .macau) == .adcode && SpecialRegion.keptBy(p, in: .hongKong) == nil)
        #expect(SpecialRegion.region(of: mapPlace("x", 22.3, city: "香港", adcode: "810001")) == .hongKong)
    }
}

@Suite("T-040zx F-15b §71 Macau and Hong Kong: places on 高德 without a city, times and guidance on OSRM")
struct TripSARRouteTests {
    @Test("T-040zx F-15b §71 row 335: 澳門, Macau, 氹仔, 「珠海,澳门」, 香港, 尖沙咀 are SAR lookups; 「珠海,澳门」 keeps 澳门 and 珠海 results")
    func row335() async {
        for c in ["澳門", "Macau", "氹仔", "珠海,澳门"] { #expect(SpecialRegion.lookup(c)?.regions == [.macau], "\(c)") }
        for c in ["香港", "尖沙咀"] { #expect(SpecialRegion.lookup(c)?.regions == [.hongKong], "\(c)") }
        #expect(SpecialRegion.lookup("珠海") == nil && SpecialRegion.lookup("珠海,澳门")?.mainland == ["珠海"])
        let search = AmapLookupSearch(["大三巴": [mapPlace("大三巴茶餐厅", 22.27, city: "珠海市", adcode: "440402")],
                                       "旅游塔": [v3("澳门旅游塔", 22.18)]])
        let day = [sarSight("大三巴", city: "珠海,澳门"), sarSight("旅游塔", city: "珠海,澳门")]
        let rig = await LookupRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        _ = await rig.run(planCall("去澳门", city: "珠海,澳门"))
        let stops = await rig.planner.currentPlan.allStops.map(\.stop)
        #expect(stops.map(\.placed) == [true, true], "\(stops.map(\.place.name))")
        #expect(search.requests.withLock { $0 }.allSatisfy { $0.city == nil && !$0.cityLimit })
    }

    @Test("T-040zx F-15b §71 row 336: 渔人码头 with only 长沙/唐山 results keeps nothing; 澳门渔人码头 then finds the Macau one")
    func row336() async {
        let search = AmapLookupSearch([
            "渔人码头": [mapPlace("渔人码头", 28.2, city: "长沙市", adcode: "430102"), mapPlace("渔人码头", 39.6, city: "唐山市", adcode: "130203")],
            "澳门渔人码头": [v3("澳门渔人码头", 22.19)],
        ])
        let s = sarSight("渔人码头", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall("去澳门", city: "澳门"))
        #expect(search.requests.withLock { $0 }.map(\.keywords).prefix(2) == ["渔人码头", "澳门渔人码头"])
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.name == "澳门渔人码头")
    }

    @Test("T-040zx F-15b §71 row 337: 上葡京 for 澳门威尼斯人度假村 and the toilet for Ruins of St. Paul's are rejected; not_found, no Photon")
    func row337() async {
        #expect(!SpecialRegion.nameMatches(asked: "澳门威尼斯人度假村", found: "澳门上葡京综合度假村"))
        #expect(!SpecialRegion.nameMatches(asked: "Ruins of St. Paul's", found: "Public Toilet near Ruins of St. Paul's"))
        #expect(SpecialRegion.nameMatches(asked: "澳门威尼斯人度假村", found: "澳门威尼斯人"))
        #expect(SpecialRegion.nameMatches(asked: "大三巴牌坊", found: "大三巴牌坊"))
        let search = AmapLookupSearch(["澳门威尼斯人度假村": [v3("澳门上葡京综合度假村", 22.15)],
                                       "Ruins of St. Paul's": [v3("Public Toilet near Ruins of St. Paul's", 22.197)]])
        let day = [sarSight("澳门威尼斯人度假村", city: "澳门"), sarSight("Ruins of St. Paul's", city: "澳门")]
        let rig = await LookupRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall("去澳门", city: "澳门"))
        guard case .array(let missed)? = r.data["not_placed"] else { Issue.record("no not_placed: \(r)"); return }
        #expect(missed.compactMap { $0["reason"]?.stringValue } == ["not_found", "not_found"])
        // Only 高德 was asked (the rig has no Photon); the second gets the 澳门 retry, the first already starts with it.
        #expect(Set(search.requests.withLock { $0 }.map(\.keywords)) == ["澳门威尼斯人度假村", "Ruins of St. Paul's", "澳门Ruins of St. Paul's"])
    }

    @Test("T-040zx F-15b §71 row 338: 人民公园, city 珠海: city search as today; no retry")
    func row338() async {
        let search = AmapLookupSearch(["珠海|人民公园": [mapPlace("人民公园", 22.27, city: "珠海市", adcode: "440402")]])
        let s = sarSight("人民公园", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        #expect(search.requests.withLock { $0 }.allSatisfy { $0.city == "珠海" && $0.cityLimit })
        #expect(rig.line("trip lookup retry=").isEmpty)
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == true)
    }

    @Test("T-040zx F-15b §71 row 339: 大三巴, city 珠海, city search returns 大三巴茶餐厅(华发峰尚店): the core matches, kept as today")
    func row339() async {
        let search = AmapLookupSearch(["珠海|大三巴": [mapPlace("大三巴茶餐厅(华发峰尚店)", 22.27, city: "珠海市", adcode: "440402")]])
        let s = sarSight("大三巴", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        #expect(rig.line("trip lookup retry=").isEmpty)
        #expect(await rig.planner.currentPlan.allStops.first?.stop.place.name == "大三巴茶餐厅(华发峰尚店)")
    }

    @Test("T-040zx F-15b §71 row 340: city 珠海 answering USER_ABROAD_DAILY_QUERY_OVER_LIMIT: retried with no city; retry=nocity")
    func row340() async {
        let search = AmapLookupSearch(["珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")]],
                                      errors: ["珠海渔女": [abroadLimit]])
        let s = sarSight("珠海渔女", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        let requests = search.requests.withLock { $0 }
        #expect(requests.count == 2 && requests[0].city == "珠海" && requests[1].city == nil, "\(requests)")
        #expect(rig.line("trip lookup retry=") == ["trip lookup retry=nocity kept=1"])
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == true)
    }

    @Test("T-040zx F-15b §71 row 341: 澳门旅游塔 → 新葡京 → 澳门渔人码头: OSRM with WGS-84 points; vendor=osrm reason=sar")
    func row341() async {
        let tower = v3("澳门旅游塔", 22.180, 113.536), lisboa = v3("新葡京", 22.190, 113.543), wharf = v3("澳门渔人码头", 22.193, 113.557)
        let search = AmapLookupSearch(["澳门旅游塔": [tower], "新葡京": [lisboa], "澳门渔人码头": [wharf]])
        let day = ["澳门旅游塔", "新葡京", "澳门渔人码头"].map { sarSight($0, city: "澳门") }
        let rig = await SARRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall("去澳门", city: "澳门"))
        #expect(r.ok, "\(r)")
        let asked = rig.osrm.asked.withLock { $0 }
        #expect(!asked.isEmpty)
        let sent = asked.last ?? []
        let expected = [tower, lisboa, wharf].map { CoordinateConverter.wgs84($0.coordinate) }
        #expect(sent.count == 3 && sent.allSatisfy { $0.datum == .wgs84 })
        #expect(zip(sent, expected).allSatisfy { abs($0.latitude - $1.latitude) < 1e-9 && abs($0.longitude - $1.longitude) < 1e-9 })
        // The shift is real (hundreds of metres), and the inverse round-trips.
        #expect(SelfPosition.distanceMeters(sent[0], tower.coordinate) > 200)
        #expect(SelfPosition.distanceMeters(CoordinateConverter.gcj02(sent[0]), tower.coordinate) < 1)
        #expect(!rig.line("trip times vendor=osrm reason=sar").isEmpty && rig.line("trip times vendor=amap").isEmpty, "\(rig.line("trip times"))")
        #expect(rig.amap.points.withLock { $0 }.isEmpty)
        #expect(await rig.planner.currentPlan.days[0].stops.dropFirst().allSatisfy { $0.legSeconds != nil })
    }

    @Test("T-040zx F-15b §71 row 342: 珠海站 → 大三巴牌坊 → 珠海长隆海洋王国: both legs OSRM and border; next has the permit sentence once")
    func row342() async {
        let station = mapPlace("珠海站", 22.215, city: "珠海市", adcode: "440402")
        let ruins = v3("大三巴牌坊", 22.197, 113.540)
        let ocean = mapPlace("珠海长隆海洋王国", 22.100, city: "珠海市", adcode: "440404")
        let search = AmapLookupSearch(["珠海|珠海站": [station], "大三巴牌坊": [ruins], "珠海|珠海长隆海洋王国": [ocean]])
        let day = [sarSight("珠海站", city: "珠海"), sarSight("大三巴牌坊", city: "澳门"), sarSight("珠海长隆海洋王国", city: "珠海")]
        let rig = await SARRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall("从珠海出发去澳门", city: "珠海"))
        #expect(r.ok, "\(r)")
        guard case .array(let borders)? = r.data["border_legs"] else { Issue.record("no border_legs: \(r)"); return }
        #expect(borders.count == 2 && borders.allSatisfy { $0["border"] == .bool(true) })
        let next = r.data["next"]?.stringValue ?? ""
        #expect(next.components(separatedBy: TripBorder.permitNext).count == 2, "\(next)")
        #expect(!rig.line("trip times vendor=osrm reason=sar").isEmpty && rig.line("trip times vendor=amap").isEmpty)
        // The 高德 point of 珠海站 also goes to OSRM as WGS-84.
        #expect(rig.osrm.asked.withLock { $0 }.last?.allSatisfy { $0.datum == .wgs84 } == true)
        // The cards: 「过关时间未计入」 on both border legs.
        let list = await rig.planner.current
        guard case .cards(let cards) = TripScreen.of(list, moving: false) else { Issue.record("no cards"); return }
        #expect(cards.map(\.border) == [false, true, true])
    }

    @Test("T-040zx F-15b §71 row 343: 珠海渔女 → 圆明新园: 高德 times as today")
    func row343() async {
        let search = AmapLookupSearch(["珠海|珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")],
                                       "珠海|圆明新园": [mapPlace("圆明新园", 22.24, city: "珠海市", adcode: "440402")]])
        let day = [sarSight("珠海渔女", city: "珠海"), sarSight("圆明新园", city: "珠海")]
        let rig = await SARRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall())
        #expect(r.ok && r.data["border_legs"] == nil, "\(r)")
        #expect(rig.osrm.asked.withLock { $0 }.isEmpty)
        #expect(!rig.line("trip times vendor=amap").isEmpty && rig.line("trip times vendor=osrm").isEmpty)
    }

    @Test("T-040zx F-15b §71 item 4: the planner's system text names Macau and Hong Kong places by their common simplified names")
    func item4() {
        #expect(TripPlannerShape.system.contains("澳门、香港的地方用地图上常用的简体中文名（如大三巴牌坊、澳门旅游塔、澳门威尼斯人），不要用英文名或别名。"))
    }
}
