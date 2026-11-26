import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §71 (T-040zx): Macau and Hong Kong places on 高德 without a city; drive times and guidance on OSRM.

private func sight(_ name: String, city: String) -> JSONValue { ["name": .string(name), "city": .string(city), "minutes": 60] }

private func macau(_ name: String, _ lat: Double, _ lng: Double = 113.55) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, city: "澳门特别行政区", district: nil, adcode: nil, province: "澳门特别行政区")
}

private func mainland(_ name: String, _ lat: Double, city: String, adcode: String = "440402", lng: Double = 113.55) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, city: city, district: nil, adcode: adcode, province: "广东省")
}

/// OSRM table stand-in that keeps every point it was sent.
final class PointOsrm: DrivingTimes, @unchecked Sendable {
    let sent = Mutex<[[GeoCoordinate]]>([])
    var answersWholeTable: Bool { true }
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] { throw AmapWebError.failed }
    func table(_ points: [GeoCoordinate]) async throws -> [[DrivingTime?]] {
        sent.withLock { $0.append(points) }
        return points.map { _ in points.map { _ in DrivingTime(meters: 2_700, seconds: 600) } }
    }
}

/// 高德 times stand-in: every request recorded, 900 s per leg.
final class CountingAmapTimes: DrivingTimes, @unchecked Sendable {
    let calls = Mutex(0)
    func drivingTimes(origins: [GeoCoordinate], destination: GeoCoordinate) async throws -> [DrivingTime?] {
        calls.withLock { $0 += 1 }
        return origins.map { _ in DrivingTime(meters: 9_000, seconds: 900) }
    }
}

private struct TimesRig {
    let planner: TripPlanner
    let lines = TripLines()
    let osrm = PointOsrm()
    let amap = CountingAmapTimes()
    init(search: AmapLookupSearch, answers: [ScriptPlanner.Answer]) async {
        let lines = self.lines
        let clock = ManualClock()
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { GeoCoordinate(latitude: 22.27, longitude: 113.5, datum: .gcj02) },
                              clock: clock, onLine: { lines.append($0) },
                              times: TripTimes(service: amap, clock: clock, retryDelay: .milliseconds(1)),
                              abroadTimes: TripTimes(service: osrm, clock: clock, minGap: .zero),
                              plannerModel: ScriptPlanner(answers))
        await planner.connectCards()
    }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

