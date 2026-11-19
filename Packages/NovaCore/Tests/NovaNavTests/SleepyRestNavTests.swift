import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

/// F-09b §12 row 4 (T-031k): 「附近的咖啡店」 with no results lists nothing and starts no route.
@Suite("T-031k F-09b §12 row 4 navigate_to with no nearby results")
struct SleepyRestNavTests {
    @Test("T-031k F-09b §12 row 4: 附近的咖啡店 with no results is an honest failure; no list, no route")
    func noNearbyCoffee() async {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 1_000, seconds: 120)])
        let nav = NavigationController(search: FixedSearch(places: []), engine: engine, location: NoLocation(),
                                       clock: ManualClock())
        await nav.start()
        let result = await nav.execute(tool("navigate_to", ["destination": "附近的咖啡店"]))
        #expect(!result.ok && result.code == .noCandidates)
        #expect(await nav.current.places.isEmpty)
        #expect(await nav.current.destination == nil)
        #expect(await nav.current.phase == .idle)
        #expect(engine.calls.withLock { $0 }.isEmpty)
    }
}
