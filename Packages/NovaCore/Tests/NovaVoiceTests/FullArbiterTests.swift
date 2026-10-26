import Testing
@testable import NovaKit
@testable import NovaVoice

private func at(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }

@Suite("T-052 F-08 full arbiter")
struct FullArbiterTests {
    @Test("F-08 §10 row 2: a reply ready while guidance speaks is held, and plays after guidance")
    func guidanceHold() {
        var a = SpeechArbiter()
        a.guidance(true, at: at(0))
        let v1 = a.decide(at: at(100))
        #expect(v1.0 == .hold)
        a.guidance(false, at: at(2000))
        let v2 = a.decide(at: at(2000))
        #expect(v2.0 == .hold && v2.wake == at(2500))
        let v2b = a.decide(at: at(2500))
        #expect(v2b.0 == .play)
    }

    @Test("F-08 R6 judges a reply when it is first ready: a workload hold past the 10 s window still plays")
    func admittedBeforeHold() {
        var a = SpeechArbiter()
        a.setNavigating(true)
        a.driverSpoke(at: at(0))
        a.setManoeuvreDistance(120)
        let held = a.decide(at: at(3000))
        #expect(held.0 == .hold && held.wake == at(11_000))
        let late = a.decide(at: at(11_000))
        #expect(late.0 == .play)
    }

    @Test("F-08 §10 row 3: within 150 m of a manoeuvre an unstarted reply is held at most 8 s")
    func workloadHold() {
        var a = SpeechArbiter()
        a.setNavigating(true)
        a.driverSpoke(at: at(0))
        a.setManoeuvreDistance(120)
        let first = a.decide(at: at(1000))
        #expect(first.0 == .hold && first.wake == at(9000))
        let v3 = a.decide(at: at(8999))
        #expect(v3.0 == .hold)
        let v4 = a.decide(at: at(9000))
        #expect(v4.0 == .play)
        // A reply already started is not held again mid-way.
        a.setManoeuvreDistance(40)
        let v5 = a.decide(at: at(9100))
        #expect(v5.0 == .play)
    }

    @Test("F-08 R6a: the hold ends early when the distance jumps by more than 20 m (manoeuvre passed)")
    func workloadJump() {
        var a = SpeechArbiter()
        a.setNavigating(true)
        a.driverSpoke(at: at(0))
        a.setManoeuvreDistance(60)
        let v6 = a.decide(at: at(500))
        #expect(v6.0 == .hold)
        a.setManoeuvreDistance(75)
        let v7 = a.decide(at: at(600))
        #expect(v7.0 == .hold)
        a.setManoeuvreDistance(900)
        let v8 = a.decide(at: at(700))
        #expect(v8.0 == .play)
    }

    @Test("F-08 R6: while navigating an unprompted reply outside the 10 s window is dropped; guidance readings are exempt")
    func permittedWindow() {
        var a = SpeechArbiter()
        a.setNavigating(true)
        let v9 = a.decide(at: at(0))
        #expect(v9.0 == .drop)
        let v10 = a.decide(at: at(0), exempt: true)
        #expect(v10.0 == .play)
        a.newReply()
        a.driverSpoke(at: at(1000))
        let v11 = a.decide(at: at(11_000))
        #expect(v11.0 == .play)
        a.newReply()
        let v12 = a.decide(at: at(11_001))
        #expect(v12.0 == .drop)
        a.setNavigating(false)
        let v13 = a.decide(at: at(60_000))
        #expect(v13.0 == .play)
    }

    @Test("F-08 R4 outranks R6 and R1: a permanent focus loss drops even a guidance reading")
    func order() {
        var a = SpeechArbiter()
        _ = a.handle(.audioSession(.mediaServicesReset))
        a.guidance(true, at: at(0))
        let v14 = a.decide(at: at(0), exempt: true)
        #expect(v14.0 == .drop)
    }

    @Test("F-08 uplink: closed while guidance speaks and for the 500 ms tail")
    func uplinkTail() {
        var a = SpeechArbiter()
        let v15 = a.uplink(at: at(0))
        #expect(v15.open)
        a.guidance(true, at: at(0))
        let closed = a.uplink(at: at(0))
        #expect(!closed.open && closed.wake == at(20_000))
        a.guidance(false, at: at(3000))
        let tail = a.uplink(at: at(3000))
        #expect(!tail.open && tail.wake == at(3500))
        let v16 = a.uplink(at: at(3500))
        #expect(v16.open)
    }

    @Test("F-08 uplink reopens after at most 20 s even while guidance still sounds")
    func uplinkCap() {
        var a = SpeechArbiter()
        a.guidance(true, at: at(0))
        _ = a.uplink(at: at(0))
        let v17 = a.uplink(at: at(19_999))
        #expect(!v17.open)
        let v18 = a.uplink(at: at(20_000))
        #expect(v18.open)
    }

    @Test("F-08 R0: a driver mid-utterance when guidance starts keeps the uplink up to 8 s")
    func midUtterance() {
        var a = SpeechArbiter()
        a.driverSpeech(true)
        a.guidance(true, at: at(1000))
        let kept = a.uplink(at: at(1000))
        #expect(kept.open && kept.wake == at(9000))
        let v19 = a.uplink(at: at(9000))
        #expect(!v19.open)
    }
}
