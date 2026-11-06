import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it, so order, gaps and duplicates show.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func record(_ id: Int, sent: Bool = true) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: .silence, sentToModel: sent, muteReason: .none, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
/// A scripted utterance as the gate cuts it: start, pre-roll and `frames` of audio, stop, stream end, record.
private func utterance(_ id: Int, frames: Int, from first: Int = 1, sent: Bool = true) -> [[UplinkGateOutput]] {
    var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: sent), .audio(f(first))]]
    for n in (first + 1)..<(first + frames) { steps.append([.audio(f(n))]) }
    steps.append([.speechStopped(.normal), .utterance(record(id, sent: sent)), .streamEnd])
    return steps
}
private func audioNumbers(_ outputs: [UplinkGateOutput]) -> [Int] {
    outputs.compactMap { if case .audio(let fr) = $0 { Int(fr.samples[0]) } else { nil } }
}

@Suite("T-013e F-04b speaker lock: SpeakerHold before upload")
struct SpeakerHoldTests {
    @Test("F-04b row 1: lock off, outputs equal the gate's and no score is requested")
    func lockOffPassesThrough() {
        var hold = SpeakerHold()
        for step in utterance(1, frames: 150) {
            let out = hold.frame(step)
            #expect(out.outputs == step)
            #expect(out.request == nil)
        }
        #expect(hold.takeChecks().isEmpty)
        #expect(hold.verdict == nil)
    }

