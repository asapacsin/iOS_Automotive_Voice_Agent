import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func numbers(_ frames: [PCMFrame16k]) -> [Int] { frames.map { Int($0.samples[0]) } }
private func audio(_ outputs: [UplinkGateOutput]) -> [Int] {
    outputs.compactMap { if case .audio(let fr) = $0 { Int(fr.samples[0]) } else { nil } }
}
private func record(_ id: Int, end: UtteranceEnd = .silence) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: end, sentToModel: false, muteReason: .reply, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
private func live(_ actions: [BargeInAction], _ outputs: [UplinkGateOutput] = [], adopt: Bool = false) -> BargeInLive.Step {
    var s = BargeInLive.Step()
    s.actions = actions
    s.outputs = outputs
    s.adopt = adopt
    return s
}

/// F-04b §17 (T-013k): only the driver can interrupt her, decided on the first second of speech.
@Suite("T-013k F-04b §17 early speaker check for an interruption")
struct EarlyBargeInTests {
    /// A not-sent candidate while her reply plays: start with 30 pre-roll frames and frame 31 in one burst, then
    /// frames up to `frames`; `close` ends it (record, stop, stream end) in the last step.
    static func candidate(frames: Int, from first: Int = 1, id: Int = 1, end: UtteranceEnd = .silence)
        -> [[UplinkGateOutput]] {
        var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: false)] + (first...(first + 30)).map { .audio(f($0)) }]
        if frames > 31 { for n in (first + 31)..<(first + frames) { steps.append([.audio(f(n))]) } }
        steps.append([.speechStopped(.normal), .utterance(record(id, end: end)), .streamEnd])
        return steps
    }

    static func locked(early: Double? = 0.3) -> SpeakerHold {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5, early: early)
        hold.scoreUnsent = true
        hold.earlyCandidate = true
        return hold
    }

    /// Feeds the steps; returns the early and whole requests and every step's early verdicts.
    static func feed(_ hold: inout SpeakerHold, _ steps: [[UplinkGateOutput]], upTo: Int? = nil)
        -> (early: [SpeakerScoreRequest], whole: [SpeakerScoreRequest]) {
        var early: [SpeakerScoreRequest] = [], whole: [SpeakerScoreRequest] = []
        for s in steps.prefix(upTo ?? steps.count) {
            let step = hold.frame(s)
            if let r = step.earlyRequest { early.append(r) }
            if let r = step.request { whole.append(r) }
        }
        return (early, whole)
    }

    @Test("T-013k F-04b §17 row 62: dip at once; one early request on exactly the first 1.0 s of speech; the stop at the early verdict; words wait for the whole verdict")
    func row62() throws {
        var hold = Self.locked()
        var actions = SpeakerActionHold()
        let steps = Self.candidate(frames: 250)
        // 0.4 s in: BargeInLive dips her; it acts before any verdict (item 1).
        _ = Self.feed(&hold, steps, upTo: 10)
        let dip = actions.step(live([.dip(true)]), verdict: hold.verdict, utterance: hold.heldUtterance)
        #expect(dip.actions == [.dip(true)])
        // 0.8 s in: BargeInLive decides to stop; the stop and the adopted utterance wait.
        _ = Self.feed(&hold, Array(steps[10...]), upTo: 40)
        let stop = live([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true)
        let queued = actions.step(stop, verdict: hold.verdict, utterance: hold.heldUtterance)
        #expect(queued == BargeInLive.Step())
        // 1.0 s of speech after the 30 pre-roll frames: frame 130 makes the request.
        var early: [SpeakerScoreRequest] = []
        var whole: [SpeakerScoreRequest] = []
        for s in steps[50...] {
            let step = hold.frame(s)
            if let r = step.earlyRequest { early.append(r) }
            if let r = step.request { whole.append(r) }
            if !early.isEmpty, whole.isEmpty, early.count == 1, step.earlyRequest != nil {
                // Accepted at once.
                let verdict = hold.result(.score(0.9, scoreMs: 20, raw: 0.6, cohort: 800), utterance: early[0].utterance,
                                          generation: early[0].generation, kind: .early)
                #expect(verdict.early == .accepted && verdict.earlyUtterance == 1)
                let released = actions.early(verdict.early, utterance: verdict.earlyUtterance)
                #expect(released.actions == [.stop] && released.outputs.isEmpty && !released.adopt)
                #expect(actions.holding)  // the adopted utterance still waits
            }
        }
        #expect(early.count == 1 && early[0].kind == .early)
        #expect(numbers(early[0].frames) == Array(31...130))
        #expect(hold.verdict == .pending || hold.isHeld(1))
        let lines = hold.takeChecks()
        let line = try #require(lines.first)
        #expect(line.kind == .early && line.result == .accepted && line.speechMs == 1000)
        #expect(line.logLine.contains("kind=early score=0.9 raw=0.6 norm=0.9 cohort=800 bar=cohort threshold=0.3 result=accepted"))
        // The whole sentence decides the words.
        let w = try #require(whole.first)
        #expect(w.kind == .speech && w.frames.count == 250)
        let done = hold.result(.score(0.8, scoreMs: 30), utterance: w.utterance, generation: w.generation)
        #expect(done.decided == [.accepted])
        let after = actions.decided(done.decided)
        #expect(after.adopt && audio(after.outputs) == [1] && after.actions.isEmpty)
    }

    @Test("T-013k F-04b §17 row 63: early rejected: no stop, the dip undone; the whole verdict alone decides the words")
    func row63() throws {
        var hold = Self.locked()
        var actions = SpeakerActionHold()
        var words = SpeakerWordsHold()
        let steps = Self.candidate(frames: 250)
        _ = Self.feed(&hold, steps, upTo: 10)
        _ = actions.step(live([.dip(true)]), verdict: hold.verdict, utterance: hold.heldUtterance)
        let now = words.words(.partial("导航"), utterance: 1, heldUtterance: hold.isHeld(1) ? 1 : nil)
        #expect(!now)
        _ = actions.step(live([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true),
                         verdict: hold.verdict, utterance: hold.heldUtterance)
        let (early, _) = Self.feed(&hold, Array(steps[10...]), upTo: 130)
        let r = try #require(early.first)
        let verdict = hold.result(.score(0.1, scoreMs: 20), utterance: r.utterance, generation: r.generation, kind: .early)
        #expect(verdict.early == .rejected)
        let dropped = actions.early(verdict.early, utterance: verdict.earlyUtterance)
        #expect(dropped.actions == [.dip(false)] && !dropped.adopt && audio(dropped.outputs).isEmpty)
        // A later live step of this utterance stays dropped.
        let later = actions.step(live([.dip(true), .stop], [], adopt: true), verdict: hold.verdict, utterance: hold.heldUtterance)
        #expect(!later.actions.contains(.stop) && !later.actions.contains(.dip(true)) && !later.adopt)
        // Whole sentence accepted: the words go on; no stop ever.
        let (_, whole) = Self.feed(&hold, Array(steps[140...]))
        let w = try #require(whole.first)
        let done = hold.result(.score(0.8, scoreMs: 30), utterance: w.utterance, generation: w.generation)
        let released = words.decided(done.decided, utterances: done.decidedUtterances)
        #expect(released.map(\.words) == [.partial("导航")])
        let final = actions.decided(done.decided)
        #expect(!final.actions.contains(.stop))
        // T-013l: the words are not thrown away by the early rejection: the whole verdict sends them.
        #expect(final.adopt && audio(final.outputs) == [1])
        let kinds = hold.takeChecks().map(\.kind)
        #expect(kinds == [.early, .speech])
    }

    @Test("T-013k F-04b §17 row 64: early scoring fails, or the cohort has no threshold1s: unknown, no stop, dip undone")
    func row64() throws {
        // Failure.
        var hold = Self.locked()
        let (early, _) = Self.feed(&hold, Self.candidate(frames: 250), upTo: 101)
        let r = try #require(early.first)
        let v = hold.result(.failed(scoreMs: 5), utterance: r.utterance, generation: r.generation, kind: .early)
        #expect(v.early == .unknown && hold.early == .unknown)
        var actions = SpeakerActionHold()
        _ = actions.step(live([.stop]), verdict: .pending, utterance: 1)
        let undo = actions.early(v.early, utterance: v.earlyUtterance)
        #expect(undo.actions == [.dip(false)])
        let failLine = hold.takeChecks().first?.logLine ?? ""
        #expect(failLine.contains("kind=early score=none"))
        // No 1 s threshold: no request at all, unknown at 1.0 s; the record shows threshold none.
        var bare = Self.locked(early: nil)
        var sawUnknown = false
        for s in Self.candidate(frames: 250) {
            let step = bare.frame(s)
            #expect(step.earlyRequest == nil)
            if step.early == .unknown { sawUnknown = true }
        }
        #expect(sawUnknown)
        let bareLine = bare.takeChecks().first?.logLine ?? ""
        #expect(bareLine.contains("kind=early score=none raw=none norm=none cohort=none bar=cohort threshold=none result=unknown"))
        // A cohort without threshold1s gives none; a finite one is used.
        let meta = SpeakerCohortMeta(source: "s", license: "l", model: "m", modelSha256: "x", speakers: 1, dimension: 1,
                                     topN: 1, threshold: 1.5, eer: 0.1, trials: 1)
        // T-013l: no threshold1s: the measured whole-sentence threshold is used.
        #expect(meta.earlyThreshold == 1.5)
        let decoded = try JSONDecoder().decode(SpeakerCohortMeta.self, from: Data(
            #"{"source":"s","license":"l","model":"m","modelSha256":"x","speakers":1,"dimension":1,"topN":1,"threshold":1.5,"eer":0.1,"trials":1,"threshold1s":0.9,"eer1s":0.2,"trials1s":4}"#.utf8))
        #expect(decoded.earlyThreshold == 0.9 && decoded.eer1s == 0.2 && decoded.trials1s == 4)
    }

    @Test("T-013k F-04b §17 row 65: a 0.8 s candidate gets no early request; the stop follows the whole verdict")
    func row65() throws {
        var hold = Self.locked()
        var actions = SpeakerActionHold()
        let (early, whole) = Self.feed(&hold, Self.candidate(frames: 80))
        #expect(early.isEmpty)
        _ = actions.step(live([.stop]), verdict: .pending, utterance: 1)
        let w = try #require(whole.first)
        let done = hold.result(.score(0.9, scoreMs: 1), utterance: w.utterance, generation: w.generation)
        let acted = actions.decided(done.decided)
        #expect(acted.actions == [.stop])
    }

    @Test("T-013k F-04b §17 row 66: cut by cutAtUnmute while the next starts in the same frame: kept, its verdict is its own")
    func row66() throws {
        var hold = Self.locked()
        var steps = Self.candidate(frames: 230, end: .cutAtUnmute)
        // The cut's close and the next (sent) utterance's start in one frame.
        let close = steps.removeLast()
        steps.append(close.filter { $0 != .streamEnd } + [.speechStarted(sentToModel: true), .audio(f(900))])
        var whole: [SpeakerScoreRequest] = []
        var decided: [SpeakerHold.Verdict] = []
        for s in steps {
            let step = hold.frame(s)
            if let r = step.request { whole.append(r) }
            decided += step.decided
        }
        #expect(decided.isEmpty)  // not dropped as unknown
        #expect(hold.isHeld(1) && hold.heldUtterance == 2)
        let w = try #require(whole.first)
        #expect(w.utterance == 1)
        let done = hold.result(.score(0.9, scoreMs: 1), utterance: w.utterance, generation: w.generation)
        #expect(done.decided == [.accepted] && done.decidedUtterances == [1])
        #expect(hold.heldUtterance == 2 && hold.verdict == .pending && !hold.isHeld(1))
        // Steps queued under utterance 2 (the carry and a stop) wait for 2's own verdict, not 1's.
        var actions = SpeakerActionHold()
        let carry = live([.dip(false)], [.speechStarted(sentToModel: true), .audio(f(1)), .audio(f(900))], adopt: true)
        _ = actions.step(live([.stop]), verdict: .pending, utterance: 2)
        _ = actions.step(carry, verdict: .pending, utterance: 2)
        let first = actions.decided(done.decided, utterances: done.decidedUtterances)
        #expect(first.actions.isEmpty && !first.adopt && first.outputs.isEmpty && actions.holding)
        let second = actions.decided([.accepted], utterances: [2])
        #expect(second.actions == [.stop] && second.adopt && audio(second.outputs) == [1, 900])
    }

    @Test("T-013k F-04b §17 items 3-4 review: one utterance's early or whole rejection never drops another's queued stop")
    func perUtterance() {
        var actions = SpeakerActionHold()
        // B (2) is open with a stop queued while A (1) waits for its score.
        _ = actions.step(live([.stop], [.speechStarted(sentToModel: true), .audio(f(5))], adopt: true),
                         verdict: .pending, utterance: 2)
        let aRejected = actions.decided([.rejected], utterances: [1])
        #expect(!aRejected.actions.contains(.stop) && actions.holding)
        let aEarly = actions.early(.rejected, utterance: 1)
        #expect(!aEarly.actions.contains(.stop) && actions.holding)
        let bEarly = actions.early(.accepted, utterance: 2)
        #expect(bEarly.actions == [.stop])
        let bWhole = actions.decided([.accepted], utterances: [2])
        #expect(bWhole.adopt && audio(bWhole.outputs) == [5] && !actions.holding)
    }

    @Test("T-013k F-04b §17 item 4 review: a threshold change re-asks a kept utterance instead of leaving it held")
    func thresholdChangeRescores() throws {
        var hold = Self.locked()
        var steps = Self.candidate(frames: 230, end: .cutAtUnmute)
        let close = steps.removeLast()
        steps.append(close.filter { $0 != .streamEnd } + [.speechStarted(sentToModel: true), .audio(f(900))])
        var whole: [SpeakerScoreRequest] = []
        for s in steps { if let r = hold.frame(s).request { whole.append(r) } }
        let old = try #require(whole.first)
        let change = hold.setLock(threshold: 0.6, early: 0.3)
        let again = try #require(change.rescore.first)
        #expect(again.utterance == 1 && again.generation != old.generation && again.frames.count == 230)
        // The stale result does nothing; the new one decides it.
        #expect(hold.result(.score(0.9, scoreMs: 1), utterance: 1, generation: old.generation).decided.isEmpty)
        let done = hold.result(.score(0.9, scoreMs: 1), utterance: 1, generation: again.generation)
        #expect(done.decided == [.accepted] && !hold.isHeld(1))
        // Only the 1 s threshold changing keeps the generation.
        let g = hold.generation
        #expect(hold.setLock(threshold: 0.6, early: 0.4).rescore.isEmpty && hold.generation == g)
    }

    @Test("T-013k F-04b §17 row 67: lock off, or lock on with her silent: no early request; outputs as today")
    func row67() {
        var off = SpeakerHold()
        off.earlyCandidate = true
        for s in Self.candidate(frames: 250) {
            let step = off.frame(s)
            #expect(step.earlyRequest == nil && step.outputs == s)
        }
        // Lock on, she is silent: the utterance is sent, BargeInLive keeps nothing.
        var on = Self.locked()
        on.earlyCandidate = false
        var sent: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true)] + (1...31).map { .audio(f($0)) }]
        for n in 32...250 { sent.append([.audio(f(n))]) }
        for s in sent { let step = on.frame(s); #expect(step.earlyRequest == nil) }
        // Not a live candidate either: no early request.
        var quiet = Self.locked()
        quiet.earlyCandidate = false
        for s in Self.candidate(frames: 250) { let step = quiet.frame(s); #expect(step.earlyRequest == nil) }
    }
}
