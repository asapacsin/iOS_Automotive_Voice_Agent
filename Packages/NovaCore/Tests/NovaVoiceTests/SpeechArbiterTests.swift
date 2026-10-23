import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-022 F-08 minimal arbiter")
struct SpeechArbiterTests {
    @Test("F-08 W2 qualified barge-in: flush first, then cancel revoicing, then notify; new epoch")
    func bargeInOrder() {
        var a = SpeechArbiter()
        _ = a.handle(.replyPlaying(true))
        let e = a.epoch.next()
        let effects = a.handle(.speechStarted(recentSpeech: true))
        #expect(effects == [.flushPlayback(e), .cancelRevoicing(e), .bargeIn(qualified: true)])
        #expect(a.epoch == e && !a.replyPlaying)
    }

    @Test("F-08 W2 end to end with fakes: clause 3 of the old epoch is never played")
    func bargeInWithRevoicer() {
        var a = SpeechArbiter()
        var q = RevoicerQueue(epoch: a.epoch)
        let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
        let old = q.epoch
        for c in ["一。", "二。", "三。"] { _ = q.handle(.clause(c)) }
        _ = q.handle(.synthesized(epoch: old, sequence: 0, .success(pcm)))
        _ = a.handle(.replyPlaying(true))
        var played: [RevoicerOutput] = []
        for effect in a.handle(.speechStarted(recentSpeech: true)) {
            if case .cancelRevoicing(let e) = effect { played += q.handle(.cancel(newEpoch: e)) }
        }
        played += q.handle(.synthesized(epoch: old, sequence: 1, .success(pcm)))
        played += q.handle(.synthesized(epoch: old, sequence: 2, .success(pcm)))
        #expect(!played.contains { if case .play = $0 { true } else { false } })
        #expect(q.epoch == a.epoch)
    }

    @Test("F-08 unqualified speech over playback is residual echo: nothing is flushed")
    func unqualified() {
        var a = SpeechArbiter()
        _ = a.handle(.replyPlaying(true))
        let before = a.epoch
        #expect(a.handle(.speechStarted(recentSpeech: false)) == [.bargeIn(qualified: false)])
        #expect(a.epoch == before && a.replyPlaying)
        var idle = SpeechArbiter()
        #expect(idle.handle(.speechStarted(recentSpeech: true)).isEmpty)
    }

    @Test("F-08 R1 guidance speaking holds a ready reply until guidance ends")
    func guidanceHold() {
        var a = SpeechArbiter()
        _ = a.handle(.guidanceSpeaking(true))
        #expect(a.reply == .hold)
        _ = a.handle(.guidanceSpeaking(false))
        #expect(a.reply == .play)
    }

    @Test("F-08 R5: an interruption or a lost route holds; R4: reset media services drops and flushes")
    func focus() {
        var a = SpeechArbiter()
        _ = a.handle(.audioSession(.interruptionBegan))
        #expect(a.reply == .hold)
        _ = a.handle(.audioSession(.interruptionEnded(shouldResume: true)))
        #expect(a.reply == .play)
        _ = a.handle(.replyPlaying(true))
        #expect(a.handle(.audioSession(.routeLost)).isEmpty && a.reply == .hold)
        a.regainFocus()
        let effects = a.handle(.audioSession(.mediaServicesReset))
        #expect(a.reply == .drop && effects.first == .flushPlayback(a.epoch))
        var b = SpeechArbiter()
        _ = b.handle(.audioSession(.interruptionEnded(shouldResume: false)))
        #expect(b.reply == .drop)
        a.regainFocus()
        #expect(a.reply == .play)
    }

    @Test("F-08 recent speech needs 200 ms voiced within the last 600 ms")
    func recentSpeech() {
        var gate = SpeechUplinkGate()
        for f in PCM.noise(rms: 60, frames: 150, seed: 1) { _ = gate.process(f) }
        for f in PCM.tone(peak: 6000, frames: 19) { _ = gate.process(f) }
        #expect(!gate.hasRecentSpeech)
        _ = gate.process(PCM.tone(peak: 6000, frames: 1)[0])
        #expect(gate.hasRecentSpeech)
        for f in PCM.noise(rms: 60, frames: 41, seed: 3) { _ = gate.process(f) }
        #expect(!gate.hasRecentSpeech)
    }
}