    @Test("F-04b row 2: accepted at 1.0 s releases pre-roll and frames in order, no gap or duplicate")
    func acceptedReleasesInOrder() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var forwarded: [UplinkGateOutput] = []
        var request: SpeakerScoreRequest?
        let steps = utterance(1, frames: 150)
        for step in steps.prefix(100) {
            let s = hold.frame(step)
            forwarded += s.outputs
            if let r = s.request { request = r }
        }
        #expect(forwarded.isEmpty)
        let r = try! #require(request)
        #expect(r.frames.count == 100)
        #expect(r.kind == .speech)
        forwarded += hold.result(.score(0.8, scoreMs: 30), utterance: r.utterance, generation: r.generation).outputs
        for step in steps.dropFirst(100) { forwarded += hold.frame(step).outputs }
        #expect(forwarded.first == .speechStarted(sentToModel: true))
        #expect(audioNumbers(forwarded) == Array(1...150))
        #expect(Array(forwarded.suffix(2)) == [.utterance(record(1)), .streamEnd])
        let check = try! #require(hold.takeChecks().first)
        #expect(check.result == .accepted && check.speechMs == 1000 && check.scoreMs == 30)
        #expect(check.logLine.hasPrefix("speaker-check utterance=1 kind=speech score=0.8 threshold=0.5 result=accepted"))
    }

    /// Runs the utterance with a result after 1 s (or none) and returns everything forwarded.
    private func run(_ outcome: SpeakerScoreOutcome?, frames: Int = 150) -> ([UplinkGateOutput], SpeakerHold) {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var out: [UplinkGateOutput] = []
        for step in utterance(1, frames: frames) {
            let s = hold.frame(step)
            out += s.outputs
            if let r = s.request, let outcome { out += hold.result(outcome, utterance: r.utterance, generation: r.generation).outputs }
        }
        return (out, hold)
    }

    private func notSent(_ out: [UplinkGateOutput]) {
        #expect(audioNumbers(out).isEmpty)
        #expect(!out.contains(.speechStarted(sentToModel: true)))
        #expect(!out.contains(.streamEnd))
        #expect(out.first == .speechStarted(sentToModel: false))
        var r = record(1)
        r.sentToModel = false
        r.muteReason = .speaker
        #expect(out.last == .utterance(r))
        #expect(r.logLine.contains("muteReason=speaker"))
    }

    @Test("F-04b row 3: rejected, unknown, scoring failure and buffer past 3 s send nothing, muteReason=speaker")
    func rejectedUnknownFailureCap() {
        var (out, hold) = run(.score(0.2, scoreMs: 20))
        notSent(out)
        #expect(hold.takeChecks().map(\.result) == [.rejected])
        // Unknown: under minScoreSpeech (0.4 s of audio).
        (out, hold) = run(nil, frames: 40)
        notSent(out)
        #expect(hold.takeChecks().map(\.result) == [.unknown])
        #expect(hold.takeChecks().isEmpty)
        (out, hold) = run(.failed(scoreMs: 5))
        notSent(out)
        #expect(hold.unavailable)
        #expect(hold.takeChecks().first?.score == nil)
        // No result ever: unknown once past 3 s.
        (out, hold) = run(nil, frames: 400)
        notSent(out)
        #expect(hold.takeChecks().map(\.result) == [.unknown])
    }

    @Test("F-04b row 3: between minScoreSpeech and 1 s, scored at the end")
    func shortScoredAtEnd() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var request: SpeakerScoreRequest?
        var out: [UplinkGateOutput] = []
        for step in utterance(1, frames: 70) {
            let s = hold.frame(step)
            out += s.outputs
            if let r = s.request { request = r }
        }
        #expect(out.isEmpty)
        let r = try! #require(request)
        out = hold.result(.score(0.9, scoreMs: 10), utterance: r.utterance, generation: r.generation).outputs
        #expect(audioNumbers(out) == Array(1...70))
        #expect(Array(out.suffix(2)) == [.utterance(record(1)), .streamEnd])
    }

    @Test("F-04b row 4: a late result for an old utterance or old session is dropped")
    func staleResults() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var first: SpeakerScoreRequest?
        for step in utterance(1, frames: 120) { if let r = hold.frame(step).request { first = r } }
        // Utterance 1 closed waiting; utterance 2 starts and makes it unknown.
        var second: SpeakerScoreRequest?
        for step in utterance(2, frames: 120, from: 500) { if let r = hold.frame(step).request { second = r } }
        let old = try! #require(first)
        #expect(hold.result(.score(0.99, scoreMs: 1), utterance: old.utterance, generation: old.generation).outputs.isEmpty)
        // A new session: the second request is stale too.
        hold.reset()
        let s2 = try! #require(second)
        #expect(hold.result(.score(0.99, scoreMs: 1), utterance: s2.utterance, generation: s2.generation).outputs.isEmpty)
    }

    @Test("F-04b row 5: on to off releases a held utterance in order; off to on applies from the next one")
    func switching() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var out: [UplinkGateOutput] = []
        let steps = utterance(1, frames: 150)
        var request: SpeakerScoreRequest?
        for step in steps.prefix(50) { out += hold.frame(step).outputs }
        #expect(out.isEmpty)
        let off = hold.setLock(threshold: nil)
        out += off.outputs
        #expect(off.decided == [.accepted])
        for step in steps.dropFirst(50) {
            let s = hold.frame(step)
            out += s.outputs
            if let r = s.request { request = r }
        }
        #expect(request == nil)
        #expect(audioNumbers(out) == Array(1...150))
        // Off to on mid-utterance: the open one passes, the next one is held.
        var hold2 = SpeakerHold()
        var out2: [UplinkGateOutput] = []
        let a = utterance(1, frames: 50), b = utterance(2, frames: 50, from: 100)
        out2 += hold2.frame(a[0]).outputs
        _ = hold2.setLock(threshold: 0.5)
        for step in a.dropFirst() { out2 += hold2.frame(step).outputs }
        #expect(audioNumbers(out2) == Array(1...50))
        #expect(hold2.frame(b[0]).outputs.isEmpty)
        #expect(hold2.holding)
    }

    @Test("F-04b §6 item 9: not-sent utterances pass as they are and are scored only for an interruption")
    func unsentScoredForInterruption() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var requests = 0
        for step in utterance(1, frames: 120, sent: false) {
            let s = hold.frame(step)
            #expect(s.outputs == step)
            if s.request != nil { requests += 1 }
        }
        #expect(requests == 0)
        hold.scoreUnsent = true
        var request: SpeakerScoreRequest?
        for step in utterance(2, frames: 120, from: 300, sent: false).prefix(100) {
            let s = hold.frame(step)
            #expect(s.outputs == step)
            if let r = s.request { request = r }
        }
        #expect(hold.verdict == .pending)
        let r = try! #require(request)
        let res = hold.result(.score(0.1, scoreMs: 1), utterance: r.utterance, generation: r.generation)
        #expect(res.decided == [.rejected])
        #expect(hold.verdict == .rejected)
    }
}

@Suite("T-013e F-04b speaker lock: interruption, wake and stop phrases")
struct SpeakerActionTests {
    private func step(_ actions: [BargeInAction], _ outputs: [UplinkGateOutput] = [], adopt: Bool = false) -> BargeInLive.Step {
        var s = BargeInLive.Step()
        s.actions = actions
        s.outputs = outputs
        s.adopt = adopt
        return s
    }

