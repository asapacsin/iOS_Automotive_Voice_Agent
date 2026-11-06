import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-016k F-24 §16 VPN path, quick-close handle drop")
struct VpnNetworkRecoveryTests {
    static func snap(satisfied: Bool = true, wifi: Bool = false, cellular: Bool = false, wired: Bool = false,
                     other: Bool = false) -> NetworkPathSnapshot {
        NetworkPathSnapshot(satisfied: satisfied, wifi: wifi, cellular: cellular, wired: wired, other: other)
    }

    @Test("T-016k F-24 §16 row 1: network means a real interface; a tunnel alone is unavailable unless the switch is off")
    func row1Snapshots() {
        let snapshots = [Self.snap(wifi: true), Self.snap(cellular: true), Self.snap(wired: true),
                         Self.snap(other: true), Self.snap(satisfied: false, wifi: true)]
        #expect(snapshots.map { $0.available() } == [true, true, true, false, false])
        #expect(snapshots.map { $0.available(requirePhysicalInterface: false) } == [true, true, true, true, false])
        #expect(RealtimeTuning().requirePhysicalInterface)
        // A VPN path over Wi-Fi (`utun5 … uses wifi`) is available.
        #expect(Self.snap(wifi: true, other: true).available())
        #expect(Self.snap(wifi: true, other: true).diagnostic.logLine == "networkPath satisfied=true via=wifi tunnel=true")
        #expect(Self.snap(other: true).diagnostic.logLine == "networkPath satisfied=true via=none tunnel=true")
        #expect(Self.snap(cellular: true).diagnostic.logLine == "networkPath satisfied=true via=cell tunnel=false")
        #expect(Self.snap(satisfied: false, wired: true).diagnostic.logLine
                == "networkPath satisfied=false via=wired tunnel=false")
    }

    @Test("F-24 §16 row 2: tunnel-only for 300 ms is not reported; for 600 ms it is lost, then restored")
    func row2Watcher() {
        var w = NetworkPathEvaluator()
        var reports: [Bool] = []
        var lines: [String] = []
        var tick: NovaInstant?
        func feed(_ s: NetworkPathSnapshot, at ms: Int64) {
            let (line, report, tickAt) = w.path(s, at: NovaInstant(milliseconds: ms))
            if let line { lines.append(line.logLine) }
            if let report { reports.append(report) }
            if let tickAt { tick = tickAt }
        }
        func advance(to ms: Int64) {
            if let t = tick, t.milliseconds <= ms {
                tick = nil
                if let report = w.tick(at: t) { reports.append(report) }
            }
        }
        let wifi = Self.snap(wifi: true, other: true)
        let tunnel = Self.snap(other: true)
        feed(wifi, at: 0)
        feed(tunnel, at: 1_000)
        advance(to: 1_300)
        feed(wifi, at: 1_300)
        advance(to: 2_000)
        #expect(reports.isEmpty)
        feed(tunnel, at: 3_000)
        advance(to: 3_600)
        #expect(reports == [false])
        feed(wifi, at: 3_600)
        #expect(reports == [false, true])
        #expect(lines.count == 5 && lines.allSatisfy { $0.hasPrefix("networkPath satisfied=true via=") })
        // The same snapshot again logs nothing.
        feed(wifi, at: 4_000)
        #expect(lines.count == 5)
    }

    @Test("F-24 §16 row 3: two resumed attempts closed 0.5 s after 101: the third sends no handle")
    func row3QuickClose() {
        var h = SessionHarness(session: VoiceSession(resume: SessionResume(handle: "h1")))
        h.send(.start)
        h.advance(by: .milliseconds(500))
        h.server(.failed(RealtimeError(.connectionClosed)))  // server close, before setupComplete
        #expect(h.session.resumptionHandle == "h1" && h.session.quickCloses == 1)
        let (_, at) = h.timers[.reconnectDelay]!
        h.advance(by: at - h.now)
        h.advance(by: .milliseconds(500))
        h.server(.failed(RealtimeError(.connectionClosed)))
        #expect(h.log.contains(.diagnostic(.resumeDropped(reason: .quickClose))))
        #expect(DiagnosticEvent.resumeDropped(reason: .quickClose).logLine == "resumeDropped reason=quickClose")
        #expect(h.session.resumptionHandle == nil)
        h.advance(by: .seconds(1))
        #expect(h.connects.map(\.1) == ["h1", "h1", nil])
        // A new session: she does not claim the lost turn (the resume report says the handle was rejected).
        h.server(.setupComplete)
        #expect(h.log.contains(.diagnostic(.resumed(handle: false))))
        #expect(h.log.contains(.diagnostic(.sessionResume(handle: true, result: .rejected))))
        // The §15 kept handle is cleared: a later give-up keeps none.
        h.server(.closed)
        while let (_, at) = h.timers[.reconnectDelay] {
            h.advance(by: at - h.now)
            h.server(.failed(RealtimeError(.connection, unreachable: true)))
        }
        #expect(h.log.contains(.keepHandle(nil)) && !h.log.contains(.keepHandle("h1")))
    }

    @Test("F-24 §16 row 3: closes past 3 s after setup, or unreachable ones, keep the handle")
    func row3NotQuick() {
        var h = SessionHarness()
        h.connected()
        h.server(.resumptionHandle("h1"))
        for _ in 0..<3 {
            let (_, at) = h.timers[.reconnectDelay] ?? (SessionTimer(kind: .reconnectDelay, epoch: .initial), h.now)
            h.advance(by: at - h.now)
            if h.session.state == .reconnecting { h.server(.setupComplete) }
            h.advance(by: .seconds(4))
            h.server(.failed(RealtimeError(.connectionClosed)))
        }
        #expect(h.session.resumptionHandle == "h1" && h.session.quickCloses == 0)
        for _ in 0..<3 {
            let (_, at) = h.timers[.reconnectDelay]!
            h.advance(by: at - h.now)
            h.advance(by: .milliseconds(500))
            h.server(.failed(RealtimeError(.disconnect, unreachable: true)))
        }
        #expect(h.session.resumptionHandle == "h1")
        #expect(!h.log.contains(.diagnostic(.resumeDropped(reason: .quickClose))))
    }

    @Test("F-24 §16 item 3: ping every 10 s, pong due in 5 s")
    func pingTuning() {
        #expect(RealtimeTuning().pingInterval == .seconds(10) && RealtimeTuning().pongTimeout == .seconds(5))
    }
}
