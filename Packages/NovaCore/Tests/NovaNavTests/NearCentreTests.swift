import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

private let zhuhai = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .wgs84)
private let tokyoPhone = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .wgs84)
private let tokyoCentre = GeoCoordinate(latitude: 35.6812, longitude: 139.7671, datum: .gcj02)
private let springfield = GeoCoordinate(latitude: 39.80, longitude: -89.64, datum: .gcj02)
private let hotel = GeoCoordinate(latitude: 35.69, longitude: 139.70, datum: .gcj02)

private func nav(_ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("n1")!, name: "navigate_to", arguments: .object(args))
}

/// 高德 `/v3/geocode/geo` stand-in: every name asked, one fixed answer or error.
final class FakeGeocode: PlaceLookup, @unchecked Sendable {
    let answer: Result<[LookedUpPlace], AmapWebError>
    let asked = Mutex<[String]>([])
    init(_ answer: Result<[LookedUpPlace], AmapWebError>) { self.answer = answer }
    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        asked.withLock { $0.append(name) }
        return try answer.get()
    }
}

/// A 高德 geocode that answers only when `release()` is called (a slow geocode).
final class SlowGeocode: PlaceLookup, @unchecked Sendable {
    let asked = Mutex<Int>(0)
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let open = Mutex(false)
    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        await withCheckedContinuation { c in
            let now = open.withLock { $0 }
            if now { c.resume() } else { gate.withLock { $0 = c } }
            asked.withLock { $0 += 1 }
        }
        return [LookedUpPlace(name: name, coordinate: place("x", 0).coordinate)]
    }
    func release() {
        open.withLock { $0 = true }
        gate.withLock { $0?.resume(); $0 = nil }
    }
    func waitAsked() async { while asked.withLock({ $0 }) == 0 { await Task.yield() } }
}

/// The demo point (位置来源 off): the provider's fix is `DriveSettings.demoOrigin`, its source `.demo`.
private struct DemoLocation: LocationProvider {
    let fix: LocationFix
    func latestFix() async -> LocationFix? { fix }
    var source: LocationSource { .demo }
}

/// A controller with the phone at `phone` (or the demo point), 高德 `home`, Photon `photon`; a geocode abroad
/// answers Tokyo (JP) or, for 「Springfield」, a point in the US.
private struct NearRig {
    let nav: NavigationController
    let lines = TripLines()
    let geocoded = TripLines()

    /// `area`: what Photon's area lookup answers (default: Tokyo, or the US for Springfield); `.some(nil)` none, so
    /// `centre` (Apple's bare centre) is used.
    init(phone: GeoCoordinate, home: any PlaceSearch, photon: FakeApple, demo: Bool = false,
         geocode: (any PlaceLookup)? = nil, area: TripArea?? = .none, centre: GeoCoordinate = tokyoCentre) async {
        let fix = LocationFix(coordinate: phone, horizontalAccuracyMeters: 20, timestamp: .zero)
        let lines = self.lines
        let location: any LocationProvider = demo ? DemoLocation(fix: fix) : FixLocation(fix: fix)
        nav = NavigationController(search: home, engine: ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)]),
                                   location: location, clock: ManualClock(), onTripLine: { lines.append($0) })
        await nav.start()
        let geocoded = self.geocoded
        await nav.setAbroad(search: photon, center: { _ in centre }, area: { name in
            geocoded.append(name)
            if let area { return area }
            return name.contains("Springfield") ? TripArea(center: springfield, countryCode: "US")
                : TripArea(center: tokyoCentre, countryCode: "JP")
        })
        if let geocode { await nav.setHomeGeocode(geocode) }
    }

    func near() -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix("nav near ") } }

    /// An abroad Tokyo trip made, open and shown, over this controller.
    func tokyoTrip() async -> TripPlanner {
        let planner = TripPlanner(search: TripSearch(tokyo), navigation: nav, origin: { tokyoCentre }, clock: ManualClock(),
                                  abroadSearch: FakeApple(tokyo))
        await planner.connectCards()
        let made = await planner.execute(planCall(["places": names(["浅草寺", "东京塔"]), "abroad": true,
                                                                 "city": "Tokyo, Japan"]))
        #expect(made.ok)
        #expect(await planner.cardsHidden == false)
        return planner
    }
}

private func stop(_ day: Int, _ name: String, _ role: TripRole, _ at: GeoCoordinate) -> NearTripStop {
    NearTripStop(day: day, name: name, asked: name, role: role, coordinate: at, countryCode: "JP")
}