    @Test("F-04b §6 item 9: no dip or stop before acceptance; accepted releases them in order")
    func interruptionWaitsForAcceptance() {
        var hold = SpeakerActionHold()
        #expect(hold.step(step([.dip(true)]), verdict: .pending) == BargeInLive.Step())
        #expect(hold.step(step([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true),
                          verdict: .pending) == BargeInLive.Step())
        let released = hold.decided([.accepted])
        #expect(released.actions == [.dip(true), .stop])
        #expect(released.adopt)
        #expect(audioNumbers(released.outputs) == [1])
        #expect(!hold.holding)
    }

    @Test("F-04b §6 item 9: rejected drops the actions and nothing it would send goes up")
    func interruptionRejected() {
        var hold = SpeakerActionHold()
        _ = hold.step(step([.dip(true)]), verdict: .pending)
        _ = hold.step(step([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true), verdict: .pending)
        let dropped = hold.decided([.rejected])
        #expect(dropped.actions.isEmpty && !dropped.adopt)
        #expect(dropped.outputs == [.speechStarted(sentToModel: false)])
        let later = hold.step(step([.stop], [.audio(f(2)), .streamEnd]), verdict: .rejected)
        #expect(later.actions.isEmpty && later.outputs.isEmpty)
        // Lock off: unchanged.
        let s = step([.dip(true)], [.audio(f(3))])
        #expect(hold.step(s, verdict: nil) == s)
    }

    @Test("F-04b row 9: wake and stop phrase with the verifier rejecting, then accepting")
    func phrases() {
        for kind in [SpeakerCheckKind.wake, .stop] {
            var check = SpeakerPhraseCheck(kind: kind)
            #expect(check.hit(recent: []) == .act)  // lock off: as today
            check.setLock(threshold: 0.5)
            var recent = RecentFrames()
            for n in 1...250 { recent.append(f(n)) }
            #expect(recent.frames.count == 200)
            #expect(audioNumbers(recent.frames.map { .audio($0) }) == Array(51...250))
            guard case .verify(let r) = check.hit(recent: recent.frames) else { Issue.record("no verify"); return }
            #expect(check.hit(recent: recent.frames) == .ignore)
            let noResult = check.result(.score(0.3, scoreMs: 9), check: r.utterance, generation: r.generation, waitMs: 9)
            let no = try! #require(noResult)
            #expect(!no.act)
            #expect(no.line.kind == kind && no.line.result == .rejected)
            guard case .verify(let r2) = check.hit(recent: recent.frames) else { Issue.record("no verify"); return }
            let yesResult = check.result(.score(0.7, scoreMs: 9), check: r2.utterance, generation: r2.generation, waitMs: 9)
            let yes = try! #require(yesResult)
            #expect(yes.act)
            // Failure is unknown, never accepted; a stale result is dropped.
            guard case .verify(let r3) = check.hit(recent: recent.frames) else { Issue.record("no verify"); return }
                let failed = check.result(.failed(scoreMs: 1), check: r3.utterance, generation: r3.generation, waitMs: 1)
            #expect(failed?.act == false)
            guard case .verify(let r4) = check.hit(recent: recent.frames) else { Issue.record("no verify"); return }
            check.setLock(threshold: 0.6)
            let stale = check.result(.score(0.9, scoreMs: 1), check: r4.utterance, generation: r4.generation, waitMs: 1)
            #expect(stale == nil)
        }
    }
}

private final class MemoryStore: SpeakerProfileStore, @unchecked Sendable {
    var profile: SpeakerProfile?
    func load() -> SpeakerProfile? { profile }
    func save(_ p: SpeakerProfile) throws { profile = p }
    func delete() throws { profile = nil }
}

@Suite("T-013e F-04b speaker lock: enrollment, profile, settings, calibration")
struct SpeakerProfileTests {
    static let model = (name: "campplus", dimension: 3)
    static func take(_ e: [Float], speech: Int64 = 3_000, clipped: Int = 0, noise: Int = 40) -> EnrollmentTake {
        EnrollmentTake(speech: .milliseconds(speech), clippedSamples: clipped, noiseDb: noise, embedding: e)
    }
    static let good = [take([1, 0.1, 0]), take([0.9, 0.2, 0]), take([1, 0, 0.1])]

