import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

/// Zhuhai, mainland China (WGS-84), where GCJ-02 differs by a few hundred metres.
private let zhuhai = GeoCoordinate(latitude: 22.2711, longitude: 113.5767, datum: .wgs84)
private let t0 = NovaInstant(milliseconds: 1_000_000)

private func fix(_ c: GeoCoordinate = zhuhai, accuracy: Double = 10, ageSeconds: Int64 = 0,
                 speedKmh: Double? = nil, course: Double? = nil) -> LocationFix {
    LocationFix(coordinate: c, horizontalAccuracyMeters: accuracy, timestamp: t0 - .seconds(ageSeconds),
                speedMetersPerSecond: speedKmh.map { $0 / 3.6 }, courseDegrees: course)
}

private func position(_ f: LocationFix?, source: LocationSource = .device,
                      permission: LocationAuthorization = .authorized, now: NovaInstant = t0,
                      phase: NovaNav.NavigationPhase = .idle, car: GeoCoordinate? = nil, carHeading: Double? = nil) -> SelfPosition {
    SelfPosition.make(.init(fix: f, source: source, permission: permission, now: now, phase: phase,
                            simulatedCar: car, simulatedHeadingDegrees: carHeading))
}

/// A point `meters` north of `c`.
private func north(_ c: GeoCoordinate, _ meters: Double) -> GeoCoordinate {
    GeoCoordinate(latitude: c.latitude + meters / 111_195, longitude: c.longitude, datum: c.datum)
}

@Suite("T-044a F-16b 我的位置 marker")
struct SelfPositionTests {
    @Test("F-16b SelfPosition: fresh/provisional/none by age and accuracy (30 s, 10 min, 2000 m)")
    func freshness() {
        #expect(position(fix(ageSeconds: 30)).marker?.style == .fresh)
        #expect(position(fix(ageSeconds: 31)).marker?.style == .provisional)
        #expect(position(fix(ageSeconds: 600)).marker?.style == .provisional)
        #expect(position(fix(ageSeconds: 601)).hidden == .unusable)
        #expect(position(fix(accuracy: 2000)).marker != nil)
        #expect(position(fix(accuracy: 2001)).hidden == .unusable)
        #expect(position(nil).hidden == .noFix)
        #expect(position(nil).marker == nil)
    }

    @Test("F-16b SelfPosition: denied and not asked hide the marker with their reason")
    func permission() {
        let denied = position(fix(), permission: .denied)
        #expect(denied.marker == nil && denied.hidden == .denied)
        #expect(position(fix(), permission: .notDetermined).hidden == .notDetermined)
        let pill = LocateButton(denied, mode: .awaitingFirstFix)
        #expect(pill.action == .openSettings && pill.icon == .unavailable && pill.showsPermissionPill)
        let ask = LocateButton(position(nil, permission: .notDetermined), mode: .awaitingFirstFix)
        #expect(ask.action == .askPermission && !ask.showsPermissionPill)
        #expect(LocateButton(position(nil), mode: .following).action == LocateAction.none)
        #expect(LocateButton(position(fix()), mode: .following) == LocateButton(position(fix()), mode: .following))
        #expect(LocateButton(position(fix()), mode: .following).icon == .following)
        let free = LocateButton(position(fix()), mode: .free(lastTouch: t0))
        #expect(free.icon == .free && free.action == .recenter)
    }

    @Test("F-16b SelfPosition: accuracy circle only above 30 m")
    func accuracyCircle() {
        #expect(position(fix(accuracy: 30)).marker?.accuracyRadiusMeters == nil)
        #expect(position(fix(accuracy: 31)).marker?.accuracyRadiusMeters == 31)
    }