private let tokyoStops = [stop(1, "浅草寺", .sight, GeoCoordinate(latitude: 35.7148, longitude: 139.7967, datum: .gcj02)),
                          stop(1, "Hotel Gracery", .hotel, hotel),
                          stop(2, "上野公园", .sight, GeoCoordinate(latitude: 35.7156, longitude: 139.7745, datum: .gcj02)),
                          stop(2, "上野动物园", .sight, GeoCoordinate(latitude: 35.7164, longitude: 139.7713, datum: .gcj02))]

@Suite("T-040z F-15b §51 item 8: the model names the search centre; code resolves and checks it")
struct NearCentreTests {
    @Test("F-15b §51 row 176 (cards hidden since item 9): Zhuhai, Tokyo trip hidden, 咖啡店 near=here: 高德 around the phone; facts searched_around the phone, no trip_city; nav near kind=here vendor=amap source=fix")
    func row176() async {
        let home = FakeApple(["咖啡店": [place("瑞幸", 300), place("星巴克", 600)]])
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await NearRig(phone: zhuhai, home: home, photon: photon)
        let planner = await rig.tokyoTrip()
        #expect(await planner.hideCards())
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(home.centers.withLock { $0 }.allSatisfy { $0 == CoordinateConverter.gcj02(zhuhai) })
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(r.data["facts"]?["searched_around"] == "手机位置" && r.data["facts"]?["trip_city"] == nil)
        #expect(r.data["facts"]?["vendor"] == "amap" && r.data["facts"]?["found"] == .int(2))
        #expect(rig.near() == ["nav near kind=here vendor=amap source=fix found=2 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 row 177: phone fix in Tokyo, no trip, 便利店 near=here: Photon around the phone; no 高德 request")
    func row177() async {
        let amap = AmapSpy()
        let photon = FakeApple(["便利店": [jp("Lawson", lat: 35.681), jp("FamilyMart", lat: 35.679)]])
        let rig = await NearRig(phone: tokyoPhone, home: amap, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "here"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(photon.centers.withLock { $0 }.map { [$0.latitude, $0.longitude] } == [[35.68, 139.76]])
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(r.data["facts"]?["trip_city"] == nil && r.data["facts"]?["vendor"] == "photon")
        #expect(rig.near() == ["nav near kind=here vendor=photon source=fix found=2 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 row 178: 位置来源 off, 咖啡店 near=here: around demoOrigin; facts say 演示位置; source=demo")
    func row178() async {
        let demoOrigin = GeoCoordinate(latitude: 22.27, longitude: 113.58, datum: .wgs84)
        let home = FakeApple(["咖啡店": [place("瑞幸", 300), place("星巴克", 600)]])
        let rig = await NearRig(phone: demoOrigin, home: home, photon: FakeApple([:]), demo: true)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(r.ok)
        #expect(home.centers.withLock { $0 } == [CoordinateConverter.gcj02(demoOrigin)])
        #expect(r.data["facts"]?["searched_around"] == "演示位置")
        #expect(rig.near().first?.contains("source=demo") == true)
    }

    @Test("F-15b §51 row 179: phone in Zhuhai, 便利店 near=place 东京 JP: Photon around Tokyo's centre, JP and 50 km only; source=geocode vendor=photon")
    func row179() async {
        let amap = AmapSpy()
        let stores = [jp("Lawson", lat: 35.69, lng: 139.77), jp("Lawson Osaka", lat: 34.7, lng: 135.5),
                      jp("GS25", lat: 35.69, lng: 139.77, country: "KR")]
        let photon = FakeApple(["便利店": stores])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "东京", "near_country": "JP"]))
        #expect(r.ok)
        #expect(rig.geocoded.withLock { $0 } == ["东京"])
        #expect(photon.centers.withLock { $0 } == [tokyoCentre])
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(await rig.nav.current.destination?.name == "Lawson")
        #expect(r.data["facts"]?["searched_around"] == "东京" && r.data["facts"]?["vendor"] == "photon")
        #expect(rig.near() == ["nav near kind=place vendor=photon source=geocode found=1 dropped=2 reason=ok"])
    }

