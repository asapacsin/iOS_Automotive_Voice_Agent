import Testing
import NovaKit
@testable import NovaPorts

/// F-16b (T-044b): the fix stream behind the map's 我的位置 marker.
@Suite("T-044b F-16b location updates")
struct LocationUpdatesTests {
    private func fix(_ lat: Double, speed: Double? = nil) -> LocationFix {
        LocationFix(coordinate: GeoCoordinate(latitude: lat, longitude: 113.57, datum: .wgs84),
                    horizontalAccuracyMeters: 10, timestamp: .zero, speedMetersPerSecond: speed, courseDegrees: nil)
    }

    @Test("F-16b updates: a late subscriber gets the latest fix first, then every new one, speed kept")
    func lateSubscriber() async {
        let state = LocationFixState(clock: ManualClock(), permission: .authorized)
        state.receive(fix(22.1))
        var it = state.updates().makeAsyncIterator()
        #expect(await it.next() == fix(22.1))
        state.receive(fix(22.2, speed: 8))
        #expect(await it.next() == fix(22.2, speed: 8))
    }

    @Test("F-16b updates: every subscriber hears each fix; a stopped one is dropped")
    func fanOut() async {
        let state = LocationFixState(clock: ManualClock(), permission: .authorized)
        var a = state.updates().makeAsyncIterator()
        var b: AsyncStream<LocationFix>.Iterator? = state.updates().makeAsyncIterator()
        #expect(state.subscriberCount == 2)
        state.receive(fix(22.3))
        #expect(await a.next() == fix(22.3))
        #expect(await b?.next() == fix(22.3))
        b = nil
        while state.subscriberCount != 1 { await Task.yield() }
        state.receive(fix(22.4))
        #expect(await a.next() == fix(22.4))
    }

    @Test("F-16b updates: with no fix yet nothing is yielded until one arrives; denial clears the latest")
    func noFixYet() async {
        let state = LocationFixState(clock: ManualClock(), permission: .authorized)
        state.receive(fix(22.5))
        _ = state.authorizationChanged(.denied)
        let stream = state.updates()
        let task = Task { var it = stream.makeAsyncIterator(); return await it.next() }
        while state.subscriberCount != 1 { await Task.yield() }
        _ = state.authorizationChanged(.authorized)
        state.receive(fix(22.6))
        #expect(await task.value == fix(22.6))
    }
}
