import Testing
@testable import NovaVoice

@Suite("T-021q F-03 §14 another app takes the microphone")
struct MicInterruptionTests {
    @Test("T-021q F-03 §14 row 1: interrupted blocks the restart; shouldResume resumes at once, restart only after reactivation")
    func resumeNow() {
        var m = MicInterruption()
        #expect(m.allowsRestart)
        let began = m.began()
        #expect(began == "audio interrupted")
        #expect(!m.allowsRestart)
        let e = m.ended(shouldResume: true)
        #expect(e?.resume == true && e?.line == "audio interruption-ended resume=now")
        // Until the session is reactivated a configuration change still does not restart the engine.
        #expect(!m.allowsRestart)
        m.resumed()
        #expect(m.allowsRestart)
    }

    @Test("T-021q F-03 §14 row 2: ended without shouldResume waits until the app is active again, then resumes once")
    func resumeOnReturn() {
        var m = MicInterruption()
        _ = m.began()
        let e = m.ended(shouldResume: false)
        #expect(e?.resume == false && e?.line == "audio interruption-ended resume=on-return" && !m.allowsRestart)
        let first = m.becameActive()
        #expect(first)
        let again = m.becameActive()
        #expect(!again)
        m.resumed()
        #expect(m.allowsRestart)
        let after = m.becameActive()
        #expect(!after)
    }

    @Test("T-021q F-03 §14 row 2: a began with no end resumes on return; a failed reactivation waits for the next return")
    func beganWithoutEnd() {
        var m = MicInterruption()
        _ = m.began()
        let first = m.becameActive()
        #expect(first)
        m.resumeFailed()
        #expect(!m.allowsRestart)
        let second = m.becameActive()
        #expect(second)
        m.resumed()
        #expect(m.allowsRestart)
    }

    @Test("T-021q F-03 §14 row 3: no interruption: becoming active, a stray end or an app-suspended began changes nothing")
    func noInterruption() {
        var m = MicInterruption()
        let active = m.becameActive()
        #expect(!active)
        let stray = m.ended(shouldResume: true)
        #expect(stray == nil && m.allowsRestart)
        let suspended = m.began(appWasSuspended: true)
        #expect(suspended == nil && m.allowsRestart)
        _ = m.began()
        m.reset()
        let after = m.becameActive()
        #expect(m.allowsRestart && !after)
    }

    @Test("T-021q F-03 §14 row 1: a new interruption during a resume is not cleared by that resume")
    func beganDuringResume() {
        var m = MicInterruption()
        _ = m.began()
        _ = m.ended(shouldResume: true)
        _ = m.began()
        m.resumed()
        #expect(!m.allowsRestart)
    }
}
