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

private func navCall(_ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("n1")!, name: "navigate_to", arguments: .object(args))
}

/// A navigation controller with the phone at `phone`, 高德 `home`, Photon `photon` and Tokyo's area known.
private struct SeparateRig {
    let nav: NavigationController
    let engine: ScriptedNaviEngine
    let lines = TripLines()
    let areas = TripLines()

    init(phone: GeoCoordinate, home: any PlaceSearch, photon: FakeApple) async {
        engine = ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)])
        let fix = LocationFix(coordinate: phone, horizontalAccuracyMeters: 20, timestamp: .zero)
        let lines = self.lines
        nav = NavigationController(search: home, engine: engine, location: FixLocation(fix: fix), clock: ManualClock(),
                                   onTripLine: { lines.append($0) })
        await nav.start()
        let areas = self.areas
        await nav.setAbroad(search: photon, center: { _ in tokyoCentre }, area: { city in
            areas.append(city)
            return TripArea(center: tokyoCentre, countryCode: "JP")
        })
    }

    /// An abroad Tokyo trip made, open and shown, over this controller.
    func tokyoTrip() async -> TripPlanner {
        let planner = TripPlanner(search: TripSearch(tokyo), navigation: nav, origin: { tokyoCentre }, clock: ManualClock(),
                                  abroadSearch: FakeApple(tokyo))
        await planner.connectCards()
        let made = await planner.execute(planCall(["places": names(["浅草寺", "东京塔"]), "abroad": true,
                                                                 "city": "Tokyo, Japan"]))
        #expect(made.ok)
        #expect(await !planner.cardsHidden)
        return planner
    }
}

@Suite("T-040y F-15b §51 plain navigation separate from the trip")
struct TripNavSeparateTests {
    @Test("F-15b §51 row 161 (cards hidden since item 9): Zhuhai, Tokyo trip hidden, navigate_to 附近的咖啡店 (no abroad): 高德 around the phone, no Photon, no abroad=yes")
    func row161() async {
        let amap = AmapSpy()
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await SeparateRig(phone: zhuhai, home: amap, photon: photon)
        #expect(await rig.tokyoTrip().hideCards())
        _ = await rig.nav.execute(navCall(["destination": "附近的咖啡店", "near": "here"]))
        #expect(amap.calls.withLock { $0 }.contains("咖啡店"))
        #expect(photon.asked.withLock { $0 }.isEmpty && rig.areas.withLock { $0 }.isEmpty)
        #expect(rig.lines.withLock { $0 }.allSatisfy { !$0.contains("abroad=yes") })
    }

    @Test("F-15b §51 row 162 (cards hidden since item 9): Tokyo trip hidden, navigate_to 浅草寺 (no abroad): home search, the trip is not consulted")
    func row162() async {
        let amap = AmapSpy()
        let photon = FakeApple(tokyo)
        let rig = await SeparateRig(phone: zhuhai, home: amap, photon: photon)
        #expect(await rig.tokyoTrip().hideCards())
        _ = await rig.nav.execute(navCall(["destination": "浅草寺", "near": "here"]))
        #expect(!amap.calls.withLock { $0 }.isEmpty)
        #expect(photon.asked.withLock { $0 }.isEmpty && rig.areas.withLock { $0 }.isEmpty)
        #expect(rig.lines.withLock { $0 }.allSatisfy { !$0.hasPrefix("nav search vendor=photon") })
    }