    @Test("F-15b §51 row 180: near=place 香洲 CN: 高德 geocode and 高德 search")
    func row180() async {
        let home = FakeApple(["香洲": [place("香洲区", 0)], "便利店": [place("美宜佳", 300), place("7-Eleven", 500)]])
        let photon = FakeApple([:])
        let rig = await NearRig(phone: zhuhai, home: home, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "香洲", "near_country": "CN"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(home.asked.withLock { $0 } == ["香洲", "便利店"])
        #expect(home.centers.withLock { $0 } == [place("香洲区", 0).coordinate])
        #expect(photon.asked.withLock { $0 }.isEmpty && rig.geocoded.withLock { $0 }.isEmpty)
        #expect(rig.near() == ["nav near kind=place vendor=amap source=geocode found=2 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 row 181: near=place Springfield JP, geocoded in the US: no search; countryMismatch with the found country; reason=country_mismatch")
    func row181() async {
        let amap = AmapSpy()
        let photon = FakeApple(["餐厅": [jp("Diner", lat: 39.8, lng: -89.6, country: "US")]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "place", "near_name": "Springfield", "near_country": "JP"]))
        #expect(r.ok == false && r.code == .countryMismatch)
        #expect(r.data["facts"]?["found_country"] == "US" && r.data["facts"]?["near_country"] == "JP")
        #expect(photon.asked.withLock { $0 }.isEmpty && amap.calls.withLock { $0 }.isEmpty)
        #expect(rig.near() == ["nav near kind=place vendor=none source=geocode found=0 dropped=0 reason=country_mismatch"])
        #expect(await rig.nav.current.phase == .idle)
    }

    @Test("F-15b §51 row 182: Tokyo trip shown, day 1 hotel saved, 餐厅 near=trip 第一天的酒店: around the hotel's saved coordinates; Photon; source=trip")
    func row182() async {
        let photon = FakeApple(["餐厅": [jp("Ichiran", lat: 35.691, lng: 139.70), jp("Sushi", lat: 35.689, lng: 139.70)]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        await rig.nav.setNearTrip { NearTrip(hidden: false, abroad: true, city: "Tokyo, Japan", stops: tokyoStops) }
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "第一天的酒店"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(photon.centers.withLock { $0 } == [hotel])
        #expect(r.data["facts"]?["searched_around"] == "行程第1天Hotel Gracery")
        #expect(rig.near() == ["nav near kind=trip vendor=photon source=trip found=2 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 row 182 (planner): near=trip 浅草寺 on the shown Tokyo trip is centred on the stop's saved coordinates")
    func row182Planner() async {
        let photon = FakeApple(["餐厅": [jp("Ichiran", lat: 35.711), jp("Sushi", lat: 35.709)]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        let planner = await rig.tokyoTrip()
        let saved = await planner.currentPlan.allStops.first { $0.stop.place.name == "浅草寺" }?.stop.place.coordinate
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "浅草寺"]))
        #expect(r.ok)
        #expect(saved != nil && photon.centers.withLock { $0 } == [saved!])
    }

    @Test("F-15b §51 row 183: the same with the cards hidden: tripHidden as item 2; no search")
    func row183() async {
        let photon = FakeApple(["餐厅": [jp("Ichiran", lat: 35.711)]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        let planner = await rig.tokyoTrip()
        #expect(await planner.hideCards())
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "浅草寺"]))
        #expect(r.code == .tripHidden && r.advice == nil && r.data["next"]?.stringValue == TripPlanner.tripHiddenNext
              && r.data["facts"] == TripPlanner.tripHiddenResult.data["facts"])
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(rig.near() == ["nav near kind=trip vendor=none source=trip found=0 dropped=0 reason=trip_hidden"])
        #expect(await planner.cardsHidden)
    }

    @Test("F-15b §51 row 184: near=trip matching two stops: ambiguous with both names; matching none: notFound with the plan's stop names")
    func row184() async {
        let photon = FakeApple(["餐厅": [jp("Ichiran", lat: 35.711)]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        await rig.nav.setNearTrip { NearTrip(hidden: false, abroad: true, city: "Tokyo, Japan", stops: tokyoStops) }
        let two = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "上野"]))
        #expect(two.code == .ambiguous && two.data["facts"]?["matches"] == ["上野公园", "上野动物园"])
        let none = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "晴空塔"]))
        #expect(none.code == .notFound)
        #expect(none.data["facts"]?["stops"] == ["浅草寺", "Hotel Gracery", "上野公园", "上野动物园"])
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(rig.near().map { $0.hasSuffix("reason=ambiguous") || $0.hasSuffix("reason=not_found") } == [true, true])
    }

    @Test("F-15b §51 row 185: near missing; near=route while not guiding: invalidFields, no search")
    func row185() async {
        #expect(ToolCatalog.validate("navigate_to", ["destination": "咖啡店"]) == .invalidFields)
        #expect(ToolCatalog.validate("navigate_to", ["destination": "咖啡店", "near": "there"]) == .invalidFields)
        let dispatched = ToolCatalog.validate(nav(["destination": "咖啡店"]))
        #expect(dispatched == .invalidFields)
        let amap = AmapSpy()
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let route = await rig.nav.execute(nav(["destination": "加油站", "near": "route"]))
        #expect(route.code == .invalidFields)
        let unknown = await rig.nav.execute(nav(["destination": "加油站", "near": "there"]))
        #expect(unknown.code == .invalidFields)
        // F-09b §13: facts and rules, no hand-written sentence.
        #expect(route.advice == nil && route.data["facts"]?["navigating"] == false && route.data["may"] == ["offer_nearby"])
        #expect(unknown.advice == nil && unknown.data["facts"]?["near"] == "there"
                && unknown.data["facts"]?["near_allowed"] == ["here", "place", "trip", "route"])
        let noCountry = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "东京"]))
        #expect(noCountry.advice == nil && noCountry.data["facts"]?["missing"] == ["near_country"])
        #expect(amap.calls.withLock { $0 }.isEmpty && photon.asked.withLock { $0 }.isEmpty)
        #expect(await rig.nav.current.phase == .idle)
    }

    @Test("F-15b §51 row 189: near_country 日本 is JP; a name not in the table, or JPN, counts as missing")
    func row189() async {
        #expect(NavigationController.nearCountry("日本") == "JP" && NavigationController.nearCountry(" jp ") == "JP")
        #expect(NavigationController.nearCountry("澳门") == "MO" && NavigationController.nearCountry("中国") == "CN")
        #expect(NavigationController.nearCountry("火星") == nil && NavigationController.nearCountry("JPN") == nil)
        #expect(NavigationController.nearCountry("") == nil && NavigationController.nearCountry(nil) == nil)
        let amap = AmapSpy()
        let photon = FakeApple(["便利店": [jp("Lawson", lat: 35.69, lng: 139.77)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "东京", "near_country": "日本"]))
        #expect(r.ok && r.data["facts"]?["vendor"] == "photon")
        let odd = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "东京", "near_country": "火星"]))
        #expect(odd.code == .invalidFields && odd.data["facts"]?["missing"] == ["near_country"])
    }

    @Test("F-15b §51 row 186: schema: navigate_to has near, near_name, near_country; no abroad, no city; catalog text as item 8")
    func row186() throws {
        let spec = try #require(ToolCatalog.spec("navigate_to"))
        let schema = spec.declaration.parametersJSONSchema
        let props = schema["properties"]
        #expect(props?["near"]?["enum"] == ["here", "place", "trip", "route"])
        #expect(props?["near_name"]?["type"] == "string" && props?["near_country"]?["type"] == "string")
        #expect(props?["abroad"] == nil && props?["city"] == nil)
        #expect(schema["required"] == ["destination", "near"])
        let text = "near：司机说「附近」「这儿」或没说地点时填 here；说了某个地方（城市、景点、地址）填 place，并填 near_name 和 near_country；说的是行程里的地方（「酒店附近」「第一天那个景点」）填 trip，只在行程打开时可用；导航中问「路上」填 route。拿不准司机指的是哪里时，先问司机一句，不要猜。"
        #expect(spec.declaration.description.hasSuffix(text))
        #expect(ToolCatalog.validate("navigate_to", ["destination": "便利店", "near": "place", "near_name": "东京", "near_country": "JP"]) == nil)
        #expect(ToolCatalog.validate("navigate_to", ["destination": "A", "near": "here", "abroad": true]) == .invalidFields)
        #expect(ToolCatalog.validate("navigate_to", ["destination": "A", "near": "here", "city": "Tokyo, Japan"]) == .invalidFields)
        #expect(ToolCatalog.validate("navigate_to", ["destination": "A", "near": "place", "near_country": "JPN"]) == .invalidFields)
        #expect(ToolCatalog.validate("navigate_to", ["destination": "A", "near": "place", "near_name": " "]) == .invalidFields)
        #expect(ToolCatalog.validate("navigate_to", ["near": "here"]) == .invalidFields)
    }

    @Test("F-15b §51 item 8: near=route while guiding lists along the route; source=route")
    func routeWhileGuiding() async {
        let home = FakeApple(["加油站": [place("中石化", 300), place("中石油", 600)], "万达": [place("万达", 1_000)]])
        let rig = await NearRig(phone: zhuhai, home: home, photon: FakeApple([:]))
        #expect(await rig.nav.execute(nav(["destination": "万达"])).ok)
        #expect(await rig.nav.current.navigating)
        let r = await rig.nav.execute(nav(["destination": "加油站", "near": "route"]))
        #expect(r.ok && r.data["status"] == "candidates_listed_over_guidance")
        #expect(rig.near() == ["nav near kind=route vendor=amap source=route found=2 dropped=0 reason=ok"])
    }

    // MARK: Review fixes (2e425fa)

    @Test("F-15b §51 item 8: near=place with near_country MO or HK geocodes and searches on 高德, never Photon")
    func macauHongKong() async {
        for (name, country) in [("澳门", "MO"), ("香港", "HK"), ("台北", "TW")] {
            let home = FakeApple(["便利店": [place("全家", 300), place("7-11", 500)]])
            let photon = FakeApple(["便利店": [jp("Hotel", lat: 35.69)]])
            let geocode = FakeGeocode(.success([LookedUpPlace(name: name, coordinate: place("x", 0).coordinate)]))
            let rig = await NearRig(phone: zhuhai, home: home, photon: photon, geocode: geocode)
            let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": .string(name),
                                               "near_country": .string(country)]))
            #expect(r.ok, "\(country)")
            #expect(geocode.asked.withLock { $0 } == [name])
            #expect(photon.asked.withLock { $0 }.isEmpty && rig.geocoded.withLock { $0 }.isEmpty, "\(country)")
            #expect(rig.near() == ["nav near kind=place vendor=amap source=geocode found=2 dropped=0 reason=ok"], "\(country)")
        }
    }

    @Test("F-15b §51 item 8: a newer navigate_to during a slow near=place geocode wins; the old one is optionsStale, no route")
    func slowGeocodeNewerWins() async {
        let home = FakeApple(["便利店": [place("美宜佳", 300), place("7-Eleven", 500)], "咖啡店": [place("瑞幸", 300)]])
        let geocode = SlowGeocode()
        let rig = await NearRig(phone: zhuhai, home: home, photon: FakeApple([:]), geocode: geocode)
        let nav0 = rig.nav
        let old = Task { await nav0.execute(nav(["destination": "便利店", "near": "place", "near_name": "香洲", "near_country": "CN"])) }
        await geocode.waitAsked()
        #expect(await rig.nav.current.phase == .resolvingDestination)
        let newer = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(newer.ok)
        let before = await rig.nav.current
        geocode.release()
        let r = await old.value
        #expect(r.code == .optionsStale)
        #expect(home.asked.withLock { $0 } == ["咖啡店"])
        let after = await rig.nav.current
        #expect(after.generation == before.generation)
        #expect(after.phase == before.phase)
        #expect(after.destination?.name == "瑞幸" && after.destination == before.destination)
        #expect(rig.near() == ["nav near kind=here vendor=amap source=fix found=1 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 item 8: exit_navigation_mode during a slow near=place geocode cancels it; nothing searched")
    func slowGeocodeCancelled() async {
        let home = FakeApple(["便利店": [place("美宜佳", 300)]])
        let geocode = SlowGeocode()
        let rig = await NearRig(phone: zhuhai, home: home, photon: FakeApple([:]), geocode: geocode)
        let nav0 = rig.nav
        let old = Task { await nav0.execute(nav(["destination": "便利店", "near": "place", "near_name": "香洲", "near_country": "CN"])) }
        await geocode.waitAsked()
        let cancel = await rig.nav.execute(ToolCall(id: CallID("x1")!, name: "exit_navigation_mode", arguments: .object([:])))
        #expect(cancel.data["status"] == "navigation_selection_cancelled")
        geocode.release()
        #expect(await old.value.code == .optionsStale)
        #expect(home.asked.withLock { $0 }.isEmpty && rig.near().isEmpty)
        #expect(await rig.nav.current.phase == .idle)
    }

    @Test("F-15b §51 item 8: 高德 geocode errors give their cause (key, quota, network), not not_found")
    func geocodeFailure() async {
        for (error, code) in [(AmapWebError.keyMissing, ToolErrorCode.amapWebKeyMissing), (.quota, .liveInfoQuota),
                              (.timeout, .liveInfoUnavailable)] {
            let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple([:]), geocode: FakeGeocode(.failure(error)))
            let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "香洲", "near_country": "CN"]))
            #expect(r.code == code, "\(error)")
            #expect(rig.near() == ["nav near kind=place vendor=none source=geocode found=0 dropped=0 reason=failed"])
        }
    }

    @Test("F-15b §51 item 8: a trip stop in Osaka with countryCode JP (inside China's box) is searched on Photon")
    func osakaStop() async {
        let osaka = GeoCoordinate(latitude: 34.69, longitude: 135.50, datum: .gcj02)
        #expect(CoordinateConverter.outOfChina(osaka.latitude, osaka.longitude) == false)
        let amap = AmapSpy()
        let photon = FakeApple(["餐厅": [jp("Kani Doraku", lat: 34.69, lng: 135.50), jp("Ichiran", lat: 34.70, lng: 135.50)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        await rig.nav.setNearTrip { NearTrip(hidden: false, abroad: true, city: "Osaka, Japan",
                                             stops: [stop(1, "大阪城", .sight, osaka)]) }
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "大阪城"]))
        #expect(r.ok && photon.centers.withLock { $0 } == [osaka] && amap.calls.withLock { $0 }.isEmpty)
        #expect(rig.near().first?.hasPrefix("nav near kind=trip vendor=photon") == true)
    }

    @Test("F-15b §51 item 8: near=place 大阪 JP (inside China's box) is searched on Photon by its country")
    func osakaPlace() async {
        let osaka = GeoCoordinate(latitude: 34.69, longitude: 135.50, datum: .gcj02)
        let amap = AmapSpy()
        let photon = FakeApple(["餐厅": [jp("Kani Doraku", lat: 34.69, lng: 135.50)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon, area: TripArea(center: osaka, countryCode: "JP"))
        let r = await rig.nav.execute(nav(["destination": "餐厅", "near": "place", "near_name": "大阪", "near_country": "JP"]))
        #expect(r.ok && photon.centers.withLock { $0 } == [osaka] && amap.calls.withLock { $0 }.isEmpty)
        #expect(rig.near() == ["nav near kind=place vendor=photon source=geocode found=1 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 item 8: Apple's bare centre fallback gives no country; the box is not taken as China (Seoul, KR)")
    func appleFallback() async {
        let seoul = GeoCoordinate(latitude: 37.57, longitude: 126.98, datum: .gcj02)
        let photon = FakeApple(["咖啡店": [jp("Starbucks", lat: 37.57, lng: 126.98, country: "KR")]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon, area: .some(nil), centre: seoul)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "place", "near_name": "首尔", "near_country": "KR"]))
        #expect(r.ok && r.code == nil)
        #expect(photon.centers.withLock { $0 } == [seoul])
    }

    @Test("F-15b §51 item 8: near=place without near_country: invalidFields, nothing searched")
    func placeWithoutCountry() async {
        let amap = AmapSpy()
        let photon = FakeApple([:])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "place", "near_name": "东京"]))
        #expect(r.code == .invalidFields)
        #expect(amap.calls.withLock { $0 }.isEmpty && photon.asked.withLock { $0 }.isEmpty && rig.geocoded.withLock { $0 }.isEmpty)
    }

    @Test("F-15b §51 item 8: no usable fix: the facts do not say 手机位置")
    func noFix() async {
        let home = FakeApple(["咖啡店": [place("瑞幸", 300), place("星巴克", 600)]])
        let nav0 = NavigationController(search: home, engine: ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)]),
                                        location: NoLocation(), clock: ManualClock())
        await nav0.start()
        let r = await nav0.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(r.data["facts"]?["searched_around"] == "没有定位" && r.data["facts"]?["located"] == false)
    }

    @Test("T-040za F-15b §51 item 9: cards shown, the vendor goes by the next stop's country: a China trip (Tianjin) on 高德 around the stop, a Seoul trip (KR, inside the China box) on Photon")
    func tripHereVendorByStopCountry() async {
        let tianjin = GeoCoordinate(latitude: 39.13, longitude: 117.2, datum: .gcj02)
        let seoul = GeoCoordinate(latitude: 37.57, longitude: 126.98, datum: .gcj02)
        let china = NearTrip(hidden: false, abroad: false, city: nil,
                             stops: [NearTripStop(day: 1, name: "古文化街", asked: "古文化街", role: .sight, coordinate: tianjin,
                                                  countryCode: "CN")])
        let home = FakeApple(["咖啡店": [place("瑞幸", 300)]])
        let rigCN = await NearRig(phone: zhuhai, home: home, photon: FakeApple([:]))
        await rigCN.nav.setNearTrip { china }
        let r1 = await rigCN.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(home.centers.withLock { $0 } == [tianjin])
        #expect(r1.data["facts"]?["searched_around"] == "行程位置（古文化街）" && r1.data["facts"]?["vendor"] == "amap")
        #expect(r1.data["facts"]?["trip_city"] == nil)

        let korea = NearTrip(hidden: false, abroad: true, city: "Seoul, Korea",
                             stops: [NearTripStop(day: 1, name: "景福宫", asked: "景福宫", role: .sight, coordinate: seoul,
                                                  countryCode: "KR")])
        let amap = AmapSpy()
        let photon = FakeApple(["咖啡店": [jp("Ediya", lat: 37.57, lng: 126.98, country: "KR")]])
        let rigKR = await NearRig(phone: zhuhai, home: amap, photon: photon,
                                  area: .some(TripArea(center: seoul, countryCode: "KR")))
        await rigKR.nav.setNearTrip { korea }
        let r2 = await rigKR.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(r2.data["facts"]?["vendor"] == "photon" && r2.data["facts"]?["source"] == "trip_here")
        #expect(rigKR.near() == ["nav near kind=here vendor=photon source=trip_here found=1 dropped=0 reason=ok"])
    }

    @Test("F-15b §51 item 8: near=here abroad keeps to 50 km (an Osaka result for a Tokyo phone is dropped)")
    func hereAbroadRange() async {
        let photon = FakeApple(["便利店": [jp("Lawson", lat: 35.681), jp("Lawson Osaka", lat: 34.7, lng: 135.5)]])
        let rig = await NearRig(phone: tokyoPhone, home: AmapSpy(), photon: photon)
        let r = await rig.nav.execute(nav(["destination": "便利店", "near": "here"]))
        #expect(r.ok && r.data["count"] == nil && r.data["status"] != "candidates_listed")
        #expect(rig.near() == ["nav near kind=here vendor=photon source=fix found=1 dropped=1 reason=ok"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("nav search vendor=photon abroad=yes found=1 ") })
    }

    @Test("F-15b §51 item 8: near=trip with the cards hidden also logs trip blocked tool=navigate_to reason=hidden")
    func hiddenLogsBlocked() async {
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple([:]))
        await rig.nav.setNearTrip { NearTrip(hidden: true, abroad: true, city: "Tokyo, Japan", stops: tokyoStops) }
        _ = await rig.nav.execute(nav(["destination": "餐厅", "near": "trip", "near_name": "浅草寺"]))
        #expect(rig.lines.withLock { $0 }.contains("trip blocked tool=navigate_to reason=hidden"))
    }

    @Test("F-15b §51 item 8: trip stop matching by name, day and role")
    func matching() {
        let trip = NearTrip(hidden: false, abroad: true, city: nil, stops: tokyoStops)
        #expect(trip.match("第一天的酒店").map(\.name) == ["Hotel Gracery"])
        #expect(trip.match("浅草寺").map(\.name) == ["浅草寺"])
        #expect(trip.match("第2天那个景点").map(\.name) == ["上野公园", "上野动物园"])
        #expect(trip.match("酒店").map(\.name) == ["Hotel Gracery"])
        #expect(trip.match("晴空塔").isEmpty)
        #expect(NearTrip.day(in: "第三天") == 3 && NearTrip.day(in: "酒店") == nil)
    }
}