    @Test("F-04b row 6: too short, clipped and disagreeing sentences are not saved, with the reason shown")
    func enrollmentChecks() {
        let store = MemoryStore()
        let now = Date(timeIntervalSince1970: 0)
        func enroll(_ t: [EnrollmentTake]) -> EnrollmentProblem? {
            if case .failure(let p) = SpeakerEnrollment.enroll(t, modelName: "campplus", dimension: 3, at: now, store: store) {
                return p
            }
            return nil
        }
        #expect(enroll(Self.good.map { var t = $0; t.speech = .seconds(2); return t }) == .tooShort)
        #expect(enroll([Self.good[0], Self.good[1], Self.take([1, 0, 0], clipped: 500)]) == .clipped)
        #expect(enroll([Self.good[0], Self.good[1], Self.take([1, 0, 0], noise: 70)]) == .noisy)
        #expect(enroll([Self.good[0], Self.good[1], Self.take([0, 1, 0])]) == .disagree)
        #expect(store.profile == nil)
        #expect(EnrollmentProblem.disagree.text.contains("重试"))
        #expect(enroll(Self.good) == nil)
        let p = try! #require(store.profile)
        #expect(p.threshold == nil)
        #expect(abs(p.embedding.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    }

    @Test("F-04b row 7: save and reload; failed re-enroll keeps the old one; delete; model change; wipe-all")
    func profileLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSpeakerProfileStore(url: dir.appendingPathComponent("SpeakerLock/profile.json"))
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = try SpeakerEnrollment.enroll(Self.good, modelName: "campplus", dimension: 3, at: at, store: store).get()
        profile.threshold = 0.42
        profile.calibrationClipMs = 1000  // §14 item 4: measured on the live clip
        try store.save(profile)
        #expect(FileSpeakerProfileStore(url: store.url).load() == profile)
        // A failing re-enrollment keeps the old file.
        _ = SpeakerEnrollment.enroll([Self.take([1, 0, 0])], modelName: "campplus", dimension: 3, at: at, store: store)
        #expect(store.load() == profile)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: store.load(), model: Self.model) == 0.42)
        // Model change: invalid and lock off.
        #expect(SpeakerLockPolicy.status(profile: profile, model: (name: "other", dimension: 3)) == .invalidModel)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: profile, model: (name: "campplus", dimension: 4)) == nil)
        // Delete (also what the wipe-all calls): removed and lock off.
        try SpeakerEnrollment.delete(store: store)
        #expect(store.load() == nil)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: store.load(), model: Self.model) == nil)
        try SpeakerEnrollment.delete(store: store)  // deleting twice is fine
    }

    @Test("F-04b row 8: switch on with no profile or no threshold opens enrollment or calibration")
    func switchOnNeedsCalibratedProfile() {
        let enrolled = SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3, enrolledAt: Date())
        var calibrated = enrolled
        calibrated.threshold = 0.5
        calibrated.calibrationClipMs = 1000  // §14 item 4: measured on the live clip
        #expect(SpeakerLockPolicy.requestOn(profile: nil, model: Self.model) == .openEnrollment)
        #expect(SpeakerLockPolicy.requestOn(profile: enrolled, model: Self.model) == .openCalibration)
        #expect(SpeakerLockPolicy.requestOn(profile: calibrated, model: Self.model) == .on(threshold: 0.5))
        #expect(SpeakerLockPolicy.requestOn(profile: calibrated, model: nil) == .modelUnavailable)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: enrolled, model: Self.model) == nil)
        #expect(SpeakerLockPolicy.threshold(switchOn: false, profile: calibrated, model: Self.model) == nil)
        #expect(SpeakerLockPolicy.status(profile: nil, model: Self.model).text == "未录入")
        #expect(SpeakerLockPolicy.status(profile: enrolled, model: Self.model).text == "已录入，未校准")
        #expect(SpeakerLockPolicy.status(profile: calibrated, model: Self.model).text == "已录入")
        #expect(SpeakerLockPolicy.status(profile: calibrated, model: nil).text == "声纹模型不可用")
    }

    @Test("F-04b §5: calibration suggests the lowest threshold with no false accepts and states the weak evidence")
    func calibration() {
        var c = SpeakerCalibration(driver: (0..<20).map { 0.5 + Double($0) * 0.02 },
                                   others: (0..<19).map { Double($0) * 0.02 })
        #expect(c.suggested == nil)  // 19 lines are not enough
        c.others.append(0.555)
        #expect(c.suggested.map { abs($0 - 0.56) < 1e-9 } == true)
        let row = c.row(at: 0.56)
        #expect(row.falseAccepts == 0 && row.falseRejects == 3)
        #expect(c.rows.first.map { $0.falseAccepts == 20 } == true)
        #expect(abs(SpeakerCalibration.upperBound(zeroOf: 20) - 0.139) < 0.001)
        #expect(c.caveat.contains("约 14%"))
        #expect(c.scoresFile.hasPrefix("clipMs=1000\ndriver 0.5 whole=none\n"))  // §14 item 3
        #expect(SpeakerCalibration.lines.count == 20)
        #expect(Set(SpeakerCalibration.lines).isDisjoint(with: SpeakerEnrollment.sentences))
    }
}

