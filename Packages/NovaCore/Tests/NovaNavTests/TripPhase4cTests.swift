import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §47 (T-040s): which route requests are marked `abroad` (OSRM inside the app). The engine side (OSRM request,
/// templates, recalculation) is in NovaServices `OsrmRouteSourceTests`.
@Suite("T-040s F-15b §47 guidance abroad on OSRM routes: the abroad flag")
struct TripPhase4cTests {
    @Test("F-15b row 111: abroad trip, trip_next: the route request is abroad; guidance starts in the app, no Apple Maps")
    func row111() async {
        let opened = Mutex<[String]>([])
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 67_700, seconds: 3_720), route(2, meters: 70_000, seconds: 4_000)])
        let rig = await TripRig(engine: engine, times: TripTimes(service: FakeDrivingTimes(byLine), clock: ManualClock(),
                                                                 retryDelay: .milliseconds(1)),
                                here: GeoCoordinate(latitude: 35.77, longitude: 139.8, datum: .gcj02), abroad: FakeApple(tokyo),
                                handoff: { place in opened.withLock { $0.append(place.name) }; return true })
        _ = await rig.run(trip("make_trip_list", ["places": names(["浅草寺"]), "abroad": true]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["status"] == "trip_next")
        #expect(engine.requests.withLock { $0 }.map(\.abroad) == [true])
        #expect(opened.withLock { $0 }.isEmpty)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip handoff") } == false)
    }

    @Test("F-15b row 114 (planner side): the abroad route fails: ROUTE_CALCULATION_FAILED, then Apple Maps (§38 item 2)")
    func row114() async {
        let opened = Mutex<[String]>([])
        let engine = ScriptedNaviEngine(routes: [])
        let rig = await TripRig(engine: engine, times: TripTimes(service: FakeDrivingTimes(byLine), clock: ManualClock(),
                                                                 retryDelay: .milliseconds(1)),
                                here: GeoCoordinate(latitude: 35.77, longitude: 139.8, datum: .gcj02), abroad: FakeApple(tokyo),
                                handoff: { place in opened.withLock { $0.append(place.name) }; return true })
        _ = await rig.run(trip("make_trip_list", ["places": names(["浅草寺"]), "abroad": true]))
        let r = await rig.run(trip("trip_next"))
        #expect(engine.requests.withLock { $0 }.map(\.abroad) == [true])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasSuffix("ok=no code=ROUTE_CALCULATION_FAILED") })
        #expect(r.ok && r.data["status"] == "apple_maps")
        #expect(opened.withLock { $0 } == ["浅草寺"])
    }

    @Test("F-15b row 114a: home trip (abroad=false): the route request is not abroad (高德 as today)")
    func row114a() async {
        let (rig, _) = await timesRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街"]), "city": "天津"]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok)
        #expect(rig.engine.requests.withLock { $0 }.map(\.abroad) == [false])
    }

    @Test("F-15b §47 item 1: navigate_to abroad=true routes abroad; a home navigate_to afterwards does not")
    func navigateAbroad() async {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)])
        let fix = LocationFix(coordinate: GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .wgs84),
                              horizontalAccuracyMeters: 20, timestamp: .zero)
        let nav = NavigationController(search: FakeApple(["古文化街": [jp("古文化街", lat: 39.1, lng: 117.2, country: "CN")]]), engine: engine, location: FixLocation(fix: fix),
                                       clock: ManualClock())
        await nav.start()
        await nav.setAbroad(search: FakeApple(["浅草寺 (Senso-ji)": [jp("浅草寺", lat: 35.71)]]), center: { _ in
            GeoCoordinate(latitude: 35.6812, longitude: 139.7671, datum: .gcj02)
        }, tripCity: { nil })
        let call = { (args: [String: JSONValue]) in ToolCall(id: CallID("n1")!, name: "navigate_to", arguments: .object(args)) }
        let r = await nav.execute(call(["destination": "浅草寺 (Senso-ji)", "abroad": true, "city": "Tokyo, Japan"]))
        #expect(r.ok)
        #expect(engine.requests.withLock { $0 }.map(\.abroad) == [true])
        _ = await nav.execute(trip("exit_navigation_mode"))
        let home = await nav.execute(call(["destination": "古文化街"]))
        #expect(home.ok, "\(home.data) \(String(describing: home.code))")
        #expect(engine.requests.withLock { $0 }.map(\.abroad) == [true, false])
    }
}