    @Test("F-16b SelfPosition: demo source draws 演示位置 at the demo point, no arrow, no circle")
    func demo() {
        let demoPoint = GeoCoordinate(latitude: 22.2558, longitude: 113.5767, datum: .gcj02)
        let p = position(fix(demoPoint, accuracy: 500, speedKmh: 50, course: 90), source: .demo,
                         permission: .denied)
        #expect(p.marker == SelfPosition.Marker(coordinate: demoPoint, style: .demo, headingDegrees: nil,
                                                accuracyRadiusMeters: nil, caption: "演示位置"))
    }

    @Test("F-16b SelfPosition: arrow only when fresh, ≥ 5 km/h and a valid course")
    func heading() {
        #expect(position(fix(speedKmh: 5.0, course: 90)).marker?.headingDegrees == 90)
        #expect(position(fix(speedKmh: 4.9, course: 90)).marker?.headingDegrees == nil)
        #expect(position(fix(speedKmh: 30, course: -1)).marker?.headingDegrees == nil)
        #expect(position(fix(speedKmh: 30, course: 360)).marker?.headingDegrees == nil)
        #expect(position(fix(speedKmh: 30)).marker?.headingDegrees == nil)
        #expect(position(fix(ageSeconds: 60, speedKmh: 30, course: 90)).marker?.headingDegrees == nil)
    }

    @Test("F-16b SelfPosition: a WGS-84 fix in China is drawn in GCJ-02; outside China unchanged")
    func datum() throws {
        let marker = try #require(position(fix()).marker)
        #expect(marker.coordinate == CoordinateConverter.gcj02(zhuhai) && marker.coordinate.datum == .gcj02)
        #expect(SelfPosition.distanceMeters(marker.coordinate, zhuhai) > 100)
        let tokyo = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .wgs84)
        let abroad = try #require(position(fix(tokyo)).marker)
        #expect(abroad.coordinate.latitude == tokyo.latitude && abroad.coordinate.longitude == tokyo.longitude)
    }

    @Test("F-16b SelfPosition: navigating draws one simulated marker with the route bearing; back to the real fix after")
    func simulated() {
        let car = GeoCoordinate(latitude: 22.3, longitude: 113.6, datum: .gcj02)
        let driving = position(fix(), phase: .navigating, car: car, carHeading: 45)
        #expect(driving.marker == SelfPosition.Marker(coordinate: car, style: .simulated, headingDegrees: 45,
                                                      accuracyRadiusMeters: nil, caption: nil))
        // Even with no real fix or no permission, the simulated drive has its one marker.
        #expect(position(nil, permission: .denied, phase: .navigating, car: car).marker?.style == .simulated)
        #expect(position(fix(), source: .demo, phase: .navigating, car: car).marker?.caption == "演示位置")
        let after = position(fix(), phase: .arrived, car: car)
        #expect(after.marker?.style == .fresh && after.marker?.coordinate == CoordinateConverter.gcj02(zhuhai))
    }

    @Test("F-16b bearing: north 0, east 90, under 1 m nil")
    func bearing() throws {
        let a = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02)
        let n = try #require(SelfPosition.bearing(from: a, to: north(a, 100)))
        #expect(abs(n) < 0.01 || abs(n - 360) < 0.01)
        let east = GeoCoordinate(latitude: 22.27, longitude: 113.571, datum: .gcj02)
        #expect(abs(try #require(SelfPosition.bearing(from: a, to: east)) - 90) < 0.1)
        let west = GeoCoordinate(latitude: 22.27, longitude: 113.569, datum: .gcj02)
        #expect(abs(try #require(SelfPosition.bearing(from: a, to: west)) - 270) < 0.1)
        #expect(SelfPosition.bearing(from: a, to: north(a, 0.5)) == nil)
    }
}

@Suite("T-044a F-16b map camera policy")
struct MapCameraPolicyTests {
    let here = CoordinateConverter.gcj02(zhuhai)

    func at(_ c: GeoCoordinate) -> SelfPosition {
        position(fix(GeoCoordinate(latitude: c.latitude, longitude: c.longitude, datum: .wgs84)))
    }

    func seen(_ c: GeoCoordinate) -> GeoCoordinate { CoordinateConverter.gcj02(GeoCoordinate(
        latitude: c.latitude, longitude: c.longitude, datum: .wgs84)) }

    @Test("F-16b MapCameraPolicy: first fix recenters once at 1500 m; a gesture before it prevents that")
    func firstFix() {
        var p = MapCameraPolicy()
        #expect(p.handle(.position(position(nil), at: t0)) == nil)
        #expect(p.mode == .awaitingFirstFix)
        #expect(p.handle(.position(at(zhuhai), at: t0)) == .center(seen(zhuhai), spanMeters: 1500))
        #expect(p.mode == .following)
        var panned = MapCameraPolicy()
        _ = panned.handle(.userGesture(at: t0))
        #expect(panned.handle(.position(at(zhuhai), at: t0 + .seconds(1))) == nil)
    }

