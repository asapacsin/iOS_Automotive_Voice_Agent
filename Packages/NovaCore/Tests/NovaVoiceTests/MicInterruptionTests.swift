import Testing
@testable import NovaVoice

@Suite("T-021q F-03 §14 another app takes the microphone")
struct MicInterruptionTests {
    @Test("T-021q F-03 §14 row 1: interrupted blocks the restart; shouldResume resumes at once")
    func resumeNow() {
        var m = MicInterruption()
        #expect(m.allowsRestart)
        let began = m.began()
        #expect(began == "audio interrupted")
        #expect(!m.allowsRestart)
        let e = m.ended(shouldResume: true)
        #expect(e.resume && e.line == "audio interruption-ended resume=now" && m.allowsRestart)
    }

    @Test("T-021q F-03 §14 row 2: ended without shouldResume waits until the app is active again")
    func resumeOnReturn() {
        var m = MicInterruption()
        _ = m.began()
        let e = m.ended(shouldResume: false)
        #expect(!e.resume && e.line == "audio interruption-ended resume=on-return" && !m.allowsRestart)
        let first = m.becameActive()
        #expect(first && m.allowsRestart)
        let second = m.becameActive()
        #expect(!second)
    }

    @Test("T-021q F-03 §14 row 3: no interruption: becoming active or a stray end changes nothing")
    func noInterruption() {
        var m = MicInterruption()
        let active = m.becameActive()
        #expect(!active)
        let stray = m.ended(shouldResume: true)
        #expect(!stray.resume && m.allowsRestart)
        _ = m.began()
        m.reset()
        let after = m.becameActive()
        #expect(m.allowsRestart && !after)
    }
}
