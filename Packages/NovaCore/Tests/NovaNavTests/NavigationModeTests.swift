import Testing
import Synchronization
import NovaKit
import NovaPorts
@testable import NovaNav

private let lat = 22.27
/// `index`·0.001° east of the start: about 103 m per step at this latitude.
private func p(_ index: Double, north meters: Double = 0) -> GeoCoordinate {
    GeoCoordinate(latitude: lat + meters / 111_320, longitude: 113.5 + index * 0.001, datum: .gcj02)
}

private func fix(_ c: GeoCoordinate, at seconds: Int64, accuracy: Double = 10) -> LocationFix {
    LocationFix(coordinate: c, horizontalAccuracyMeters: accuracy, timestamp: NovaInstant(milliseconds: seconds * 1000))
}

private func u(_ r: inout RouteProgress, _ f: LocationFix) -> RouteProgress.Snapshot { r.update(f)! }

private func route() -> RouteProgress {
    // Five points, steps begin at points 0 and 2 and 3; about 412 m, 60 s.
    RouteProgress(points: (0...4).map { p(Double($0)) }, stepStarts: [0, 2, 3], durationSeconds: 60, start: .zero)
}

@Suite("T-040a F-15a NavigationModeSetting")
struct NavigationModeSettingTests {
    @Test("F-15a row 1: default 真实导航 → .gps; 模拟导航 → .emulator; 演示起点 → .emulator whatever the switch says")
    func mode() {
        #expect(NavigationModeSetting.default == .real)
        #expect(NavigationModeSetting.mode(.default, source: .device) == .gps)
        #expect(NavigationModeSetting.mode(.simulated, source: .device) == .emulator)
        #expect(NavigationModeSetting.mode(.real, source: .demo) == .emulator)
        #expect(NavigationModeSetting.mode(.simulated, source: .demo) == .emulator)
        #expect(NavigationModeSetting.locked(source: .demo))
        #expect(!NavigationModeSetting.locked(source: .device))
    }
}

@Suite("T-040a F-15a RouteProgress")
struct RouteProgressTests {
    @Test("F-15a row 2: matching, step entry, distance to the next turn, remaining distance and time")
    func matching() {
        var r = route()
        let start = u(&r, fix(p(0.5, north: 8), at: 1))
        #expect(start.onRoute)
        #expect(abs(start.distanceFromRouteMeters - 8) < 1)
        #expect(start.enteredStep == 0)
        #expect(abs(start.alongMeters - r.totalMeters / 8) < 2)
        #expect(abs(start.distanceToNextStepMeters - r.totalMeters * 3 / 8) < 2)
        #expect(abs(start.remainingMeters - r.totalMeters * 7 / 8) < 2)
        #expect(abs(start.remainingSeconds - 52) <= 1)
        let same = u(&r, fix(p(1.5), at: 2))
        #expect(same.enteredStep == nil && same.stepIndex == 0)
        let next = u(&r, fix(p(2.2), at: 3))
        #expect(next.enteredStep == 1 && next.stepIndex == 1)
        // A step skipped between two fixes is entered at the furthest one.
        let jump = u(&r, fix(p(3.4), at: 4))
        #expect(jump.enteredStep == 2)
        // Progress never goes back (a fix that matches behind the car).
        let back = u(&r, fix(p(3.0), at: 5))
        #expect(back.alongMeters == jump.alongMeters && back.enteredStep == nil)
    }

    @Test("F-15a row 2: off route after 3 fixes over ≥ 5 s farther than 50 m; coarse fixes are not counted")
    func offRoute() {
        var r = route()
        _ = r.update(fix(p(1), at: 0))
        #expect(u(&r, fix(p(1.2, north: 80), at: 1)).offRouteConfirmed == false)
        #expect(u(&r, fix(p(1.3, north: 90), at: 2)).offRouteConfirmed == false)
        // Third fix but only 2 s after the first: not yet.
        #expect(u(&r, fix(p(1.4, north: 95), at: 3)).offRouteConfirmed == false)
        // Coarse: the marker may move, but it is not counted.
        let coarse = u(&r, fix(p(1.5, north: 300), at: 9, accuracy: 80))
        #expect(!coarse.onRoute && !coarse.offRouteConfirmed)
        let confirmed = u(&r, fix(p(1.5, north: 100), at: 6))
        #expect(confirmed.offRouteConfirmed && !confirmed.onRoute)
        // Off route, progress holds.
        #expect(abs(confirmed.alongMeters - r.totalMeters / 4) < 2)
        // The count starts again after a confirmation; a fix back on the route resets it.
        #expect(u(&r, fix(p(1.6, north: 100), at: 7)).offRouteConfirmed == false)
        _ = r.update(fix(p(1.7), at: 8))
        _ = r.update(fix(p(1.8, north: 100), at: 9))
        _ = r.update(fix(p(1.9, north: 100), at: 12))
        #expect(u(&r, fix(p(2.0, north: 100), at: 15)).offRouteConfirmed)
    }