    @Test("F-16b MapCameraPolicy: following throttles at 10 m and 1 s")
    func throttle() {
        var p = MapCameraPolicy()
        _ = p.handle(.position(at(zhuhai), at: t0))
        #expect(p.handle(.position(at(north(zhuhai, 9)), at: t0 + .seconds(5))) == nil)
        #expect(p.handle(.position(at(north(zhuhai, 20)), at: t0 + .milliseconds(5_500))) != nil)
        #expect(p.handle(.position(at(north(zhuhai, 60)), at: t0 + .milliseconds(6_000))) == nil)
        #expect(p.handle(.position(at(north(zhuhai, 60)), at: t0 + .milliseconds(6_500)))
            == .center(seen(north(zhuhai, 60)), spanMeters: 1500))
    }

    @Test("F-16b MapCameraPolicy: pan stops following; 15 s untouched recenters; 14.9 s does not")
    func autoRecenter() {
        var p = MapCameraPolicy()
        _ = p.handle(.position(at(zhuhai), at: t0))
        let touch = t0 + .seconds(10)
        _ = p.handle(.userGesture(at: touch))
        #expect(p.handle(.position(at(north(zhuhai, 500)), at: touch + .seconds(2))) == nil)
        #expect(p.handle(.tick(at: touch + .milliseconds(14_900))) == nil)
        #expect(p.handle(.tick(at: touch + .seconds(15))) == .center(seen(north(zhuhai, 500)), spanMeters: 1500))
        #expect(p.mode == .following)
        // A second touch restarts the 15 s.
        _ = p.handle(.userGesture(at: touch + .seconds(20)))
        _ = p.handle(.userGesture(at: touch + .seconds(30)))
        #expect(p.handle(.tick(at: touch + .seconds(40))) == nil)
        #expect(p.handle(.tick(at: touch + .seconds(45))) != nil)
    }

    @Test("F-16b MapCameraPolicy: locate-me recenters at once without throttle")
    func locateMe() {
        var p = MapCameraPolicy()
        #expect(p.handle(.locateMe(at: t0)) == nil)  // C10: nothing to show yet
        _ = p.handle(.position(at(zhuhai), at: t0))
        _ = p.handle(.userGesture(at: t0 + .milliseconds(100)))
        #expect(p.handle(.locateMe(at: t0 + .milliseconds(200))) == .center(seen(zhuhai), spanMeters: 1500))
        #expect(p.mode == .following)
        _ = p.handle(.position(position(nil, permission: .denied), at: t0 + .seconds(1)))
        #expect(p.handle(.locateMe(at: t0 + .seconds(2))) == nil)
    }

    @Test("F-16b MapCameraPolicy: lists fit once and freeze; closing them resumes following only if it was following")
    func lists() {
        var p = MapCameraPolicy()
        _ = p.handle(.position(at(zhuhai), at: t0))
        #expect(p.handle(.framing(.lists, at: t0 + .seconds(1))) == .fitContent)
        #expect(p.handle(.framing(.lists, at: t0 + .seconds(2))) == nil)
        #expect(p.handle(.position(at(north(zhuhai, 300)), at: t0 + .seconds(3))) == nil)
        _ = p.handle(.userGesture(at: t0 + .seconds(4)))
        #expect(p.handle(.tick(at: t0 + .seconds(30))) == nil)
        #expect(p.handle(.framing(.open, at: t0 + .seconds(31))) == nil)  // free when the list closed
        var q = MapCameraPolicy()
        _ = q.handle(.position(at(zhuhai), at: t0))
        _ = q.handle(.framing(.lists, at: t0 + .seconds(1)))
        _ = q.handle(.position(at(north(zhuhai, 300)), at: t0 + .seconds(2)))
        #expect(q.handle(.framing(.navigating, at: t0 + .seconds(3))) == .center(seen(north(zhuhai, 300)), spanMeters: 1500))
        var presentation = NavigationFlowState()
        #expect(MapCameraPolicy.framing(MapPresentation(presentation)) == .open)
        presentation.phase = .awaitingRouteSelection
        #expect(MapCameraPolicy.framing(MapPresentation(presentation)) == .lists)
        presentation.phase = .navigating
        #expect(MapCameraPolicy.framing(MapPresentation(presentation)) == .navigating)
    }

    @Test("F-16b MapCameraPolicy: source switch waits for the next first fix")
    func sourceSwitch() {
        var p = MapCameraPolicy()
        _ = p.handle(.position(at(zhuhai), at: t0))
        _ = p.handle(.sourceChanged)
        #expect(p.mode == .awaitingFirstFix)
        #expect(p.handle(.locateMe(at: t0 + .seconds(1))) == nil)
        let demoPoint = GeoCoordinate(latitude: 22.2558, longitude: 113.5767, datum: .gcj02)
        let demo = position(fix(demoPoint), source: .demo)
        #expect(p.handle(.position(demo, at: t0 + .milliseconds(1_100))) == .center(demoPoint, spanMeters: 1500))
    }
}
