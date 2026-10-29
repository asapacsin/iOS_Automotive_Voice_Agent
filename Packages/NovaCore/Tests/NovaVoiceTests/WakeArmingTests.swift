import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-061 F-01 wake arming and mic router")
struct WakeArmingTests {
    @Test("F-01 §10 row 1: from SLEEP a wake resumes exactly once; the mic goes to the uplink")
    func sleepWake() {
        var w = WakeArming()
        w.lifecycle(.sleep)
        #expect(w.route == .wake)
        #expect(w.detector(.wake) == .resume)
        #expect(w.route == .uplink)
        #expect(w.detector(.wake) == .ignore)  // late duplicate before ACTIVE
        w.lifecycle(.active)
        #expect(w.detector(.wake) == .ignore)
    }

    @Test("F-01 §10 row 2: while ACTIVE a duplicate wake restarts nothing; DEEP_IDLE starts a new session")
    func duplicate() {
        var w = WakeArming()
        #expect(w.detector(.wake) == .startSession)
        w.lifecycle(.active)
        #expect(w.detector(.wake) == .ignore && w.route == .uplink)
        w.lifecycle(.sleep)
        w.lifecycle(.deepIdle)
        #expect(w.armed && w.detector(.wake) == .startSession)
    }

    @Test("F-01 §10 row 3: six failed inits make wake unavailable; the button still starts a session")
    func retries() {
        var r = BoundedRetry()
        let delays = (0..<6).map { _ in r.failed() }
        #expect(delays == [.milliseconds(1500), .milliseconds(3000), .milliseconds(6000), .milliseconds(12_000),
                           .milliseconds(24_000), nil])
        var w = WakeArming()
        _ = w.detector(.unavailable)
        #expect(!w.armed && w.route == .none)
        #expect(w.tap() == .startSession && w.route == .uplink)
        #expect(w.tap() == .ignore)
        w.startFailed()
        #expect(w.tap() == .startSession)
    }
}
