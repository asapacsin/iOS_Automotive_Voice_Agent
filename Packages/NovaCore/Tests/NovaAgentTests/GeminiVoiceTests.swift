import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

/// F-07 §15 row 13 (T-020b): Gemini 原声 plays Gemini's own audio through the existing claim gate.
@Suite("T-020b F-07 §15 Gemini 原声 through the judged path")
struct GeminiVoiceTests {
    static let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])

    static func played(_ effects: [AgentEffect]) -> [TurnID] {
        effects.compactMap { if case .playReplyAudio(let t, _) = $0 { t } else { nil } }
    }

    static func gemini() -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false)
        d.connect()
        return d
    }

    @Test("T-020b row 13: a clean chat turn: no clause for a revoicer; each audio part released as it arrives")
    func chatTurn() {
        var d = Self.gemini()
        #expect(!d.state.revoicing)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("讲个笑话", isFinal: true))
        d.realtime(.responseStarted(t1))
        #expect(Self.played(d.realtime(.replyAudio(t1, Self.pcm))) == [t1])
        d.realtime(.replyText(t1, "好的，有一只小猫。"))
        #expect(Self.played(d.realtime(.replyAudio(t1, Self.pcm))) == [t1])
        #expect(Self.played(d.realtime(.audioDone(t1)) + d.realtime(.responseDone(t1, outcome: .completed))).isEmpty)
        #expect(spoken(d.effects).isEmpty)   // no Revoicer clause at all
        #expect(d.state.view.subtitle == "好的，有一只小猫。")
    }

    @Test("T-020b row 13: a claim in the transcript after 800 ms of audio played, then disproven: cut at once, claim-cut, nudge")
    func claimCut() {
        var d = Self.gemini()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("讲个笑话", isFinal: true))
        d.realtime(.responseStarted(t1))
        let second = PCMBuffer(sampleRate: 24_000, samples: Array(repeating: 0, count: 24_000))   // 1 s
        d.realtime(.replyText(t1, "好的，"))
        #expect(Self.played(d.realtime(.replyAudio(t1, second))) == [t1])
        d.now = d.now + .milliseconds(800)
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.realtime(.replyText(t1, "空调已经为您打开了。"))
        let cut = d.send(.toolFinished(t1, climateOn(), .failure(.vehicleUnavailable)))
        #expect(cut.contains(.diagnostic(.claimCut(turn: 1, playedMs: 800))))
        #expect(cut.contains(.flushPlayback(Epoch(1))))
        #expect(DiagnosticEvent.claimCut(turn: 1, playedMs: 800).logLine == "claim-cut turn=1 played_ms=800")
        #expect(d.state.view.subtitle.isEmpty)
        #expect(!d.fire(.correction).isEmpty)   // the correction nudge goes out
    }

    @Test("T-020b row 13: a proven control_climate turn: audio at the ok=true result")
    func provenTurn() {
        var d = Self.gemini()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: false))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        let held = d.realtime(.replyText(t1, "空调开了。")) + d.realtime(.replyAudio(t1, Self.pcm))
        #expect(Self.played(held).isEmpty)
        let proven = d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        #expect(Self.played(proven) == [t1])
        let response = index(proven) { if case .provider(.toolResponses) = $0 { true } else { false } }
        let play = index(proven) { if case .playReplyAudio = $0 { true } else { false } }
        #expect(response != nil && play != nil && response! < play!)
    }

    @Test("T-020b row 13: a disproven claim before any audio played: nothing heard, the turn voided")
    func disprovenTurn() {
        var d = Self.gemini()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: false))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.realtime(.replyText(t1, "空调已经为您打开了。"))
        d.realtime(.replyAudio(t1, Self.pcm))
        d.send(.toolFinished(t1, climateOn(), .failure(.vehicleUnavailable)))
        d.realtime(.audioDone(t1))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(Self.played(d.effects).isEmpty)
        #expect(d.effects.contains(.flushPlayback(Epoch(1))))
    }

    @Test("T-020b row 13: with revoicing (Qwen, Azure) Gemini's audio is never played, as before")
    func revoicingUnchanged() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("讲个笑话", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.replyAudio(t1, Self.pcm))
        d.realtime(.replyText(t1, "好的，有一只小猫。"))
        d.realtime(.audioDone(t1))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(Self.played(d.effects).isEmpty)
        #expect(spoken(d.effects) == "好的，有一只小猫。")
    }
}