@Suite("T-040za F-15b §51 item 9: cards shown, 附近 is the trip location; cards hidden, the phone")
struct TripHereTests {
    @Test("T-040za F-15b §51 row 190: phone in Zhuhai, Tokyo trip shown, no guidance, 咖啡店 near=here: Photon around the next stop; searched_around 行程位置（…）; source=trip_here; no 高德 request")
    func row190() async {
        let amap = AmapSpy()
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.71, lng: 139.79)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon)
        let planner = await rig.tokyoTrip()
        let next = await planner.nearTrip()?.next
        #expect(next != nil && next?.day == 1)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(amap.calls.withLock { $0 }.isEmpty)
        #expect(photon.asked.withLock { $0 } == ["咖啡店"])
        #expect(r.data["facts"]?["searched_around"] == .string("行程位置（\(next?.name ?? "")）"))
        #expect(r.data["facts"]?["source"] == "trip_here" && r.data["facts"]?["vendor"] == "photon")
        #expect(r.data["facts"]?["trip_city"] == nil)
        #expect(rig.near().count == 1 && rig.near()[0].hasPrefix("nav near kind=here vendor=photon source=trip_here "))
    }

    @Test("T-040za F-15b §51 item 9: the next stop is the current day's first stop not marked; a visited first stop moves it to the second")
    func nextSkipsMarked() async {
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple([:]))
        let planner = await rig.tokyoTrip()
        let stops = await planner.nearTrip()?.stops ?? []
        #expect(stops.count == 2)
        await planner.markForTests(index: 1, .visited)
        #expect(await planner.nearTrip()?.next?.name == stops.last?.name)
    }

    @Test("T-040za F-15b §51 row 191: a trip stop guidance in 模拟导航 with the simulated car in Tokyo: around the car; searched_around 行程位置（模拟车）")
    func row191() async {
        let car = GeoCoordinate(latitude: 35.70, longitude: 139.75, datum: .gcj02)
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.701, lng: 139.751)]])
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        let planner = await rig.tokyoTrip()
        await rig.nav.setSimulatedCar { car }
        #expect(await rig.nav.tripNext(jp("浅草寺", lat: 35.71), abroad: true).ok)
        let flow = await rig.nav.current
        #expect(flow.tripStopID != nil && flow.mode == .emulator && flow.navigating)
        #expect(await planner.cardsHidden == false)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(photon.asked.withLock { $0 } == ["咖啡店"])
        #expect(r.data["facts"]?["searched_around"] == "行程位置（模拟车）" && r.data["facts"]?["source"] == "trip_here")
        #expect(rig.near().count == 1 && rig.near()[0].hasPrefix("nav near kind=here vendor=photon source=trip_here "))
    }

    @Test("T-040za F-15b §51 row 191 (Osaka): the simulated car in Osaka (inside the China box) on a JP trip is searched on Photon by the trip's country, never 高德")
    func row191Osaka() async {
        let car = GeoCoordinate(latitude: 34.69, longitude: 135.50, datum: .gcj02)
        let osaka = NearTrip(hidden: false, abroad: true, city: "Osaka, Japan",
                             stops: [NearTripStop(day: 1, name: "大阪城", asked: "大阪城", role: .sight,
                                                  coordinate: GeoCoordinate(latitude: 34.687, longitude: 135.526, datum: .gcj02),
                                                  countryCode: "JP")])
        let amap = AmapSpy()
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 34.691, lng: 135.501)]])
        let rig = await NearRig(phone: zhuhai, home: amap, photon: photon,
                                area: .some(TripArea(center: car, countryCode: "JP")))
        await rig.nav.setNearTrip { osaka }
        await rig.nav.setSimulatedCar { car }
        #expect(await rig.nav.tripNext(jp("大阪城", lat: 34.687, lng: 135.526), abroad: true).ok)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(amap.calls.withLock { $0 }.isEmpty && photon.asked.withLock { $0 } == ["咖啡店"])
        #expect(r.data["facts"]?["searched_around"] == "行程位置（模拟车）" && r.data["facts"]?["vendor"] == "photon")
    }

    @Test("T-040za F-15b §51 row 191 (no car): no trip stop guidance, a car hook set: the next stop, not the car")
    func row191NoGuidance() async {
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple(["咖啡店": [jp("Doutor", lat: 35.71)]]))
        let planner = await rig.tokyoTrip()
        await rig.nav.setSimulatedCar { GeoCoordinate(latitude: 35.0, longitude: 135.0, datum: .gcj02) }
        let next = await planner.nearTrip()?.next?.name ?? ""
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(r.data["facts"]?["searched_around"] == .string("行程位置（\(next)）"))
    }

    @Test("T-040za F-15b §51 row 192: same trip, cards hidden: near=here is the phone on 高德, as row 176")
    func row192() async {
        let home = FakeApple(["咖啡店": [place("瑞幸", 300)]])
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await NearRig(phone: zhuhai, home: home, photon: photon)
        #expect(await rig.tokyoTrip().hideCards())
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(home.centers.withLock { $0 }.allSatisfy { $0 == CoordinateConverter.gcj02(zhuhai) })
        #expect(r.data["facts"]?["searched_around"] == "手机位置" && r.data["facts"]?["source"] == nil)
        #expect(rig.near() == ["nav near kind=here vendor=amap source=fix found=1 dropped=0 reason=ok"])
    }

    @Test("T-040za F-15b §51 row 193: cards shown, navigate_to 珠海站 near=place near_country=CN: 高德 geocode and search as item 8, not the trip")
    func row193() async {
        let station = GeoCoordinate(latitude: 22.215, longitude: 113.55, datum: .gcj02)
        let home = FakeApple(["咖啡店": [place("瑞幸", 300)]])
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let geocode = FakeGeocode(.success([LookedUpPlace(name: "珠海站", coordinate: station)]))
        let rig = await NearRig(phone: zhuhai, home: home, photon: photon, geocode: geocode)
        let planner = await rig.tokyoTrip()
        #expect(await planner.cardsHidden == false)
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "place", "near_name": "珠海站", "near_country": "CN"]))
        #expect(geocode.asked.withLock { $0 } == ["珠海站"])
        #expect(home.centers.withLock { $0 } == [station] && photon.asked.withLock { $0 }.isEmpty)
        #expect(r.data["facts"]?["searched_around"] == "珠海站" && r.data["facts"]?["source"] == nil)
    }

    @Test("T-031p F-09b §14 row 2: the 现在 note's center is the trip's next stop while the cards are shown, the phone when hidden")
    func contextCenter() async {
        let rig = await NearRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple([:]))
        await rig.nav.setNearTrip { NearTrip(hidden: false, abroad: true, city: "Tokyo, Japan", stops: tokyoStops) }
        let shown = await rig.nav.contextCenter()
        #expect(shown?.trip == "浅草寺" && shown?.coordinate == tokyoStops[0].coordinate)
        await rig.nav.setNearTrip { NearTrip(hidden: true, abroad: true, city: "Tokyo, Japan", stops: tokyoStops) }
        let hidden = await rig.nav.contextCenter()
        #expect(hidden != nil && hidden?.trip == nil)
    }
}
