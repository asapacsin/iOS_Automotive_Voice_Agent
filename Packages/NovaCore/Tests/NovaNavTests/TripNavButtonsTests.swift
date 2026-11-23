import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// A Tianjin trip of three stops with guidance running to the first one (by 「去下一站」).
private func guiding() async -> TripRig {
    let rig = await TripRig()
    _ = await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼"])]))
    let r = await rig.run(trip("trip_next"))
    #expect(r.ok, "\(r)")
    for _ in 0..<200 where await !rig.nav.current.navigating { await Task.yield() }
    return rig
}

@Suite("T-040zj F-15b §57 a stop-navigation button wherever navigation can start; both buttons in the screen state")
struct TripNavButtonsTests {
    @Test("T-040zj F-15b row 245: navigation on (guidance, route picking or calculating): 「结束导航」 shown; stopNavigationButton on in the screen line")
    func row245() {
        for phase: NavigationPhase in [.navigating, .awaitingRouteSelection, .resolvingDestination, .calculatingRoute] {
            var s = NavigationFlowState()
            s.phase = phase
            #expect(s.stopButtonShown, "\(phase)")
        }
        for phase: NavigationPhase in [.idle, .stopped, .arrived, .awaitingDestinationSelection] {
            var s = NavigationFlowState()
            s.phase = phase
            #expect(!s.stopButtonShown, "\(phase)")
        }
        var screen = ScreenState()
        screen.report(.navigation, on: true)
        screen.report(.stopNavigationButton, on: true)
        #expect(screen.line.contains("navigation on；tripNextButton off；stopNavigationButton on；"))
        #expect(screen.recordLine.contains("navigation=on tripNextButton=off stopNavigationButton=on "))
    }

    @Test("T-040zj F-15b row 246: tap 「结束导航」 while moving: guidance stops; plan and marks kept; nav tap action=stop; her tap line")
    func row246() async {
        let rig = await guiding()
        await rig.planner.markForTests(index: 2, .skipped)
        let before = await rig.planner.currentPlan
        #expect(await rig.nav.current.stopButtonShown)
        // Moving does not matter: the stop tap is not a trip edit and needs no confirmation.
        let line = await rig.nav.stopTap()
        #expect(line == "[系统] 司机点了「结束导航」。这句不用回答。")
        let after = await rig.nav.current
        #expect(!after.navigating && !after.stopButtonShown && after.routes.isEmpty)
        #expect(await rig.planner.currentPlan == before)
        #expect(await rig.planner.currentPlan.days[0].stops[1].mark == .skipped)
        #expect(rig.lines.withLock { $0 }.contains("nav tap action=stop"))
    }

    @Test("T-040zj F-15b row 247: trip screen, not navigating: 「去下一站」 with its icon; navigation on: the same spot shows 「结束导航」")
    func row247() async {
        #expect(TripScreen.navButton(nextStop: "五大道", navigating: false) == .next("五大道"))
        #expect(TripScreen.navButton(nextStop: "五大道", navigating: true) == .stop)
        #expect(TripScreen.navButton(nextStop: nil, navigating: false) == nil)
        // The tap on 「去下一站」 reaches her as one line, and is recorded.
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        let (result, note) = await rig.planner.tap(.next, moving: false)
        #expect(result.ok && note == "[系统] 司机点了「去下一站」。这句不用回答。")
        #expect(rig.lines.withLock { $0 }.contains("nav tap action=next"))
        var screen = ScreenState()
        screen.report(.tripScreen, on: true)
        screen.report(.tripNextButton, on: true)
        #expect(screen.line.contains("tripNextButton on；stopNavigationButton off；"))
    }

    @Test("T-040zj F-15b row 248: trip_next while guiding to that same stop: no new route; ALREADY_NAVIGATING; next names exit_navigation_mode")
    func row248() async {
        let rig = await guiding()
        let requests = rig.engine.requests.withLock { $0 }.count
        let generation = await rig.nav.current.generation
        let r = await rig.run(trip("trip_next"))
        #expect(!r.ok && r.code == .alreadyNavigating, "\(r)")
        #expect(r.data["next"]?.stringValue == "已经在去古文化街的路上了。司机要是想停，调用 exit_navigation_mode。")
        #expect(rig.engine.requests.withLock { $0 }.count == requests)
        let now = await rig.nav.current
        #expect(now.navigating && now.generation == generation)
        #expect(rig.lines.withLock { $0 }.contains("trip next index=1 day=1 ok=no code=ALREADY_NAVIGATING"))
        // The same by a tap: no restart either, and her tap line still comes.
        let (tapped, note) = await rig.planner.tap(.next, moving: false)
        #expect(tapped.code == .alreadyNavigating && note == TripPlanner.nextTapLine)
    }

    @Test("T-040zj F-15b row 249: trip_next while guiding to another stop runs as today")
    func row249() async {
        let rig = await guiding()
        let requests = rig.engine.requests.withLock { $0 }.count
        let r = await rig.run(trip("trip_next", ["stop": "五大道"]))
        #expect(r.ok && r.data["name"] == "五大道", "\(r)")
        #expect(rig.engine.requests.withLock { $0 }.count == requests + 1)
        #expect(rig.engine.requests.withLock { $0.last }?.destinationName == "五大道")
    }

    @Test("T-040zj F-15b row 250: screen line has tripNextButton and stopNavigationButton after navigation; only on/off")
    func row250() {
        let line = ScreenState().line
        #expect(line.contains("routeCalculating off；navigation off；tripNextButton off；stopNavigationButton off；tripScreen off；"))
        let keys = Array(ScreenPanel.allCases)
        #expect(keys.firstIndex(of: .tripNextButton) == keys.firstIndex(of: .navigation)! + 1)
        #expect(keys.firstIndex(of: .stopNavigationButton) == keys.firstIndex(of: .navigation)! + 2)
        // Buttons are not panels: no layer, never the top, never 「在导航」.
        #expect(ScreenPanel.tripNextButton.layer == nil && ScreenPanel.stopNavigationButton.layer == nil)
        #expect(!ScreenPanel.navigationKeys.contains(.stopNavigationButton))
        var screen = ScreenState()
        screen.report(.stopNavigationButton, on: true)
        #expect(screen.top == nil && screen.navigationOff)
    }
}