@Suite("T-013e F-04b speaker lock: the phone's words wait for the verdict")
struct SpeakerWordsTests {
    @Test("F-04b row 3: words of a rejected utterance never reach the screen or the core; accepted ones follow in order")
    func wordsWait() {
        var hold = SpeakerWordsHold()
        let w0 = hold.words(.partial("你好"), utterance: 1, heldUtterance: nil)  // lock off / not held
        #expect(w0)
        let w1 = hold.words(.partial("打开"), utterance: 2, heldUtterance: 2)
        #expect(!w1)
        let w1b = hold.words(.final("打开空调"), utterance: 2, heldUtterance: nil)  // still held once started
        #expect(!w1b)
        let released = hold.decided([.accepted], utterances: [2])
        #expect(released.map(\.words) == [.partial("打开"), .final("打开空调")])
        let w2 = hold.words(.partial("关窗"), utterance: 3, heldUtterance: 3)
        #expect(!w2)
        let none = hold.decided([.rejected], utterances: [3])
        #expect(none.isEmpty)
        let w3 = hold.words(.final("关窗"), utterance: 3, heldUtterance: nil)
        #expect(!w3)
        let w4 = hold.words(.final("好的"), utterance: 4, heldUtterance: nil)
        #expect(w4)
    }
}

@Suite("T-013e F-04b speaker lock: the gate's real closing order")
struct SpeakerRealOrderTests {
    @Test("F-04b row 3: stop, record, closing silence, stream end; speechMs counts only the utterance")
    func realOrder() {
        var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true), .audio(f(1))]]
        for n in 2...61 { steps.append([.audio(f(n))]) }
        steps.append([.speechStopped(.normal), .utterance(record(1))])
        for n in 62...211 { steps.append([.audio(f(n))]) }
        steps.append([.streamEnd])
        // Rejected: only the marks, as not sent.
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var out: [UplinkGateOutput] = []
        for s in steps {
            let st = hold.frame(s)
            out += st.outputs
            if let r = st.request { out += hold.result(.score(0.1, scoreMs: 1), utterance: r.utterance, generation: r.generation).outputs }
        }
        var r = record(1)
        r.sentToModel = false
        r.muteReason = .speaker
        #expect(out == [.speechStarted(sentToModel: false), .speechStopped(.normal), .utterance(r)])
        #expect(hold.takeChecks().first?.speechMs == 610)
        // Accepted: identical to the input.
        var hold2 = SpeakerHold()
        _ = hold2.setLock(threshold: 0.5)
        var out2: [UplinkGateOutput] = []
        for s in steps {
            let st = hold2.frame(s)
            out2 += st.outputs
            if let r = st.request { out2 += hold2.result(.score(0.9, scoreMs: 1), utterance: r.utterance, generation: r.generation).outputs }
        }
        #expect(out2 == steps.flatMap { $0 })
    }
}

@Suite("T-013e F-04b speaker lock: the closing burst in one batch")
struct SpeakerBatchTests {
    @Test("F-04b row 3: a rejection after the whole closing burst ends the utterance; her volume is always restored")
    func batchedBurst() {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var request: SpeakerScoreRequest?
        var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true), .audio(f(1))]]
        for n in 2...70 { steps.append([.audio(f(n))]) }
        steps.append([.speechStopped(.normal), .utterance(record(1))] + (71...220).map { .audio(f($0)) } + [.streamEnd])
        for s in steps { if let r = hold.frame(s).request { request = r } }
        let r = try! #require(request)
        _ = hold.result(.score(0.1, scoreMs: 1), utterance: r.utterance, generation: r.generation)
        #expect(hold.verdict == nil)
        var actions = SpeakerActionHold()
        var s = BargeInLive.Step()
        s.actions = [.dip(false), .stop]
        _ = actions.step(s, verdict: .pending)
        #expect(actions.decided([.rejected]).actions == [.dip(false)])
        #expect(actions.step(s, verdict: .rejected).actions == [.dip(false)])
    }
}
