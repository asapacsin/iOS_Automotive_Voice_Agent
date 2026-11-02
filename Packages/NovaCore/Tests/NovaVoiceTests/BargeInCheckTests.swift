import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

private let her = BargeInCheck.syllables("珠海有很多好玩的地方")

/// A candidate that passes every stage; each test breaks one.
private func good(_ words: String = "不是明天") -> BargeInCheck.Candidate {
    BargeInCheck.Candidate(sinceEngineStart: .seconds(10), classifierMax: 0.9, peakDb: 80, barDb: 72,
                           duration: .milliseconds(1500), partials: [(.milliseconds(500), words)], final: words,
                           herSyllables: her)
}

@Suite("T-022d F-08 §17 barge-in check (log-only)")
struct BargeInCheckTests {
    @Test("Row 1: each stage's failing input gives its reason; missing classifier is notSpeech")
    func stages() {
        #expect(BargeInCheck.judge(good()).reason == .wouldStop)
        var c = good(); c.sinceEngineStart = .seconds(2)
        #expect(BargeInCheck.judge(c).reason == .settling)
        c = good(); c.classifierMax = nil
        #expect(BargeInCheck.judge(c).reason == .notSpeech)
        c = good(); c.classifierMax = 0.69
        #expect(BargeInCheck.judge(c).reason == .notSpeech)
        c = good(); c.peakDb = 71
        #expect(BargeInCheck.judge(c).reason == .lowLevel)
        c = good(); c.duration = .milliseconds(290)
        #expect(BargeInCheck.judge(c).reason == .tooShort)
        c = good("别说了")
        #expect(BargeInCheck.judge(c).reason == .stopPhrase)
        c = good(); c.partials = [(.milliseconds(1400), "不是明天")]; c.final = ""
        #expect(BargeInCheck.judge(c).reason == .noWords)
        c = good(); c.partials = []; c.final = nil
        #expect(BargeInCheck.judge(c).reason == .noWords)
        // Late partial but words in the final: passes the words stage.
        c = good(); c.partials = [(.milliseconds(1400), "不是明天")]
        #expect(BargeInCheck.judge(c).reason == .wouldStop)
        c = good("珠海好玩")
        #expect(BargeInCheck.judge(c).reason == .echoWords)
        #expect(BargeInCheck.judge(good("对对")).reason == .echoWords)
    }

    @Test("Row 2: driver bar 72 with fewer than 3, median 85 → 75, 95 → 80, 60 → 70")
    func bar() {
        #expect(BargeInCheck.driverBar([90, 90]) == 72)
        #expect(BargeInCheck.driverBar([85, 85, 85]) == 75)
        #expect(BargeInCheck.driverBar([80, 85, 90]) == 75)
        #expect(BargeInCheck.driverBar([95, 95, 95, 95]) == 80)
        #expect(BargeInCheck.driverBar([60, 60, 60]) == 70)
        // Only the last 10 count.
        #expect(BargeInCheck.driverBar(Array(repeating: 60, count: 5) + Array(repeating: 85, count: 10)) == 75)
    }

    @Test("Row 3: her words as heard / misheard alike / 不是明天 / 嗯嗯")
    func echo() {
        #expect(BargeInCheck.judge(good("珠海有很多好玩的地方")).reason == .echoWords)
        #expect(BargeInCheck.judge(good("朱海有很多好完的地方")).reason == .echoWords)
        #expect(BargeInCheck.judge(good("不是明天")).reason == .wouldStop)
        // 嗯嗯 is one syllable: the echo stage rejects it. Run through all stages it already fails at noWords
        // (嗯 is a filler), which comes first in item 3's order.
        #expect(BargeInCheck.echoMeasure(BargeInCheck.syllables("嗯嗯"), her: her).isEcho)
        #expect(BargeInCheck.judge(good("嗯嗯")).reason == .noWords)
    }

