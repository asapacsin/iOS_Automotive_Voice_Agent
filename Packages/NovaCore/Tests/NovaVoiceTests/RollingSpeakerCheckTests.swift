import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func level(_ rms: Int16) -> PCMFrame16k { PCMFrame16k(samples: Array(repeating: rms, count: 160))! }
private func audio(_ outputs: [UplinkGateOutput]) -> [Int] {
    outputs.compactMap { if case .audio(let fr) = $0 { Int(fr.samples[0]) } else { nil } }
}
private func record(_ id: Int, end: UtteranceEnd) -> UtteranceRecord {
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

/// F-04b §19 (T-013n): echo-aware VAD and the rolling voiceprint check while she speaks.
@Suite("T-013n F-04b §19 rolling speaker check")
struct RollingSpeakerCheckTests {
    static func warmGate(coupling: Double?) -> SpeechUplinkGate {
        var t = UplinkGateTuning()
        t.speechConfirm = nil
        t.echoCoupling = coupling
        var gate = SpeechUplinkGate(tuning: t)
        for _ in 0..<160 { _ = gate.process(level(50)) }
        return gate
    }

    static func opens(_ gate: inout SpeechUplinkGate, rms: Int16, playback: Double?, frames: Int = 40) -> Bool {
        var opened = false
        for _ in 0..<frames {
            if let playback { gate.playbackLevel(rms: playback) }
            if gate.process(level(rms)).contains(where: { if case .speechStarted = $0 { true } else { false } }) {
                opened = true
            }
        }
        return opened
    }

    @Test("T-013n F-04b §19 row 72a: echo below coupling × playback is not voiced; the driver over her is; her silent as today")
    func row72a() {
        var gate = Self.warmGate(coupling: 0.3)
        gate.setPlaying(reply: true)
        #expect(!Self.opens(&gate, rms: 2000, playback: 8000))
        #expect(gate.phase == .closed)
        #expect(Self.opens(&gate, rms: 3500, playback: 8000))
        gate.setPlaying(reply: false)
        for _ in 0..<300 { _ = gate.process(level(50)) }  // close, echo tail ends
        let lines = gate.takeEchoGateLines()
        #expect(lines.count == 1 && lines[0].hasPrefix("uplink echo-gate coupling=0.3 held_frames="))
        #expect(!lines[0].hasSuffix("held_frames=0"))
        var silent = Self.warmGate(coupling: 0.3)
        #expect(Self.opens(&silent, rms: 2000, playback: nil))
    }

    @Test("T-013n F-04b §19 row 72b: coupling = highest trial ratio × 2; none measured: 0.5 and coupling=default")
    func row72b() {
        let c = EchoCoupling.measured(ratios: [0.05, 0.1, 0.2, 0.15, 0.12, 0.08, 0.11, 0.19, 0.03, 0.07])
        #expect(c == 0.4)
        #expect(EchoCoupling.measured(ratios: []) == nil)
        var gate = Self.warmGate(coupling: c)
        #expect(gate.echoCoupling == 0.4)
        var d = Self.warmGate(coupling: nil)
        #expect(d.echoCoupling == 0.5)
        d.setPlaying(reply: true)
        _ = Self.opens(&d, rms: 300, playback: 1000)
        d.setPlaying(reply: false)
        for _ in 0..<100 { _ = d.process(level(50)) }
        #expect(d.takeEchoGateLines().first?.contains("coupling=default") == true)
        gate.setPlaying(reply: true)
        gate.playbackLevel(rms: 8000)
        #expect(gate.echoLevel == 3200)
    }

    static func locked() -> SpeakerHold {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5, early: 0.3)
        hold.scoreUnsent = true
        hold.earlyCandidate = true
        hold.playback = true
        return hold
    }

    /// A not-sent candidate while she plays: start with 30 pre-roll frames and frame 31, then one frame per step.
    static func start() -> [UplinkGateOutput] { [.speechStarted(sentToModel: false)] + (1...31).map { .audio(f($0)) } }

    @Test("T-013n F-04b §19 row 73: windows 1-2 rejected keep checking; window 3 accepted stops her and splits the utterance")
    func row73() throws {
        var hold = Self.locked()
        var actions = SpeakerActionHold()
        var requests: [SpeakerScoreRequest] = []
        var n = 31
        func step(_ o: [UplinkGateOutput]) { if let r = hold.frame(o).earlyRequest { requests.append(r) } }
        step(Self.start())
        _ = actions.step(live([.dip(true)]), verdict: hold.verdict, utterance: hold.heldUtterance)
        var verdicts: [SpeakerHold.Step] = []
        for score in [-1.4, -1.2] {
            while requests.count == verdicts.count { n += 1; step([.audio(f(n))]) }
            let r = requests.last!
            if verdicts.isEmpty {
                _ = actions.step(live([.stop], [.speechStarted(sentToModel: true)] + (1...n).map { .audio(f($0)) }, adopt: true),
                                 verdict: hold.verdict, utterance: hold.heldUtterance)
            }
            let v = hold.result(.score(score, scoreMs: 50), utterance: r.utterance, generation: r.generation, kind: .early)
            #expect(v.early == .rejected)
            let a = actions.early(v.early, utterance: v.earlyUtterance)
            #expect(a.actions == [.dip(false)])
            verdicts.append(v)
        }
        while requests.count == 2 { n += 1; step([.audio(f(n))]) }
        let r3 = requests[2]
        #expect(r3.frames.count == 100 && Int(r3.frames.last!.samples[0]) == n)
        let v3 = hold.result(.score(6.5, scoreMs: 50), utterance: r3.utterance, generation: r3.generation, kind: .early)
        #expect(v3.early == .accepted)
        let split = try #require(v3.split)
        // Window 3 starts at frame n-99 (index n-100); minus 30 pre-roll frames.
        #expect(split.dropFrames == n - 100 - 30)
        actions.dropAudio(split.dropFrames, utterance: 1)
        let a3 = actions.early(v3.early, utterance: v3.earlyUtterance)
        #expect(a3.actions.contains(.stop))
        let checks = hold.takeChecks()
        #expect(checks.map(\.window) == [1, 2, 3] && checks.allSatisfy { $0.kind == .early })
        #expect(checks[2].logLine.contains("kind=early window=3 "))
        #expect(hold.takeNotes() == ["speaker-split utterance=1 at_ms=\(split.dropFrames * 10) dropped_ms=\(split.dropFrames * 10)"])
        // Nothing before the split goes up when the whole verdict releases the queued audio.
        step([.speechStopped(.normal), .utterance(record(1, end: .silence)), .streamEnd])
        let done = actions.decided([.accepted], utterances: [1])
        #expect(done.adopt && audio(done.outputs).allSatisfy { $0 > split.dropFrames })
    }

    @Test("T-013n F-04b §19 row 77: window 2 accepted after window 1 rejected: the whole score is on frames after the split")
    func row77() throws {
        var hold = Self.locked()
        var early: [SpeakerScoreRequest] = [], whole: [SpeakerScoreRequest] = []
        var n = 31
        func step(_ o: [UplinkGateOutput]) {
            let s = hold.frame(o)
            if let r = s.earlyRequest { early.append(r) }
            if let r = s.request { whole.append(r) }
        }
        step(Self.start())
        while early.isEmpty { n += 1; step([.audio(f(n))]) }
        _ = hold.result(.score(-1.4, scoreMs: 1), utterance: 1, generation: early[0].generation, kind: .early)
        while early.count == 1 { n += 1; step([.audio(f(n))]) }
        let v = hold.result(.score(6.0, scoreMs: 1), utterance: 1, generation: early[1].generation, kind: .early)
        let cut = try #require(v.split).dropFrames
        for _ in 0..<50 { n += 1; step([.audio(f(n))]) }
        step([.speechStopped(.normal), .utterance(record(1, end: .silence)), .streamEnd])
        let w = try #require(whole.first)
        #expect(Int(w.frames.first!.samples[0]) == cut + 1 && w.frames.count == n - cut)
    }

    @Test("T-013n F-04b §19 row 74: all windows rejected to her reply end: cut, dropped as echo; the next utterance is on the cohort bar")
    func row74() throws {
        var hold = Self.locked()
        var early: [SpeakerScoreRequest] = [], whole: [SpeakerScoreRequest] = []
        var decided: [SpeakerHold.Verdict] = []
        var outs: [UplinkGateOutput] = []
        var n = 31
        func step(_ o: [UplinkGateOutput]) {
            let s = hold.frame(o)
            if let r = s.earlyRequest { early.append(r) }
            if let r = s.request { whole.append(r) }
            decided += s.decided
            outs += s.outputs
        }
        step(Self.start())
        for _ in 0..<3 {
            let k = early.count
            while early.count == k { n += 1; step([.audio(f(n))]) }
            _ = hold.result(.score(-1.0, scoreMs: 1), utterance: 1, generation: early.last!.generation, kind: .early)
        }
        // Her reply and echo tail end: the gate cuts and starts a new utterance in the same frame.
        hold.playback = false
        step([.speechStopped(.normal), .utterance(record(1, end: .cutAtUnmute)), .speechStarted(sentToModel: true),
              .audio(f(1000))])
        #expect(decided == [.rejected] && whole.isEmpty)
        let rec = outs.compactMap { if case .utterance(let r) = $0 { r } else { nil } }.first
        #expect(rec?.muteReason == .speaker && rec?.sentToModel == false)
        #expect(hold.takeNotes() == ["speaker-echo utterance=1 speechMs=\(n * 10) windows=3"])
        // The driver's 2 s after she stopped: a new utterance, whole-scored on the cohort bar and sent if accepted.
        for k in 0..<200 { step([.audio(f(1001 + k))]) }
        step([.speechStopped(.normal), .utterance(record(2, end: .silence)), .streamEnd])
        let w = try #require(whole.first)
        #expect(w.utterance == 2)
        let done = hold.result(.score(1.0, scoreMs: 1), utterance: 2, generation: w.generation)
        #expect(done.decided == [.accepted])
        #expect(hold.takeChecks().last?.bar == .cohort)
    }

    @Test("T-013n F-04b §19 row 75: a window due while one is in flight is skipped, not queued")
    func row75() {
        var hold = Self.locked()
        var early: [SpeakerScoreRequest] = []
        hold.frame(Self.start()).earlyRequest.map { early.append($0) }
        for n in 32...400 { if let r = hold.frame([.audio(f(n))]).earlyRequest { early.append(r) } }
        #expect(early.count == 1 && hold.skippedWindows >= 2)
        _ = hold.result(.score(-1, scoreMs: 1), utterance: 1, generation: early[0].generation, kind: .early)
        for n in 401...500 { if let r = hold.frame([.audio(f(n))]).earlyRequest { early.append(r) } }
        #expect(early.count == 2)
    }

    @Test("T-013n F-04b §19 row 76: lock off, or her silent after the first window: no rolling requests")
    func row76() {
        var off = SpeakerHold()
        off.earlyCandidate = true
        off.playback = true
        var any = off.frame(Self.start()).earlyRequest != nil
        for n in 32...400 { any = any || off.frame([.audio(f(n))]).earlyRequest != nil }
        #expect(!any)
        var hold = Self.locked()
        hold.playback = false
        var early: [SpeakerScoreRequest] = []
        hold.frame(Self.start()).earlyRequest.map { early.append($0) }
        for n in 32...400 {
            if let r = hold.frame([.audio(f(n))]).earlyRequest {
                early.append(r)
                _ = hold.result(.score(-1, scoreMs: 1), utterance: 1, generation: r.generation, kind: .early)
            }
        }
        #expect(early.count == 1)  // §17's single check, as today; no rolling once she is silent
    }

    @Test("T-013n F-04b §19 rows 73, 78 review: rolling goes on after BargeInLive lets the candidate go; an accepted window stops her with no words-check stop")
    func latchedCandidateAndVoiceStop() throws {
        var hold = Self.locked()
        var actions = SpeakerActionHold()
        var early: [SpeakerScoreRequest] = []
        var n = 31
        func step(_ o: [UplinkGateOutput]) { if let r = hold.frame(o).earlyRequest { early.append(r) } }
        step(Self.start())
        hold.earlyCandidate = false  // BargeInLive's cap or decision: no longer keeping
        for _ in 0..<2 {
            let k = early.count
            while early.count == k { n += 1; step([.audio(f(n))]) }
            if early.count < 2 {
                let v = hold.result(.score(-1.4, scoreMs: 1), utterance: 1, generation: early.last!.generation, kind: .early)
                _ = actions.early(v.early, utterance: v.earlyUtterance)
            }
        }
        #expect(early.count == 2)
        let v = hold.result(.score(6.5, scoreMs: 1), utterance: 1, generation: early[1].generation, kind: .early)
        let cut = try #require(v.split).dropFrames
        let accepted = try #require(v.voiceAccepted)
        #expect(Int(accepted.audio.first!.samples[0]) == cut + 1 && accepted.audio.count == n - cut)
        #expect(!actions.hasStop(1))
        // BargeInLive let candidate 1 go at its cap (8 s); only then may the voiceprint stop her with the hold's audio.
        var live = BargeInLive()
        live.enabled = true
        _ = live.frame([.speechStarted(sentToModel: false)], events: [.started(id: 1, candidate: true)], guidancePlaying: false)
        for _ in 0..<810 { _ = live.frame([], events: [], guidancePlaying: false) }
        #expect(!live.keeping)
        let maybe = live.voiceAccepted(1, audio: accepted.audio, gateOpen: true)
        let voice = try #require(maybe)
        #expect(voice.actions == [.stop] && voice.adopt)
        _ = actions.early(v.early, utterance: 1)
        let now = actions.step(voice, verdict: hold.verdict, utterance: 1)
        #expect(now.actions == [.stop] && now.outputs.isEmpty)  // she stops now; his audio waits for the whole verdict
        let done = actions.decided([.accepted], utterances: [1])
        #expect(done.adopt && audio(done.outputs).first == cut + 1)
        let none = live.voiceAccepted(1, audio: [], gateOpen: false)
        #expect(none == nil)
    }

    @Test("T-013n F-04b §19 row 76: lock on with her silent: no candidate, no early or rolling request")
    func row76Silent() {
        var hold = Self.locked()
        hold.earlyCandidate = false
        hold.playback = false
        var any = hold.frame(Self.start()).earlyRequest != nil
        for n in 32...400 { any = any || hold.frame([.audio(f(n))]).earlyRequest != nil }
        #expect(!any)
    }

    @Test("T-013n F-04b §19 row 74 review: an echo cut lets BargeInLive's candidate go")
    func echoReleasesLive() {
        var hold = Self.locked()
        var echo: Int?
        var n = 31
        var reqs: [SpeakerScoreRequest] = []
        hold.frame(Self.start()).earlyRequest.map { reqs.append($0) }
        while reqs.isEmpty { n += 1; hold.frame([.audio(f(n))]).earlyRequest.map { reqs.append($0) } }
        _ = hold.result(.score(-1, scoreMs: 1), utterance: 1, generation: reqs[0].generation, kind: .early)
        echo = hold.frame([.speechStopped(.normal), .utterance(record(1, end: .cutAtUnmute))]).echo
        #expect(echo == 1)
        var live = BargeInLive()
        _ = live.echoDropped(1)
        #expect(!live.keeping)
    }

    @Test("T-013n F-04b §19 re-check: after a stop phrase or with 可以打断她 off, an accepted window releases nothing")
    func noVoiceStopAfterStopPhraseOrOff() {
        for stopPhrase in [true, false] {
            var live = BargeInLive()
            live.enabled = true
            _ = live.frame([.speechStarted(sentToModel: false)], events: [.started(id: 1, candidate: true)], guidancePlaying: false)
            if stopPhrase { _ = live.stopPhrase() } else { _ = live.setEnabled(false) }
            let none = live.voiceAccepted(1, audio: [f(1)], gateOpen: true)
            #expect(none == nil)
        }
    }
}
