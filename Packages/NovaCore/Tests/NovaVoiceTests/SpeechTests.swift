import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-020 F-07 clause segmenter and wait cues")
struct SegmenterTests {
    @Test("F-07 clauses cut at sentence ends, long-enough commas and 40 chars; first may be short")
    func segment() {
        var s = ClauseSegmenter()
        #expect(s.append("好的，") == ["好的，"])
        #expect(s.append("空调已经打开，温度") == [])
        #expect(s.append("调到二十二度了。") == ["空调已经打开，温度调到二十二度了。"])
        #expect(s.append(String(repeating: "啊", count: 40)) == [String(repeating: "啊", count: 40)])
        #expect(s.append("尾巴") == [] && s.flush() == "尾巴")
        #expect(s.append("。。") == [] && s.flush() == nil)
        s.reset()
        #expect(s.append("嗯，") == [])
    }

    @Test("F-07 placeholders are never read aloud")
    func speakable() {
        #expect(speakableText("<no speech>{pause}") == nil)
        #expect(speakableText(" 好的<break/>，{pause}马上 ") == "好的，马上")
    }

    @Test("F-07 wait cues at 3, 7 and 12 s, once each; a late wake says only the delay")
    func cues() {
        var t = WaitCueTurn()
        #expect(t.due(.seconds(2)) == nil)
        #expect(t.due(.seconds(3))?.code == .visual)
        #expect(t.due(.seconds(7)) == WaitCue(code: .progress, text: "收到，正在处理。"))
        #expect(t.due(.seconds(8)) == nil)
        #expect(t.due(.seconds(12))?.text == WaitCues.delay)
        var late = WaitCueTurn()
        _ = late.due(.seconds(13))
        #expect(late.due(.seconds(13))?.code == .delay)
        var quiet = WaitCueTurn()
        quiet.suspiciousAudio = true
        #expect(quiet.due(.seconds(20)) == nil)
        #expect(WaitCues.nextThreshold(after: .seconds(7)) == .seconds(12))
        #expect(WaitCues.toolPhrase("query_live_info") == "正在查询，稍等一下。")
    }
}

@Suite("T-020 F-07 revoicer queue")
struct RevoicerQueueTests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [1])

    @Test("F-07 at most two requests in flight; audio released strictly in clause order")
    func order() {
        var q = RevoicerQueue()
        let e = q.epoch
        let first = q.handle(.clause("一。")) + q.handle(.clause("二。")) + q.handle(.clause("三。"))
        #expect(first.count == 2)
        #expect(first[0] == .synthesize(epoch: e, sequence: 0, text: "一。", deadline: .milliseconds(4800)))
        // Clause 1 returns first: held until clause 0.
        #expect(q.handle(.synthesized(epoch: e, sequence: 1, .success(pcm))) == [.synthesize(epoch: e, sequence: 2, text: "三。", deadline: .milliseconds(4800))])
        #expect(q.handle(.synthesized(epoch: e, sequence: 0, .success(pcm)))
                == [.play(epoch: e, sequence: 0, pcm), .play(epoch: e, sequence: 1, pcm)])
        #expect(q.handle(.synthesized(epoch: e, sequence: 2, .success(pcm))) == [.play(epoch: e, sequence: 2, pcm)])
    }

    @Test("F-07 barge-in during clause 2: clause 3 never plays")
    func bargeIn() {
        var q = RevoicerQueue()
        let e = q.epoch
        _ = q.handle(.clause("一。")); _ = q.handle(.clause("二。")); _ = q.handle(.clause("三。"))
        _ = q.handle(.synthesized(epoch: e, sequence: 0, .success(pcm)))  // clause 1 plays, clause 2 + 3 underway
        let cancels = q.handle(.cancel(newEpoch: e.next()))
        #expect(cancels == [.cancelSynthesis(epoch: e, sequence: 1), .cancelSynthesis(epoch: e, sequence: 2)])
        #expect(q.handle(.synthesized(epoch: e, sequence: 2, .success(pcm))).isEmpty)
        #expect(q.handle(.synthesized(epoch: e, sequence: 1, .success(pcm))).isEmpty)
        #expect(q.pendingClauses == 0 && q.epoch == e.next())
    }

    @Test("F-07 Azure 401: the reply goes quiet once, nothing else plays, no fallback audio")
    func authFailure() {
        var q = RevoicerQueue()
        let e = q.epoch
        _ = q.handle(.clause("一。")); _ = q.handle(.clause("二。")); _ = q.handle(.clause("三。"))
        let out = q.handle(.synthesized(epoch: e, sequence: 0, .failure(SpeechSynthesisError("AZURE_TTS_AUTH"))))
        #expect(out == [.cancelSynthesis(epoch: e, sequence: 1), .failed(code: "AZURE_TTS_AUTH")])
        #expect(q.handle(.clause("四。")).isEmpty)
        #expect(!out.contains { if case .play = $0 { true } else { false } })
    }

    @Test("F-07 a failure silences only its own reply")
    func failureIsPerReply() {
        var q = RevoicerQueue()
        let e = q.epoch
        _ = q.handle(.clause("一。"))
        _ = q.handle(.synthesized(epoch: e, sequence: 0, .failure(SpeechSynthesisError("AZURE_TTS_TIMEOUT"))))
        #expect(q.handle(.clause("二。")).isEmpty)
        _ = q.handle(.newReply)
        #expect(q.handle(.clause("三。")).count == 1)
    }

    @Test("F-07 deadline is 4000 + 400 ms per character")
    func deadline() {
        var q = RevoicerQueue()
        guard case .synthesize(_, _, _, let d)? = q.handle(.clause("十个字十个字十个字十")).first else { Issue.record(); return }
        #expect(d == .milliseconds(8000))
    }
}