    @Test("F-15a row 2: arrival within 30 m, reported once")
    func arrival() {
        var r = route()
        #expect(u(&r, fix(p(3.5), at: 1)).arrived == false)
        #expect(u(&r, fix(p(3.8), at: 2)).arrived)
        #expect(u(&r, fix(p(4), at: 3)).arrived == false)
    }

    @Test("F-15a row 2: signal lost after 10 s without a fix; one sentence at 30 s; a fix resumes")
    func signal() {
        var r = route()
        #expect(r.tick(at: NovaInstant(milliseconds: 9_000)) == .ok)
        #expect(r.tick(at: NovaInstant(milliseconds: 10_000)) == .lost(announce: false))
        #expect(r.tick(at: NovaInstant(milliseconds: 30_000)) == .lost(announce: true))
        #expect(r.tick(at: NovaInstant(milliseconds: 40_000)) == .lost(announce: false))
        _ = r.update(fix(p(1), at: 41))
        #expect(r.tick(at: NovaInstant(milliseconds: 45_000)) == .ok)
        #expect(r.tick(at: NovaInstant(milliseconds: 71_000)) == .lost(announce: true))
    }
}

@Suite("T-040a F-15a SelfPosition mode")
struct SelfPositionModeTests {
    let real = fix(p(0), at: 0)
    let car = GeoCoordinate(latitude: 22.3, longitude: 113.6, datum: .wgs84)

    func make(_ phase: NovaNav.NavigationPhase, car: GeoCoordinate?, mode: NaviMode) -> SelfPosition {
        SelfPosition.make(.init(fix: real, source: .device, permission: .authorized, now: .zero, phase: phase,
                                simulatedCar: car, mode: mode))
    }

    @Test("F-15a row 3: .gps never draws the simulated car; .emulator draws it for the whole trip; one marker")
    func oneMarker() {
        for phase in [NovaNav.NavigationPhase.idle, .awaitingRouteSelection, .navigating, .arrived] {
            let gps = make(phase, car: car, mode: .gps)
            #expect(gps.marker?.style == .fresh, "\(phase)")
        }
        #expect(make(.navigating, car: car, mode: .emulator).marker?.style == .simulated)
        // Between engine updates the real fix is not drawn instead of the car.
        let between = make(.navigating, car: nil, mode: .emulator)
        #expect(between.marker == nil)
        // Before and after the trip, the real fix.
        #expect(make(.awaitingRouteSelection, car: nil, mode: .emulator).marker?.style == .fresh)
        #expect(make(.arrived, car: car, mode: .emulator).marker?.style == .fresh)
    }
}

@Suite("T-040d F-15a navigation mode read per trip")
struct NavigationModePerTripTests {
    let stations = [place("珠海站", 3_000)]

    func trip(_ mode: NaviMode, location: any LocationProvider) async -> (NavigationController, ScriptedNaviEngine) {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 12_300, seconds: 1_500)])
        let nav = NavigationController(search: FixedSearch(places: stations), engine: engine, location: location,
                                       clock: ManualClock(), mode: { mode })
        await nav.start()
        return (nav, engine)
    }

    @Test("F-15a 真实导航 starts the engine in .gps from a usable fix; the snapshot carries the mode")
    func realStartsGps() async {
        let (nav, engine) = await trip(.gps, location: FixedLocation())
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        let started = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(started.ok && started.data["simulated_movement"] == .bool(false))
        #expect(engine.calls.withLock { $0 }.contains("start gps"))
        #expect(await nav.current.mode == .gps)
    }

    @Test("F-15a 真实导航 with no usable fix or no permission: no route, no demo origin (OQ-NAVM-2)")
    func realRefusesWithoutFix() async {
        for (location, code) in [(NoLocation() as any LocationProvider, ToolErrorCode.noLocation),
                                 (DeniedLocation(), .locationPermissionDenied)] {
            let (nav, engine) = await trip(.gps, location: location)
            _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
            let picked = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
            #expect(!picked.ok && picked.code == code)
            #expect(!engine.calls.withLock { $0 }.contains { $0.hasPrefix("calculate") })
            #expect(await nav.current.phase == .idle)
        }
    }

    @Test("F-15a 模拟导航 starts in .emulator without a fix and says 模拟导航")
    func simulatedNeedsNoFix() async {
        let (nav, engine) = await trip(.emulator, location: NoLocation())
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        let started = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(started.ok && started.data["simulated_movement"] == .bool(true))
        #expect(engine.calls.withLock { $0 }.contains("start emulator"))
        #expect(await nav.current.mode == .emulator)
    }
}
