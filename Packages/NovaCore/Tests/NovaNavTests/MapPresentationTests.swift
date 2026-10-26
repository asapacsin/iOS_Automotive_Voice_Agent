import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

@Suite("T-044/T-047 F-25 map presentation and taps")
struct MapPresentationTests {
    let routes = [route(1, meters: 12_300, seconds: 1_500), route(2, meters: 10_100, seconds: 1_800)]

    @Test("F-25 offered routes are drawn while choosing, only the chosen one while navigating")
    func routesDrawn() {
        var flow = NavigationFlowState()
        flow.phase = .awaitingRouteSelection
        flow.routes = routes
        flow.selectedRoute = RouteID(1)
        var p = MapPresentation(flow)
        #expect(p.routes == [RouteID(1), RouteID(2)] && p.highlighted == RouteID(1) && p.list == .routes)
        flow.phase = .navigating
        flow.routes = [routes[1]]
        flow.selectedRoute = RouteID(2)
        p = MapPresentation(flow)
        #expect(p.routes == [RouteID(2)] && p.followCar && p.list == nil)
    }

    @Test("F-25 (P59) after 算了 no route line and no destination marker remain")
    func afterCancel() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let nav = NavigationController(search: FixedSearch(places: [place("珠海站", 3_000)]), engine: engine,
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(!MapPresentation(await nav.current).routes.isEmpty)
        _ = await nav.execute(tool("exit_navigation_mode"))
        let p = MapPresentation(await nav.current)
        #expect(p.routes.isEmpty && p.destination == nil && p.markers.isEmpty && p.list == nil)
    }

    @Test("F-25 §10 row 2: a tap on a row calls the same executor as the voice choice and gets the same codes")
    func tapSameExecutor() async {
        let clock = ManualClock()
        let stations = [place("珠海站", 3_000), place("珠海北站", 9_000)]
        let voice = NavigationController(search: FixedSearch(places: stations), engine: ScriptedNaviEngine(routes: routes),
                                         location: NoLocation(), clock: clock)
        let tapped = NavigationController(search: FixedSearch(places: stations), engine: ScriptedNaviEngine(routes: routes),
                                          location: NoLocation(), clock: clock)
        await voice.start()
        await tapped.start()
        _ = await voice.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await tapped.execute(tool("navigate_to", ["destination": "珠海站"]))
        let byVoice = await voice.execute(tool("choose_navigation_option", ["index": .int(2)]))
        let byTap = await tapped.execute(ChoiceTap.call(row: 1, id: CallID("tap_1")!))
        #expect(byVoice == byTap && byTap.data["destination"] == "珠海北站")
        // Stale list: the tap gets OPTIONS_STALE exactly like the voice.
        clock.advance(by: .seconds(121))
        #expect(await tapped.execute(ChoiceTap.call(row: 0, id: CallID("tap_2")!)).code == .optionsStale)
    }
}