@Suite("T-040zx F-15b §71 Macau and Hong Kong: places on 高德 without a city, times and guidance on OSRM")
struct TripSarRouteTests {
    @Test("T-040zx F-15b §71 row 335: 澳門, Macau, 氹仔, 「珠海,澳门」, 香港, 尖沙咀 are SAR lookups; 「珠海,澳门」 keeps 澳门 and 珠海 results")
    func row335() {
        for c in ["澳門", "Macau", "MACAO", "氹仔", "珠海,澳门", "路環"] { #expect(TripSar.lookup(city: c)?.regions == [.macau], "\(c)") }
        for c in ["香港", "尖沙咀", "Hong Kong", "九龍", "香港岛"] { #expect(TripSar.lookup(city: c)?.regions == [.hongKong], "\(c)") }
        for c in ["珠海", "广州", "", "长沙"] { #expect(TripSar.lookup(city: c) == nil, "\(c)") }
        let both = TripSar.lookup(city: "珠海,澳门")!
        #expect(both.mainland == ["珠海"])
        #expect(TripSar.keeps(macau("大三巴牌坊", 22.19), both))
        #expect(TripSar.keeps(mainland("珠海渔女", 22.27, city: "珠海市"), both))
        #expect(!TripSar.keeps(mainland("渔人码头", 28.2, city: "长沙市", adcode: "430102"), both))
        // A 香港 lookup keeps no Macau result.
        #expect(!TripSar.keeps(macau("大三巴牌坊", 22.19), TripSar.lookup(city: "尖沙咀")!))
    }

    @Test("T-040zx F-15b §71 row 336: 渔人码头 no-city answer has only 长沙/唐山; item 2b's 澳门渔人码头 finds and keeps the Macau result")
    func row336() async {
        let search = AmapLookupSearch([
            "渔人码头": [mainland("渔人码头", 28.2, city: "长沙市", adcode: "430102"), mainland("渔人码头", 39.6, city: "唐山市", adcode: "130202")],
            "澳门渔人码头": [macau("澳门渔人码头", 22.19)],
        ])
        let s = sight("渔人码头", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        #expect(r.ok && r.data["not_placed"] == nil, "\(r)")
        #expect(search.asked == ["渔人码头", "澳门渔人码头"])
        #expect(search.requests.withLock { $0 }.allSatisfy { $0.city == nil && !$0.cityLimit })
        #expect(await rig.planner.currentPlan.allStops.first?.stop.place.name == "澳门渔人码头")
        #expect(TripSar.prefixed("澳门旅游塔", .macau) == nil && TripSar.prefixed("澳門塔", .macau) == nil)
    }

    @Test("T-040zx F-15b §71 row 337: 澳门威尼斯人度假村 → 澳门上葡京综合度假村 and Ruins of St. Paul's → Public Toilet near Ruins of St. Paul's are rejected by the name check; not_found, no Photon")
    func row337() async {
        #expect(TripSar.core("澳门威尼斯人度假村") == "威尼斯人")
        #expect(!TripSar.nameMatches(asked: "澳门威尼斯人度假村", found: "澳门上葡京综合度假村"))
        #expect(TripSar.nameMatches(asked: "澳门威尼斯人度假村", found: "澳门威尼斯人"))
        #expect(!TripSar.nameMatches(asked: "Ruins of St. Paul's", found: "Public Toilet near Ruins of St. Paul's"))
        #expect(TripSar.nameMatches(asked: "大三巴牌坊", found: "大三巴牌坊"))
        #expect(TripSar.nameMatches(asked: "澳門旅遊塔", found: "澳门旅游塔会展娱乐中心"))
        // Review: characters outside any small table (遊 漁 碼 媽 閣) compare in simplified form too.
        #expect(TripSar.nameMatches(asked: "漁人碼頭", found: "澳门渔人码头"))
        #expect(TripSar.nameMatches(asked: "媽閣廟", found: "妈阁庙"))
        let search = AmapLookupSearch([
            "澳门威尼斯人度假村": [macau("澳门上葡京综合度假村", 22.15)],
            "Ruins of St. Paul's": [macau("Public Toilet near Ruins of St. Paul's", 22.197)],
            "澳门Ruins of St. Paul's": [macau("Public Toilet near Ruins of St. Paul's", 22.197)],
        ])
        let day = [sight("澳门威尼斯人度假村", city: "澳门"), sight("Ruins of St. Paul's", city: "澳门")]
        let rig = await LookupRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        guard case .array(let missed)? = r.data["not_placed"] else { Issue.record("no not_placed: \(r)"); return }
        #expect(missed.map { $0["name"]?.stringValue } == ["澳门威尼斯人度假村", "Ruins of St. Paul's"])
        #expect(missed.allSatisfy { $0["reason"] == "not_found" })
        // 高德 only: the two names, the second once more with 澳门 in front (the first already starts with it).
        #expect(Set(search.asked) == ["澳门威尼斯人度假村", "Ruins of St. Paul's", "澳门Ruins of St. Paul's"] && search.asked.count == 3)
    }

    @Test("T-040zx F-15b §71 row 338: lookup 人民公园, city 珠海: city search as today; no retry")
    func row338() async {
        let search = AmapLookupSearch(["珠海|人民公园": [mainland("人民公园", 22.27, city: "珠海市")]])
        let s = sight("人民公园", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        #expect(search.requests.withLock { $0 }.map { "\($0.city ?? "-")|\($0.cityLimit)" } == ["珠海|true"])
        #expect(rig.line("trip lookup retry=").isEmpty)
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == true)
    }

    @Test("T-040zx F-15b §71 row 339: lookup 大三巴, city 珠海, 大三巴茶餐厅(华发峰尚店): the core matches, kept as today (documented limit)")
    func row339() async {
        #expect(TripSar.nameMatches(asked: "大三巴", found: "大三巴茶餐厅(华发峰尚店)"))
        let search = AmapLookupSearch(["珠海|大三巴": [mainland("大三巴茶餐厅(华发峰尚店)", 22.25, city: "珠海市")]])
        let s = sight("大三巴", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        #expect(search.asked == ["大三巴"] && rig.line("trip lookup retry=").isEmpty)
        #expect(await rig.planner.currentPlan.allStops.first?.stop.place.name == "大三巴茶餐厅(华发峰尚店)")
    }

    @Test("T-040zx F-15b §71 row 340: a 珠海 city lookup answered USER_ABROAD_DAILY_QUERY_OVER_LIMIT: item 3 retry with no city; retry=nocity")
    func row340() async {
        let limit = AmapWebFailure(.quota, info: "USER_ABROAD_DAILY_QUERY_OVER_LIMIT")
        let search = AmapLookupSearch(["珠海渔女": [mainland("珠海渔女", 22.27, city: "珠海市")]], errors: ["珠海渔女": [limit]])
        let s = sight("珠海渔女", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall())
        #expect(r.data["not_placed"] == nil, "\(r)")
        #expect(search.requests.withLock { $0 }.map { "\($0.city ?? "-")|\($0.cityLimit)" } == ["珠海|true", "-|false"])
        #expect(rig.line("trip lookup retry=") == ["trip lookup retry=nocity kept=1"])
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == true)
        // A no-city answer outside the trip's cities is not kept (人民公园 → 北京).
        let far = AmapLookupSearch(["人民公园": [mainland("人民公园", 39.9, city: "北京市", adcode: "110101")]], errors: ["人民公园": [limit]])
        let rig2 = await LookupRig([plannerAnswer([[sight("人民公园", city: "珠海")]]), plannerAnswer([[sight("人民公园", city: "珠海")]])], search: far)
        let r2 = await rig2.run(planCall())
        guard case .array(let missed)? = r2.data["not_placed"] else { Issue.record("no not_placed: \(r2)"); return }
        #expect(missed.first?["reason"] == "map_limit")
        #expect(rig2.line("trip lookup retry=") == ["trip lookup retry=nocity kept=0"])
    }

    @Test("T-040zx F-15b §71 row 341: day 澳门旅游塔 → 新葡京 → 澳门渔人码头 (GCJ-02): times from OSRM with WGS-84 points; vendor=osrm reason=sar")
    func row341() async {
        let places = [macau("澳门旅游塔", 22.1801, 113.5367), macau("新葡京", 22.1907, 113.5434), macau("澳门渔人码头", 22.1937, 113.5583)]
        let search = AmapLookupSearch(Dictionary(uniqueKeysWithValues: places.map { ($0.name, [$0]) }))
        let day = places.map { sight($0.name, city: "澳门") }
        let rig = await TimesRig(search: search, answers: [plannerAnswer([day]), plannerAnswer([day])])
        let r = await rig.planner.execute(planCall("周日去澳门", city: "澳门"))
        #expect(r.ok, "\(r)")
        let sent = rig.osrm.sent.withLock { $0 }
        #expect(sent.count == 1, "\(sent)")
        let expected = places.map { CoordinateConverter.wgs84($0.coordinate) }
        for (got, want) in zip(sent.first ?? [], expected) {
            #expect(abs(got.latitude - want.latitude) < 1e-9 && abs(got.longitude - want.longitude) < 1e-9)
        }
        // The shift is real (hundreds of metres), and the conversion inverts 高德's.
        let p = places[0].coordinate, w = expected[0]
        #expect(abs(p.latitude - w.latitude) + abs(p.longitude - w.longitude) > 0.003)
        let back = CoordinateConverter.gcj02(w)
        #expect(abs(back.latitude - p.latitude) < 1e-7 && abs(back.longitude - p.longitude) < 1e-7)
        #expect(rig.amap.calls.withLock { $0 } == 0)
        // One line per planner round (two rounds here).
        #expect(rig.line("trip times vendor=osrm reason=sar pairs=6").count == 2, "\(rig.line("trip times"))")
        let stops = await rig.planner.currentPlan.allStops.map(\.stop)
        #expect(stops.dropFirst().allSatisfy { $0.legSeconds == 600 })
        // All inside Macau: no border leg.
        #expect(r.data["border"] == nil)
    }

    @Test("T-040zx F-15b §71 row 342: day 珠海站 → 大三巴牌坊 → 珠海长隆海洋王国: both legs OSRM, both border: true; next has the permit sentence once")
    func row342() async {
        let places = [mainland("珠海站", 22.215, city: "珠海市", lng: 113.55), macau("大三巴牌坊", 22.197, 113.540),
                      mainland("珠海长隆海洋王国", 22.10, city: "珠海市", adcode: "440404", lng: 113.53)]
        let search = AmapLookupSearch(Dictionary(uniqueKeysWithValues: places.map { ($0.name, [$0]) }))
        let day = [sight("珠海站", city: "珠海"), sight("大三巴牌坊", city: "澳门"), sight("珠海长隆海洋王国", city: "珠海")]
        let rig = await TimesRig(search: search, answers: [plannerAnswer([day]), plannerAnswer([day])])
        let r = await rig.planner.execute(planCall())
        #expect(r.ok, "\(r)")
        #expect(rig.osrm.sent.withLock { $0 }.count == 1 && rig.amap.calls.withLock { $0 } == 0)
        #expect(r.data["border"] == .bool(true))
        guard case .array(let legs)? = r.data["border_legs"] else { Issue.record("no border_legs: \(r)"); return }
        #expect(legs.count == 2 && legs.allSatisfy { $0["border"] == .bool(true) })
        let next = r.data["next"]?.stringValue ?? ""
        #expect(next.components(separatedBy: TripSar.permitNext).count == 2, "\(next)")
        // The cards say the border time is not counted on both legs into and out of Macau.
        let list = await rig.planner.currentPlan.days[0]
        guard case .cards(let cards) = TripScreen.of(list, moving: false) else { Issue.record("no cards"); return }
        #expect(cards.map(\.border) == [nil, "过关时间未计入", "过关时间未计入"])
        #expect(list.stops.dropFirst().allSatisfy { $0.legSeconds == 600 })
    }

    @Test("T-040zx F-15b §71 row 343: day 珠海渔女 → 圆明新园: 高德 times as today")
    func row343() async {
        let places = [mainland("珠海渔女", 22.27, city: "珠海市"), mainland("圆明新园", 22.25, city: "珠海市")]
        let search = AmapLookupSearch(Dictionary(uniqueKeysWithValues: places.map { ($0.name, [$0]) }))
        let day = places.map { sight($0.name, city: "珠海") }
        let rig = await TimesRig(search: search, answers: [plannerAnswer([day]), plannerAnswer([day])])
        let r = await rig.planner.execute(planCall())
        #expect(r.ok && r.data["border"] == nil, "\(r)")
        #expect(rig.osrm.sent.withLock { $0 }.isEmpty && rig.amap.calls.withLock { $0 } > 0)
        #expect(!rig.line("trip times vendor=amap").isEmpty && rig.line("trip times vendor=osrm").isEmpty)
        let next = r.data["next"]?.stringValue ?? ""
        #expect(!next.isEmpty && !next.contains(TripSar.permitNext), "\(next)")
    }

    @Test("T-040zx F-15b §71 item 4: the planner's system text names SAR places by their common simplified names")
    func item4() {
        #expect(TripPlannerShape.system.contains("- 澳门、香港的地方用地图上常用的简体中文名（如大三巴牌坊、澳门旅游塔、澳门威尼斯人），不要用英文名或别名。"))
    }

    @Test("T-040zx F-15b §71 item 5: guidance to a Macau stop asks for an OSRM route with the datum shift")
    func item5Guidance() {
        let stop = macau("大三巴牌坊", 22.197, 113.540)
        #expect(TripSar.isSarPlace(stop) && !TripSar.isSarPlace(mainland("珠海站", 22.2, city: "珠海市")))
        let request = RouteRequest(destination: stop.coordinate, destinationName: stop.name, sar: true)
        #expect(request.abroad && request.sar)
        #expect(!RouteRequest(destination: stop.coordinate, destinationName: stop.name, abroad: true).sar)
    }
}