    @Test("F-15b §51 row 163: phone in Zhuhai, 便利店 near=place 东京 JP (was abroad=true city Tokyo) (and 附近的便利店): Photon around Tokyo's centre, JP and 50 km only, no trip")
    func row163() async {
        let stores = [jp("Lawson", lat: 35.69, lng: 139.77), jp("Lawson Osaka", lat: 34.7, lng: 135.5),
                      jp("GS25", lat: 35.69, lng: 139.77, country: "KR")]
        for destination in ["便利店", "附近的便利店"] {
            let amap = AmapSpy()
            let photon = FakeApple(["便利店": stores])
            let rig = await SeparateRig(phone: zhuhai, home: amap, photon: photon)
            let r = await rig.nav.execute(navCall(["destination": .string(destination), "near": "place", "near_name": "Tokyo, Japan", "near_country": "JP"]))
            #expect(r.ok, "\(destination)")
            #expect(photon.centers.withLock { $0 } == [tokyoCentre])
            #expect(rig.areas.withLock { $0 } == ["Tokyo, Japan"])
            #expect(amap.calls.withLock { $0 }.isEmpty)
            #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("nav search vendor=photon abroad=yes found=1 ") && $0.hasSuffix(" area_dropped=2") })
            #expect(await rig.nav.current.destination?.name == "Lawson")
        }
    }

    @Test("F-15b §51 row 164: phone in Tokyo, 附近的便利店 near=here (was abroad=true city Tokyo): Photon around the phone")
    func row164() async {
        let photon = FakeApple(["便利店": [jp("Lawson", lat: 35.681), jp("FamilyMart", lat: 35.679)]])
        let rig = await SeparateRig(phone: tokyoPhone, home: AmapSpy(), photon: photon)
        let r = await rig.nav.execute(navCall(["destination": "附近的便利店", "near": "here"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(photon.centers.withLock { $0 }.map { [$0.latitude, $0.longitude] } == [[35.68, 139.76]])
        #expect(rig.areas.withLock { $0 }.isEmpty)
    }

    @Test("F-15b §51 row 165: cards hidden: trip_next and a set_trip_plan change each return tripHidden; plan unchanged; still hidden")
    func row165() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼"])]))
        #expect(await rig.planner.hideCards())
        let before = await rig.order()
        let calls = [trip("trip_next"), await sameCall(rig)]
        for call in calls {
            let r = await rig.run(call)
            // §52 item 2: the refusal carries the plan too; otherwise it is the fixed refusal.
            #expect(r.code == .tripHidden && r.advice == nil && r.data.filter { $0.key != "plan" } == TripPlanner.tripHiddenResult.data,
                    "\(call.name)")
            #expect(rig.lines.withLock { $0 }.contains("trip blocked tool=\(call.name) reason=hidden"))
        }
        #expect(await rig.order() == before)
        #expect(await rig.planner.cardsHidden)
        #expect(await !rig.nav.current.navigating)
        #expect(ToolFailureAdvice.forCode(.tripHidden) == nil && TripPlanner.tripHiddenNext.hasPrefix("用自己的话简短地说。"))
    }

    @Test("F-15b §51 row 166: cards hidden: trip_plans open and a new plan (set_trip_plan, §55 item 1) each run and show the cards")
    func row166() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        #expect(await rig.run(trip("trip_plans", ["action": "save", "name": "天津一日游"])).ok)
        let calls = [trip("trip_plans", ["action": "open", "name": "天津一日游"]),
                     planCall(["places": names(["天津之眼"])])]
        for call in calls {
            #expect(await rig.planner.hideCards())
            let r = await rig.run(call)
            #expect(r.ok, "\(call.name)")
            #expect(await !rig.planner.cardsHidden, "\(call.name)")
        }
    }