    @Test("Row 4: log-only — wouldStop changes no output and logs one line without words")
    func logOnly() {
        var shadow = BargeInShadow()
        var gate = PostStopHold()
        shadow.herWords("珠海有很多好玩的地方")
        // 4 s pass (settling), she is talking.
        for _ in 0..<400 { shadow.frame([], peakDb: 50, speechProbability: 0.1, muteReason: .reply) }
        let start: [UplinkGateOutput] = [.speechStarted(sentToModel: false)]
        shadow.frame(start, peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        #expect(gate.frame(start) == start)  // the hold, as the gate's follower, sees it unchanged
        for _ in 0..<50 { shadow.frame([.audio(.silence)], peakDb: 85, speechProbability: 0.9, muteReason: .reply) }
        shadow.partial("不是明天", utterance: 1)
        #expect(shadow.takeLogs() == ["wouldStopAt 1 ms=500"])
        for _ in 0..<50 { shadow.frame([.audio(.silence)], peakDb: 80, speechProbability: 0.9, muteReason: .reply) }
        let record = UtteranceRecord(id: 1, startMs: 0, endMs: 1000, endReason: .silence, sentToModel: false,
                                     muteReason: .reply, peakDb: 85, noiseFloorDb: 40, classifierMax: 0.9)
        shadow.frame([.speechStopped(.normal), .utterance(record)], peakDb: 40, speechProbability: 0.1, muteReason: .reply)
        shadow.final("不是明天", utterance: 1)
        let logs = shadow.takeLogs()
        #expect(logs == ["bargeInShadow 1 outcome=wouldStop reason=wouldStop peakDb=85 barDb=72 durationMs=1010 "
                         + "firstWordMs=500 newSyllables=4 runSyllables=0 totalSyllables=4"])
        for line in logs { #expect(!line.contains("明天") && !line.contains("珠海")) }
    }

    @Test("Row 4: a final that never comes is judged 2 s after the close; silent-time utterances log levelCheck")
    func noFinalAndLevel() {
        var shadow = BargeInShadow()
        for _ in 0..<400 { shadow.frame([], peakDb: 50, speechProbability: nil, muteReason: .reply) }
        shadow.frame([.speechStarted(sentToModel: false)], peakDb: 85, speechProbability: nil, muteReason: .reply)
        let r = UtteranceRecord(id: 1, startMs: 0, endMs: 0, endReason: .silence, sentToModel: false, muteReason: .reply,
                                peakDb: 85, noiseFloorDb: 40, classifierMax: 0)
        shadow.frame([.utterance(r)], peakDb: 40, speechProbability: nil, muteReason: .reply)
        for _ in 0..<200 { shadow.frame([], peakDb: 40, speechProbability: nil, muteReason: .none) }
        #expect(shadow.takeLogs().first?.hasPrefix("bargeInShadow 1 outcome=rejected reason=notSpeech") == true)
        // Three sent utterances with words while she is silent set the bar.
        for id in 2...4 {
            shadow.frame([.speechStarted(sentToModel: true)], peakDb: 90, speechProbability: 0.9, muteReason: .none)
            let s = UtteranceRecord(id: id, startMs: 0, endMs: 0, endReason: .silence, sentToModel: true, muteReason: .none,
                                    peakDb: 90, noiseFloorDb: 40, classifierMax: 0.9)
            shadow.frame([.utterance(s)], peakDb: 40, speechProbability: nil, muteReason: .none)
            shadow.final("导航回家", utterance: id)
        }
        #expect(shadow.barDb == 80)
        #expect(shadow.takeLogs().first == "levelCheck 2 peakDb=90 barDb=72 below=false")
    }

    @Test("Row 5: echo tail 800 ms by default; endEchoTail still clears it")
    func echoTail() {
        #expect(UplinkGateTuning().echoTail == .milliseconds(800))
        var gate = SpeechUplinkGate()
        gate.setPlaying(reply: true)
        gate.setPlaying(reply: false)
        #expect(gate.muteReason == .echoTail)
        gate.endEchoTail()
        #expect(gate.muteReason == .none)
    }

