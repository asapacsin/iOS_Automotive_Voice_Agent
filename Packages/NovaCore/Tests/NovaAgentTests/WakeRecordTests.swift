import Foundation
import Testing
@testable import NovaAgent
import NovaKit
import NovaPorts
import NovaVoice

/// The record lines a session writes for its start, driven the way the runtime drives them: the header from
/// `SessionOrigin`, `wake-to-listening` from `WakeSessionWatch`, `wake-unused` at the end.
@Suite("T-060a F-01 §14 item 12 wake record lines")
struct WakeRecordTests {
    private func header(_ origin: SessionOrigin) -> RecordHeader {
        RecordHeader(appVersion: "1.0(9)", comfortMode: "table", interruptible: false, speakingStyle: "default",
                     startedBy: origin.startedBy)
    }

    /// Runs one session: its UI states, then whether a sent utterance came, then the end. Returns the lines.
    private func session(_ origin: SessionOrigin, clock: ManualClock, states: [(SessionUIState, Int64)],
                         sent: Bool) -> [String] {
        let watch = WakeSessionWatch(origin: origin, clock: clock)
        var recorder = ConversationRecorder()
        var lines = header(origin).lines
        var cues = 0
        for (state, advance) in states {
            clock.advance(by: .milliseconds(advance))
            for effect in watch.sessionState(state) {
                switch effect {
                case .playCue: cues += 1
                case .wakeToListening(let ms): lines += recorder.add(.wakeToListening(ms: ms), atMs: clock.now.milliseconds)
                }
            }
        }
        if sent { watch.speechStarted(sentToModel: true) }
        if watch.end() { lines += recorder.add(.wakeUnused, atMs: clock.now.milliseconds) }
        lines.append("cues=\(cues)")
        return lines
    }

    @Test("F-01 §14 row 6: startedBy is right; the sound and wake-to-listening only for a wake, once, not after a reconnect")
    func row6StartedBy() {
        let clock = ManualClock()
        let woke = clock.now
        let lines = session(.wake(at: woke), clock: clock,
                            states: [(.connecting, 100), (.listening, 2_100), (.reconnecting, 9_000), (.listening, 1_500)],
                            sent: true)
        #expect(lines.contains("startedBy wake"))
        #expect(lines.filter { $0.contains("wake-to-listening") } == ["2200 wake-to-listening ms=2200"])
        #expect(lines.last == "cues=1")
        #expect(!lines.contains { $0.contains("wake-unused") })

        let tapped = session(.tap, clock: clock, states: [(.connecting, 100), (.listening, 1_800)], sent: false)
        #expect(tapped.contains("startedBy tap"))
        #expect(!tapped.contains { $0.contains("wake-to-listening") || $0.contains("wake-unused") })
        #expect(tapped.last == "cues=0")
    }

    @Test("F-01 §14 row 8: a woken session that ends with no utterance writes wake-unused once")
    func row8WakeUnused() {
        let clock = ManualClock()
        let lines = session(.wake(at: clock.now), clock: clock, states: [(.connecting, 50), (.listening, 1_950)], sent: false)
        #expect(lines.filter { $0.hasSuffix("wake-unused") }.count == 1)
        #expect(lines.contains("2000 wake-unused"))
    }

    @Test("F-01 §14 row 6: through the core's own session states, the sound plays once and not after a reconnect")
    func row6ThroughCore() {
        var d = Drive()
        var start = WakeSessionStart(origin: .wake(at: .zero))
        var effects: [WakeSessionEffect] = []
        /// What `RuntimeSink.diagnostic` does with each effect batch.
        func sink(_ out: [AgentEffect]) {
            for case .diagnostic(.sessionState(let state)) in out { effects += start.sessionState(state, at: d.now) }
        }
        sink(d.send(.start))
        d.now = d.now + .milliseconds(2_300)
        sink(d.realtime(.setupComplete))
        #expect(effects == [.wakeToListening(ms: 2_300), .playCue])
        // The socket drops and comes back: listening again, no second sound.
        sink(d.realtime(.failed(RealtimeError(.disconnect))))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        sink(d.send(.timer(.session(timer.last!))))
        let resumed = d.realtime(.setupComplete)
        #expect(resumed.contains(.diagnostic(.sessionState(.listening))))
        sink(resumed)
        #expect(effects.filter { $0 == .playCue }.count == 1)
    }

    @Test("F-01 §14 item 12: no startedBy line when none is given; the header never carries words")
    func headerOptional() {
        let plain = RecordHeader(appVersion: "1.0(9)", comfortMode: "table", interruptible: false, speakingStyle: "default")
        #expect(!plain.lines.contains { $0.hasPrefix("startedBy") })
    }

    @Test("F-01 §14 item 12: wakeDetected is a diagnostic with no words")
    func wakeDetectedLog() {
        #expect(DiagnosticEvent.wakeDetected.logLine == "wakeDetected")
        #expect(DiagnosticEvent.wakeDetected.kind == .wakeDetected)
    }
}
