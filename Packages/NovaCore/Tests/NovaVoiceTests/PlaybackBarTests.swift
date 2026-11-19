import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func record(_ id: Int, sent: Bool, mute: MuteReason) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: .silence, sentToModel: sent, muteReason: mute, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
private func live(_ actions: [BargeInAction], _ outputs: [UplinkGateOutput] = [], adopt: Bool = false) -> BargeInLive.Step {
    var s = BargeInLive.Step()
    s.actions = actions
    s.outputs = outputs
    s.adopt = adopt
    return s
}

/// F-04b §18 (T-013m): while her reply plays or in its echo tail, the lock needs a score of at least
/// `playbackThreshold` (4.0) too, for the early stop and the whole-sentence verdict.
@Suite("T-013m F-04b §18 playback bar")
struct PlaybackBarTests {
    /// Record 20261118-133726: the cohort's whole-sentence threshold, also the early one (§17 amendment item 1).
    static let cohort = -0.092

    static func locked(playback: Bool, candidate: Bool) -> SpeakerHold {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: cohort, early: cohort)
        hold.scoreUnsent = true
        hold.earlyCandidate = candidate
        hold.playback = playback
        return hold
    }

    /// An utterance of `frames` audio frames (one per step), then its close.
    static func utterance(_ id: Int, frames: Int, sent: Bool, mute: MuteReason) -> [[UplinkGateOutput]] {
        var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: sent), .audio(f(1))]]
        if frames > 1 { for n in 2...frames { steps.append([.audio(f(n))]) } }
        steps.append([.speechStopped(.normal), .utterance(record(id, sent: sent, mute: mute)), .streamEnd])
        return steps
    }

    static func feed(_ hold: inout SpeakerHold, _ steps: [[UplinkGateOutput]])
        -> (early: [SpeakerScoreRequest], whole: [SpeakerScoreRequest]) {
        var early: [SpeakerScoreRequest] = [], whole: [SpeakerScoreRequest] = []
        for s in steps {
            let step = hold.frame(s)
            if let r = step.earlyRequest { early.append(r) }
            if let r = step.request { whole.append(r) }
        }
        return (early, whole)
    }

    @Test("T-013m F-04b §18 row 70: her reply playing, cohort -0.092, early 1.152: rejected at bar=playback threshold=4.0; no stop, dip undone")
    func row70() throws {
        var hold = Self.locked(playback: true, candidate: true)
        var actions = SpeakerActionHold()
        let steps = Self.utterance(1, frames: 250, sent: false, mute: .reply)
        let dip = actions.step(live([.dip(true)]), verdict: .pending, utterance: 1)
        #expect(dip.actions == [.dip(true)])
        _ = actions.step(live([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true),
                         verdict: .pending, utterance: 1)
        let (early, _) = Self.feed(&hold, Array(steps.prefix(120)))
        let r = try #require(early.first)
        let v = hold.result(.score(1.152, scoreMs: 20), utterance: r.utterance, generation: r.generation, kind: .early)
        #expect(v.early == .rejected && v.earlyUtterance == 1)
        let out = actions.early(v.early, utterance: v.earlyUtterance)
        #expect(out.actions == [.dip(false)] && !out.actions.contains(.stop))
        let line = try #require(hold.takeChecks().first)
        #expect(line.kind == .early && line.result == .rejected && line.bar == .playback && line.threshold == 4.0)
        #expect(line.logLine.contains("bar=playback threshold=4.0 result=rejected"))
    }

    @Test("T-013m F-04b §18 row 71: early 6.3 accepted, she stops; a whole score 2.2 of an utterance started in echoTail is not sent, mute=speaker, bar=playback")
    func row71() throws {
        // First: early 6.3 while she plays.
        var hold = Self.locked(playback: true, candidate: true)
        var actions = SpeakerActionHold()
        _ = actions.step(live([.dip(true)]), verdict: .pending, utterance: 1)
        _ = actions.step(live([.stop]), verdict: .pending, utterance: 1)
        let (early, _) = Self.feed(&hold, Array(Self.utterance(1, frames: 250, sent: false, mute: .reply).prefix(120)))
        let r = try #require(early.first)
        let v = hold.result(.score(6.3, scoreMs: 20), utterance: r.utterance, generation: r.generation, kind: .early)
        #expect(v.early == .accepted)
        #expect(actions.early(v.early, utterance: v.earlyUtterance).actions == [.stop])
        #expect(hold.takeChecks().first?.bar == .playback)

        // Second: a sent utterance that started in her echo tail, whole score 2.2 (above the cohort, under the bar).
        var tail = Self.locked(playback: true, candidate: false)
        var out: [UplinkGateOutput] = []
        var whole: [SpeakerScoreRequest] = []
        for s in Self.utterance(2, frames: 150, sent: true, mute: .none) {
            let step = tail.frame(s)
            out += step.outputs
            if let r = step.request { whole.append(r) }
        }
        #expect(out.isEmpty)
        let w = try #require(whole.first)
        let done = tail.result(.score(2.2, scoreMs: 30), utterance: w.utterance, generation: w.generation)
        #expect(done.decided == [.rejected])
        #expect(!done.outputs.contains { if case .audio = $0 { true } else { false } })
        let rec = done.outputs.compactMap { if case .utterance(let r) = $0 { r } else { nil } }.first
        #expect(rec?.sentToModel == false && rec?.muteReason == .speaker)
        let line = try #require(tail.takeChecks().first)
        #expect(line.kind == .speech && line.result == .rejected && line.bar == .playback && line.threshold == 4.0)
    }

    @Test("T-013m F-04b §18 row 71a: she is silent, score 0.6: accepted on the cohort threshold, bar=cohort")
    func row71a() throws {
        var hold = Self.locked(playback: false, candidate: false)
        var whole: [SpeakerScoreRequest] = []
        for s in Self.utterance(1, frames: 150, sent: true, mute: .none) {
            if let r = hold.frame(s).request { whole.append(r) }
        }
        let w = try #require(whole.first)
        let done = hold.result(.score(0.6, scoreMs: 30), utterance: w.utterance, generation: w.generation)
        #expect(done.decided == [.accepted])
        #expect(done.outputs.contains { if case .audio = $0 { true } else { false } })
        let line = try #require(hold.takeChecks().first)
        #expect(line.bar == .cohort && line.threshold == Self.cohort)
        #expect(line.logLine.contains("bar=cohort threshold=-0.092 result=accepted"))
    }

    @Test("T-013m F-04b §18 item 1: a cohort threshold above 4.0 decides (the higher of the two)")
    func higherCohortWins() throws {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 5.0, early: 5.0)
        hold.scoreUnsent = true
        hold.playback = true
        var whole: [SpeakerScoreRequest] = []
        for s in Self.utterance(1, frames: 150, sent: true, mute: .none) {
            if let r = hold.frame(s).request { whole.append(r) }
        }
        let w = try #require(whole.first)
        #expect(hold.result(.score(4.5, scoreMs: 1), utterance: w.utterance, generation: w.generation).decided == [.rejected])
        let line = try #require(hold.takeChecks().first)
        #expect(line.bar == .cohort && line.threshold == 5.0)
    }

    @Test("T-013m F-04b §18 item 5: lock off: nothing scored, outputs pass")
    func lockOff() {
        var hold = SpeakerHold()
        hold.playback = true
        hold.earlyCandidate = true
        let (early, whole) = Self.feed(&hold, Self.utterance(1, frames: 150, sent: true, mute: .none))
        #expect(early.isEmpty && whole.isEmpty && hold.takeChecks().isEmpty)
    }
}
