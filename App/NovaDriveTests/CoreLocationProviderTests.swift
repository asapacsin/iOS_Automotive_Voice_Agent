import CoreLocation
import Testing
import NovaKit
import NovaPorts
@testable import NovaPlatform

/// Records what the provider asks of CoreLocation (F-16a §10 row 6: "unit (fake manager)").
final class FakeLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var calls: [String] = []

    init(_ status: CLAuthorizationStatus) { authorizationStatus = status }
    func requestWhenInUseAuthorization() { calls.append("request") }
    func startUpdatingLocation() { calls.append("start") }
    func stopUpdatingLocation() { calls.append("stop") }
}

@MainActor
@Suite("T-042a CoreLocationProvider with a fake manager")
struct CoreLocationProviderTests {
    let here = CLLocation(latitude: 22.27, longitude: 113.57)

    @Test("row 6: the first request asks permission once, waits, and gets the fix that arrives")
    func firstRequestWaitsForFix() async {
        let clock = ManualClock()
        let manager = FakeLocationManager(.notDetermined)
        let provider = CoreLocationProvider(clock: clock, manager: manager)
        let request = Task { await provider.latestFix() }
        while clock.pendingSleepers == 0 { await Task.yield() }
        #expect(manager.calls == ["request", "start"])
        manager.authorizationStatus = .authorizedWhenInUse
        provider.authorizationChanged(.authorizedWhenInUse)
        provider.receive(here)
        clock.advance(by: .milliseconds(100))
        let fix = await request.value
        #expect(fix?.coordinate.latitude == 22.27)
        #expect(manager.calls.filter { $0 == "request" }.count == 1)
    }

    @Test("an already-granted manager starts updates without asking again")
    func grantedDoesNotAsk() async {
        let manager = FakeLocationManager(.authorizedWhenInUse)
        let provider = CoreLocationProvider(clock: ManualClock(), manager: manager)
        await provider.start()
        #expect(manager.calls == ["start"])
    }

    @Test("denied drops the fix and stops updates")
    func deniedClears() async {
        let manager = FakeLocationManager(.authorizedWhenInUse)
        let provider = CoreLocationProvider(clock: ManualClock(), manager: manager)
        await provider.start()
        provider.receive(here)
        manager.authorizationStatus = .denied
        provider.authorizationChanged(.denied)
        #expect(manager.calls.last == "stop")
        #expect(await provider.latestFix() == nil)
    }

    @Test("background pause stops updates; foreground resume starts them again")
    func pauseResume() async {
        let manager = FakeLocationManager(.authorizedWhenInUse)
        let provider = CoreLocationProvider(clock: ManualClock(), manager: manager)
        await provider.start()
        await provider.pause()
        await provider.resume()
        #expect(manager.calls == ["start", "stop", "start"])
    }

    @Test("a stale stop that lands after resume is dropped (review D1)")
    func staleStopDropped() async {
        let manager = FakeLocationManager(.authorizedWhenInUse)
        let provider = CoreLocationProvider(clock: ManualClock(), manager: manager)
        await provider.start()
        _ = provider.state.pause()
        _ = provider.state.resume()
        provider.apply(.stopUpdates)
        #expect(manager.calls == ["start"])
    }
}