    @Test("Row 6: reply audio after the mute ended in the same turn logs muteEndedMidReply")
    func muteEnd() {
        var watch = MuteEndWatch()
        let e = Epoch(3)
        #expect(watch.replyStarted(e) == nil)
        watch.muteEnded(e)
        #expect(watch.replyStarted(e) == "muteEndedMidReply epoch=3")
        watch.muteEnded(e)
        #expect(watch.replyStarted(e.next()) == nil)
        // Back-to-back replies keep the epoch; a new model turn between them is not mid-reply.
        watch.muteEnded(e)
        watch.newTurn()
        #expect(watch.replyStarted(e) == nil)
    }

    @Test("Row 3/4: growing partials 我 → 我问 → 我问的是明天 reach wouldStop mid-utterance; firstWordMs from the first")
    func growingPartials() {
        var shadow = BargeInShadow()
        shadow.herWords("珠海有很多好玩的地方")
        for _ in 0..<400 { shadow.frame([], peakDb: 50, speechProbability: 0.1, muteReason: .reply) }
        shadow.frame([.speechStarted(sentToModel: false)], peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        for (n, text) in [(39, "我"), (20, "我问"), (20, "我问的是明天")] {
            for _ in 0..<n { shadow.frame([.audio(.silence)], peakDb: 85, speechProbability: 0.9, muteReason: .reply) }
            shadow.partial(text, utterance: 1)
        }
        #expect(shadow.takeLogs() == ["wouldStopAt 1 ms=590"])
        let record = UtteranceRecord(id: 1, startMs: 0, endMs: 0, endReason: .cutAtUnmute, sentToModel: false,
                                     muteReason: .reply, peakDb: 85, noiseFloorDb: 40, classifierMax: 0.9)
        shadow.frame([.utterance(record)], peakDb: 40, speechProbability: nil, muteReason: .none)
        // No final comes: judged 2 s after the close on the newest partial.
        for _ in 0..<200 { shadow.frame([], peakDb: 40, speechProbability: nil, muteReason: .none) }
        let line = shadow.takeLogs().first { $0.hasPrefix("bargeInShadow") }
        #expect(line?.contains("outcome=wouldStop") == true)
        #expect(line?.contains("firstWordMs=390") == true)
    }

    @Test("Item 5: her words stay while she talks and are forgotten 10 s after her playback ends")
    func herMemory() {
        var shadow = BargeInShadow()
        shadow.herWords("珠海有很多好玩的地方")
        // 15 s of her talking: still remembered (echo stage rejects her own words).
        for _ in 0..<1500 { shadow.frame([], peakDb: 50, speechProbability: 0.1, muteReason: .reply) }
        shadow.frame([.speechStarted(sentToModel: false)], peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        for _ in 0..<50 { shadow.frame([], peakDb: 85, speechProbability: 0.9, muteReason: .reply) }
        shadow.partial("好玩的地方", utterance: 1)
        shadow.final("好玩的地方", utterance: 1)
        let r = UtteranceRecord(id: 1, startMs: 0, endMs: 0, endReason: .silence, sentToModel: false, muteReason: .reply,
                                peakDb: 85, noiseFloorDb: 40, classifierMax: 0.9)
        shadow.frame([.utterance(r)], peakDb: 40, speechProbability: nil, muteReason: .reply)
        #expect(shadow.takeLogs().last?.contains("reason=echoWords") == true)
        // Her playback ends; 10 s later the same words are new.
        shadow.herTurnEnd()
        for _ in 0..<1000 { shadow.frame([], peakDb: 50, speechProbability: 0.1, muteReason: .none) }
        shadow.frame([.speechStarted(sentToModel: false)], peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        for _ in 0..<50 { shadow.frame([], peakDb: 85, speechProbability: 0.9, muteReason: .reply) }
        shadow.final("好玩的地方", utterance: 2)
        shadow.frame([.utterance(r)], peakDb: 40, speechProbability: nil, muteReason: .reply)
        #expect(shadow.takeLogs().last?.contains("outcome=wouldStop") == true)
    }

    @Test("Row 18 / item 16: word-order echo rule on her text 「珠海有很多好玩的地方」")
    func wordOrder() {
        let text = "珠海有很多好玩的地方"
        for echo in [text, "朱海有很多好完的地方", "好玩", "对对", "嗯嗯", "珠海有"] {
            #expect(BargeInCheck.echoMeasure(echo, her: text).isEcho, "\(echo)")
        }
        for pass in ["珠海有多大", "珠海有什么好吃的", "珠海离澳门多远", "不是明天"] {
            #expect(!BargeInCheck.echoMeasure(pass, her: text).isEcho, "\(pass)")
        }
        let m = BargeInCheck.echoMeasure("珠海有多大", her: text)
        #expect(m.inRuns == 3 && m.total == 5)
        #expect(BargeInCheck.echoMeasure("珠海有什么好吃的", her: text).inRuns == 3)
    }

    @Test("Row 18: a question growing 珠海有 → 珠海有多大 is echo first, wouldStop once the last syllable arrives")
    func growingQuestion() {
        var shadow = BargeInShadow()
        shadow.herWords("珠海有很多好玩的地方")
        for _ in 0..<400 { shadow.frame([], peakDb: 50, speechProbability: 0.1, muteReason: .reply) }
        shadow.frame([.speechStarted(sentToModel: false)], peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        _ = shadow.takeEvents()
        for _ in 0..<40 { shadow.frame([.audio(.silence)], peakDb: 85, speechProbability: 0.9, muteReason: .reply) }
        for text in ["珠海", "珠海有", "珠海有多"] {
            shadow.partial(text, utterance: 1)
            shadow.frame([.audio(.silence)], peakDb: 85, speechProbability: 0.9, muteReason: .reply)
        }
        let before = shadow.takeEvents()
        #expect(!before.contains(.wouldStop(id: 1)))
        shadow.partial("珠海有多大", utterance: 1)
        let after = shadow.takeEvents()
        #expect(after.contains(.wouldStop(id: 1)))
    }
}

// MARK: - T-022e live flow

private func frame(_ v: Int16 = 1000) -> PCMFrame16k {
    PCMFrame16k(samples: [Int16](repeating: v, count: PCMFrame16k.samplesPerFrame))!
}

@Suite("T-022e F-08 §17 live interruption")
struct BargeInLiveTests {
    @Test("Row 7: setting on, full pass: dip, then restore, stop, speechStarted, buffer from onset, live; bargeInStop")
    func fullPass() {
        var live = BargeInLive()
        live.enabled = true
        let a = frame(1), b = frame(2), c = frame(3)
        // The gate's onset with its pre-roll; the candidate starts.
        var step = live.frame([.speechStarted(sentToModel: false), .audio(a), .audio(b)],
                              events: [.started(id: 1, candidate: true)], guidancePlaying: false)
        #expect(step.actions.isEmpty && step.outputs.isEmpty)
        step = live.frame([.audio(c)], events: [.early(id: 1)], guidancePlaying: false)
        #expect(step.actions == [.dip(true)] && step.outputs.isEmpty)
        step = live.pass([], events: [.wouldStop(id: 1)], guidancePlaying: false)
        #expect(step.actions == [.dip(false), .stop])
        #expect(step.outputs == [.speechStarted(sentToModel: true), .audio(a), .audio(b), .audio(c)])
        #expect(step.adopt)
        let stopLogs = live.takeLogs()
        #expect(stopLogs.first?.hasPrefix("bargeInStop 1 heldMs=") == true)
        // Live audio afterwards is the gate's own (adopted), not kept here.
        step = live.frame([.audio(a)], events: [], guidancePlaying: false)
        #expect(step.outputs.isEmpty && !live.keeping)
    }

    @Test("Row 7: the gate sends the rest of an adopted utterance and is not cut when her reply stops")
    func adopt() {
        var gate = SpeechUplinkGate(tuning: { var t = UplinkGateTuning(); t.speechConfirm = nil; return t }())
        for _ in 0..<160 { _ = gate.process(frame(0)) }
        gate.setPlaying(reply: true)
        var out: [UplinkGateOutput] = []
        for _ in 0..<30 { out += gate.process(frame(6000)) }
        #expect(out.contains(.speechStarted(sentToModel: false)))
        let adopted = gate.adoptOpenUtterance()
        #expect(adopted)
        gate.setPlaying(reply: false)
        out = []
        for _ in 0..<20 { out += gate.process(frame(6000)) }
        #expect(!out.contains { if case .speechStarted = $0 { true } else { false } })
        for _ in 0..<130 { out += gate.process(frame(0)) }
        let record = out.compactMap { if case .utterance(let r) = $0 { r } else { nil } }.first
        #expect(record?.sentToModel == true && record?.endReason == .silence)
    }

    @Test("Row 7: decided at the final after the close: start, buffer, then stopped and stream end")
    func afterClose() {
        var live = BargeInLive()
        live.enabled = true
        let a = frame(1)
        _ = live.frame([.speechStarted(sentToModel: false), .audio(a)], events: [.started(id: 1, candidate: true)],
                       guidancePlaying: false)
        let r = UtteranceRecord(id: 1, startMs: 0, endMs: 0, endReason: .silence, sentToModel: false, muteReason: .reply,
                                peakDb: 85, noiseFloorDb: 40, classifierMax: 0.9)
        _ = live.frame([.speechStopped(.normal), .utterance(r), .audio(.silence)], events: [], guidancePlaying: false)
        let step = live.pass([], events: [.wouldStop(id: 1)], guidancePlaying: false)
        #expect(step.outputs == [.speechStarted(sentToModel: true), .audio(a), .speechStopped(.normal), .streamEnd])
        #expect(!step.adopt)
    }

    @Test("Row 8: dip then no words: volume restored, nothing sent; setting off and guidance: no candidate")
    func cancelled() {
        var live = BargeInLive()
        live.enabled = true
        _ = live.frame([.speechStarted(sentToModel: false), .audio(frame())], events: [.started(id: 1, candidate: true)],
                       guidancePlaying: false)
        _ = live.frame([], events: [.early(id: 1)], guidancePlaying: false)
        let step = live.pass([], events: [.rejected(id: 1, reason: .noWords)], guidancePlaying: false)
        #expect(step.actions == [.dip(false)] && step.outputs.isEmpty && !step.adopt)
        let cancelLogs = live.takeLogs()
        #expect(cancelLogs == ["bargeInDipCancelled 1 reason=noWords"])

        var off = BargeInLive()
        _ = off.frame([.speechStarted(sentToModel: false)], events: [.started(id: 1, candidate: true)], guidancePlaying: false)
        #expect(!off.keeping)
        let offStep = off.pass([], events: [.early(id: 1), .wouldStop(id: 1)], guidancePlaying: false)
        #expect(offStep == BargeInLive.Step())

        var guidance = BargeInLive()
        guidance.enabled = true
        _ = guidance.frame([.speechStarted(sentToModel: false)], events: [.started(id: 1, candidate: true)],
                           guidancePlaying: true)
        #expect(!guidance.keeping)
    }

    @Test("Row 8: a new utterance or the 8 s cap drops what was kept")
    func supersededAndCap() {
        var live = BargeInLive()
        live.enabled = true
        _ = live.frame([.speechStarted(sentToModel: false)], events: [.started(id: 1, candidate: true)], guidancePlaying: false)
        _ = live.frame([], events: [.early(id: 1)], guidancePlaying: false)
        var step = live.frame([.speechStarted(sentToModel: true)], events: [.started(id: 2, candidate: false)],
                              guidancePlaying: false)
        #expect(step.actions == [.dip(false)] && !live.keeping)
        // A late wouldStop for the dropped one does nothing.
        let late = live.pass([], events: [.wouldStop(id: 1)], guidancePlaying: false)
        #expect(late == BargeInLive.Step())

        _ = live.frame([.speechStarted(sentToModel: false)], events: [.started(id: 3, candidate: true)], guidancePlaying: false)
        for _ in 0..<800 { step = live.frame([.audio(frame())], events: [], guidancePlaying: false) }
        #expect(live.keeping)
        step = live.frame([.audio(frame())], events: [], guidancePlaying: false)
        #expect(!live.keeping)
    }
}
