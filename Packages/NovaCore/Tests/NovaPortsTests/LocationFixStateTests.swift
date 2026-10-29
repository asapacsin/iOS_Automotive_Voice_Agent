import Testing
import NovaKit
@testable import NovaPorts

/// F-16a §10 row 6 (T-042a): the device location state machine, driven with a manual clock.
@Suite("T-042a LocationFixState")
struct LocationFixStateTests {
    private func fix(_ clock: ManualClock, lat: Double = 31.2) -> LocationFix {
        LocationFix(coordinate: GeoCoordinate(latitude: lat, longitude: 121.4, datum: .wgs84),
                    horizontalAccuracyMeters: 10, timestamp: clock.now)
    }

    private func waitForSleeper(_ clock: ManualClock) async {
        while clock.pendingSleepers == 0 { await Task.yield() }
    }

    @Test("first request right after permission waits and returns the fix that arrives before firstFixWait")
    func firstFixArrives() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .notDetermined)
        #expect(state.start() == .requestAndStart)
        #expect(state.start() == nil)
        let task = Task { await state.awaitFix() }
        await waitForSleeper(clock)
        #expect(state.authorizationChanged(.authorized) == .startUpdates)
        clock.advance(by: .milliseconds(1_000))
        await waitForSleeper(clock)
        let expected = fix(clock)
        state.receive(expected)
        clock.advance(by: .milliseconds(100))
        #expect(await task.value == expected)
        #expect(clock.now < NovaInstant.zero + TuningDefaults.firstFixWait)
    }

    @Test("no fix within firstFixWait times out with nil")
    func timeoutNil() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        _ = state.start()
        let task = Task { await state.awaitFix() }
        for _ in 0..<30 {
            await waitForSleeper(clock)
            clock.advance(by: .milliseconds(100))
        }
        #expect(await task.value == nil)
        #expect(clock.now == NovaInstant.zero + .seconds(3))
    }

    @Test("a stale cached fix waits for a fresh one; on timeout the stale fix is returned")
    func staleFix() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        _ = state.start()
        let old = fix(clock, lat: 30)
        state.receive(old)
        #expect(await state.awaitFix() == old)  // fresh: immediate
        clock.advance(by: .seconds(31))
        let waiting = Task { await state.awaitFix() }
        await waitForSleeper(clock)
        let fresh = fix(clock, lat: 31)
        state.receive(fresh)
        clock.advance(by: .milliseconds(100))
        #expect(await waiting.value == fresh)

        clock.advance(by: .seconds(31))
        let timingOut = Task { await state.awaitFix() }
        for _ in 0..<30 {
            await waitForSleeper(clock)
            clock.advance(by: .milliseconds(100))
        }
        #expect(await timingOut.value == fresh)
    }

    @Test("deny while waiting clears the fix and returns nil; denied returns at once")
    func deny() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        _ = state.start()
        state.receive(fix(clock))
        clock.advance(by: .seconds(31))
        let task = Task { await state.awaitFix() }
        await waitForSleeper(clock)
        #expect(state.authorizationChanged(.denied) == .stopUpdates)
        #expect(state.latest == nil)
        clock.advance(by: .milliseconds(100))
        #expect(await task.value == nil)
        #expect(await state.awaitFix() == nil)
        #expect(clock.pendingSleepers == 0)
        #expect(state.resume() == nil)
    }

    @Test("grant while paused does not restart; resume does; paused answers at once")
    func grantWhilePaused() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .notDetermined)
        #expect(state.pause() == nil)  // not started yet
        _ = state.resume()
        #expect(state.start() == .requestAndStart)
        #expect(state.pause() == .stopUpdates)
        #expect(state.pause() == nil)
        #expect(state.authorizationChanged(.authorized) == nil)
        #expect(await state.awaitFix() == nil)
        #expect(clock.pendingSleepers == 0)
        #expect(state.mayStartUpdates() == false)
        #expect(state.resume() == .requestAndStart)
        #expect(state.mayStartUpdates())
        #expect(state.resume() == nil)
        #expect(state.authorizationChanged(.authorized) == .startUpdates)
    }

    @Test("granted before anything needed location does not start updates")
    func grantBeforeStart() {
        let state = LocationFixState(clock: ManualClock(), permission: .notDetermined)
        #expect(state.authorizationChanged(.authorized) == nil)
        #expect(state.start() == .requestAndStart)
        #expect(state.authorizationChanged(.authorized) == .startUpdates)
    }

    @Test("a pause during the first-fix wait ends the wait without waiting out firstFixWait")
    func pauseDuringWait() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        _ = state.start()
        let task = Task { await state.awaitFix() }
        await waitForSleeper(clock)
        _ = state.pause()
        clock.advance(by: .milliseconds(100))
        #expect(await task.value == nil)
    }

    @Test("cancelling a waiting request returns the cached fix without waiting out firstFixWait")
    func cancellation() async {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        _ = state.start()
        let task = Task { await state.awaitFix() }
        await waitForSleeper(clock)
        task.cancel()
        #expect(await task.value == nil)
        #expect(clock.pendingSleepers == 0)
        #expect(clock.now == .zero)
    }

    @Test("session started in the background asks permission and starts on first foreground")
    func backgroundStartThenForeground() {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .notDetermined)
        #expect(state.pause() == nil)
        #expect(state.start() == nil)  // paused: nothing starts, the need is recorded
        #expect(state.mayStartUpdates() == false)
        #expect(state.resume() == .requestAndStart)
        #expect(state.mayStartUpdates())
        #expect(state.start() == nil)
    }

    @Test("a start that loses the race to pause is suppressed; pause/resume cycles")
    func startPauseRace() {
        let clock = ManualClock()
        let state = LocationFixState(clock: clock, permission: .authorized)
        #expect(state.start() == .requestAndStart)
        #expect(state.pause() == .stopUpdates)  // runs before the start hop reaches the main actor
        #expect(state.mayStartUpdates() == false)
        #expect(state.resume() == .requestAndStart)
        #expect(state.pause() == .stopUpdates)
        #expect(state.authorizationChanged(.denied) == .stopUpdates)
        #expect(state.resume() == nil)  // denied: no restart
        #expect(state.mayStartUpdates() == false)
    }
}