    @Test("F-15b §51 row 167: cards hidden; trip_plans list runs and the cards stay hidden")
    func row167() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        #expect(await rig.planner.hideCards())
        #expect(await rig.run(trip("trip_plans", ["action": "list"])).ok)
        #expect(await rig.planner.cardsHidden)
    }

    @Test("F-15b §51 row 168: restore() with a saved current plan: plan loaded, cards hidden, trip load … hidden=yes")
    func row168() async {
        let files = MemoryTripFiles()
        let first = await PlanRig(files: files)
        _ = await first.run(planCall(["places": names(["古文化街", "五大道"])]))
        let second = await PlanRig(files: files)
        await second.planner.restore()
        #expect(await second.planner.currentPlan.stopCount == 2)
        #expect(await second.planner.cardsHidden)
        #expect(second.lines.withLock { $0 }.contains("trip cards hidden=yes"))
        #expect(second.lines.withLock { $0 }.contains("trip load ok=yes days=1 stops=2 hidden=yes"))
    }

    @Test("F-15b §51 row 173: abroad trip stop guidance, phone in Zhuhai; navigate_to 附近的咖啡店: trip stop ended, 高德 around the phone, new route not abroad")
    func row173() async {
        let home = FakeApple(["咖啡店": [place("瑞幸", 300), place("星巴克", 600)]])
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69)]])
        let rig = await SeparateRig(phone: zhuhai, home: home, photon: photon)
        #expect(await rig.nav.tripNext(jp("浅草寺", lat: 35.71), abroad: true).ok)
        #expect(await rig.nav.current.tripStopID != nil)
        _ = await rig.nav.execute(navCall(["destination": "附近的咖啡店", "near": "here"]))
        #expect(await rig.nav.current.tripStopID == nil)
        #expect(photon.asked.withLock { $0 }.isEmpty && rig.areas.withLock { $0 }.isEmpty)
        #expect(home.asked.withLock { $0 }.contains("咖啡店"))
        let centre = CoordinateConverter.gcj02(zhuhai)
        #expect(home.centers.withLock { $0 }.allSatisfy { $0 == centre })
        _ = await rig.nav.execute(ToolCall(id: CallID("c1")!, name: "choose_navigation_option", arguments: ["index": .int(1)]))
        // The route request carries no start: the engine's origin (the phone's fix or the demo point) is the start.
        #expect(rig.engine.requests.withLock { $0 }.map(\.abroad) == [true, false])
    }

    @Test("F-15b §51 row 173 (abroad): trip stop guidance, navigate_to 附近的咖啡店 abroad=true city Tokyo ends the trip stop")
    func row173Abroad() async {
        let photon = FakeApple(["咖啡店": [jp("Doutor", lat: 35.69), jp("Tully's", lat: 35.685)]])
        let rig = await SeparateRig(phone: zhuhai, home: AmapSpy(), photon: photon)
        #expect(await rig.nav.tripNext(jp("浅草寺", lat: 35.71), abroad: true).ok)
        #expect(await rig.nav.current.tripStopID != nil)
        _ = await rig.nav.execute(navCall(["destination": "附近的咖啡店", "near": "place", "near_name": "Tokyo, Japan", "near_country": "JP"]))
        #expect(await rig.nav.current.tripStopID == nil)
        #expect(photon.asked.withLock { $0 } == ["咖啡店"])
    }

    @Test("F-15b §51 row 165 (tap): cards hidden, 「加入清单」 tap is refused with tripHidden; list unchanged")
    func row165Tap() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        #expect(await rig.planner.hideCards())
        let before = await rig.order()
        let (r, note) = await rig.planner.tap(.add(place("瑞幸", 300)), moving: false)
        #expect(r.code == .tripHidden && note == nil)
        #expect(await rig.order() == before)
        #expect(await rig.planner.cardsHidden)
        #expect(rig.lines.withLock { $0 }.contains("trip blocked tool=tap_add reason=hidden"))
    }

    @Test("F-15b §51 row 174: during an abroad trip stop guidance, here (weather here, current_location) is the phone's fix, not Tokyo")
    func row174() async {
        let rig = await SeparateRig(phone: zhuhai, home: AmapSpy(), photon: FakeApple([:]))
        #expect(await rig.nav.tripNext(jp("浅草寺", lat: 35.71), abroad: true).ok)
        #expect(await rig.nav.currentPosition() == CoordinateConverter.gcj02(zhuhai))
        #expect(await rig.nav.currentFix()?.coordinate == CoordinateConverter.gcj02(zhuhai))
    }

    @Test("F-15b §51 item 1 (replaced by item 8): the navigate_to catalog text no longer mentions abroad")
    func catalogText() throws {
        let spec = try #require(ToolCatalog.spec("navigate_to"))
        #expect(spec.declaration.description.contains("abroad") == false)
    }
}
