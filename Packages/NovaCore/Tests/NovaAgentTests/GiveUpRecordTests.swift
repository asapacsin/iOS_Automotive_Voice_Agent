import Testing
@testable import NovaAgent
import NovaKit
import NovaPorts
import NovaVoice

@Suite("T-016j F-24 §15 give-up through the agent core")
struct GiveUpRecordTests {
    @Test("§15 item 8: record lines for gave-up and resume, never a handle")
    func recordLines() {
        var recorder = ConversationRecorder()
        #expect(recorder.add(.sessionGaveUp(ms: 52_600, attempts: 11, code: .connection), atMs: 900)
                == ["900 session gave-up ms=52600 attempts=11 code=CONNECTION"])
        #expect(recorder.add(.sessionResume(handle: true, result: .resumed), atMs: 1_000)
                == ["1000 session resume handle=yes result=resumed"])
        #expect(recorder.add(.sessionResume(handle: false, result: .none), atMs: 1_100)
                == ["1100 session resume handle=no result=none"])
    }

    @Test("§15 rows 5: the core keeps the handle before the offline end is published; the next state sends it")
    func agentKeepsHandle() {
        var state = AgentState()
        var now = NovaInstant.zero
        var effects = state.handle(.start, at: now)
        effects += state.handle(.realtime(.setupComplete, connection: state.session.connection), at: now)
        effects += state.handle(.realtime(.resumptionHandle("h1"), connection: state.session.connection), at: now)
        effects += state.handle(.realtime(.closed, connection: state.session.connection), at: now)
        var guardCount = 0
        while state.session.state == .reconnecting, guardCount < 100 {
            guardCount += 1
            now = now + .seconds(8)
            // The delay timer firing is modelled by the session's own timer input.
            effects += state.handle(.realtime(.failed(RealtimeError(.connection)), connection: state.session.connection), at: now)
        }
        #expect(state.session.state == .disconnected)
        let keep = effects.firstIndex(of: .keepResumption("h1"))
        let ended = effects.lastIndex { if case .publish(let v) = $0 { v.offlineEnded } else { false } }
        #expect(keep != nil && ended != nil && keep! < ended!)
        #expect(effects.contains { if case .diagnostic(.sessionGaveUp(_, _, .connection)) = $0 { true } else { false } })
        #expect(!effects.contains { if case .publish(let v) = $0 { v.configError != nil } else { false } })

        var next = AgentState(truthfulness: TruthfulnessTuning(), resume: SessionResume(handle: "h1"))
        let connects = next.handle(.start, at: now).compactMap {
            if case .provider(.connect(_, let resume)) = $0 { resume } else { nil }
        }
        #expect(connects == ["h1"])
    }
}
