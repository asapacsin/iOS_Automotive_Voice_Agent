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

    init(phone: GeoCoordinate, home: any PlaceSearch, photon: FakeApple, demo: Bool = false) async {
        let fix = LocationFix(coordinate: phone, horizontalAccuracyMeters: 20, timestamp: .zero)
        let lines = self.lines
        let location: any LocationProvider = demo ? DemoLocation(fix: fix) : FixLocation(fix: fix)
        nav = NavigationController(search: home, engine: ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)]),
                                   location: location, clock: ManualClock(), onTripLine: { lines.append($0) })
        await nav.start()
        let geocoded = self.geocoded
        await nav.setAbroad(search: photon, center: { _ in tokyoCentre }, area: { name in
            geocoded.append(name)
            return name.contains("Springfield") ? TripArea(center: springfield, countryCode: "US")
                : TripArea(center: tokyoCentre, countryCode: "JP")
        })
    }

    func near() -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix("nav near ") } }

    /// An abroad Tokyo trip made, open and shown, over this controller.
    func tokyoTrip() async -> TripPlanner {
        let planner = TripPlanner(search: TripSearch(tokyo), navigation: nav, origin: { tokyoCentre }, clock: ManualClock(),
                                  abroadSearch: FakeApple(tokyo))
        await planner.connectCards()
        let made = await planner.execute(trip("make_trip_list", ["places": names(["浅草寺", "东京塔"]), "abroad": true,
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
    @Test("F-15b §51 row 176: Zhuhai, Tokyo trip shown, 咖啡店 near=here: 高德 around the phone; facts searched_around the phone and trip_city Tokyo; nav near kind=here vendor=amap source=fix")
    func row176() async {
        let home = FakeApple(["咖啡店": [place("瑞幸", 300), place("星巴克", 600)]])
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await NearRig(phone: zhuhai, home: home, photon: photon)
        let planner = await rig.tokyoTrip()
        let r = await rig.nav.execute(nav(["destination": "咖啡店", "near": "here"]))
        #expect(await planner.cardsHidden == false)
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(home.centers.withLock { $0 }.allSatisfy { $0 == CoordinateConverter.gcj02(zhuhai) })
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(r.data["facts"]?["searched_around"] == "手机位置" && r.data["facts"]?["trip_city"] == "Tokyo, Japan")
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
        #expect(rig.near() == ["nav near kind=place vendor=photon source=geocode found=0 dropped=0 reason=country_mismatch"])
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
        #expect(r.code == .tripHidden && r.advice == TripPlanner.tripHiddenNext)
        #expect(photon.asked.withLock { $0 }.isEmpty)
        #expect(rig.near() == ["nav near kind=trip vendor=amap source=trip found=0 dropped=0 reason=trip_hidden"])
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
        #expect(amap.calls.withLock { $0 }.isEmpty && photon.asked.withLock { $0 }.isEmpty)
        #expect(await rig.nav.current.phase == .idle)
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
