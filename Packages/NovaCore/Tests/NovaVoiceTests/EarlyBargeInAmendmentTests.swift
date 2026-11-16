import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func audio(_ outputs: [UplinkGateOutput]) -> [Int] {
    outputs.compactMap { if case .audio(let fr) = $0 { Int(fr.samples[0]) } else { nil } }
}
private func live(_ actions: [BargeInAction], _ outputs: [UplinkGateOutput] = [], adopt: Bool = false) -> BargeInLive.Step {
    var s = BargeInLive.Step()
    s.actions = actions
    s.outputs = outputs
    s.adopt = adopt
    return s
}

/// F-04b §17 amendment (T-013l): an early rejected or unknown verdict drops only the queued actions; the outputs and
/// adopt wait for the whole-sentence verdict.
@Suite("T-013l F-04b §17 amendment: early verdict decides only the stop")
struct EarlyBargeInAmendmentTests {
    @Test("T-013l F-04b §17 amendment item 2: early unknown, whole accepted: outputs and adopt go up, no stop; later steps keep their outputs")
    func unknownThenAccepted() {
        var actions = SpeakerActionHold()
        let dip = actions.step(live([.dip(true)]), verdict: .pending, utterance: 1)
        #expect(dip.actions == [.dip(true)])
        _ = actions.step(live([.stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true),
                         verdict: .pending, utterance: 1)
        let undo = actions.early(.unknown, utterance: 1)
        #expect(undo.actions == [.dip(false)] && undo.outputs.isEmpty && !undo.adopt)
        #expect(actions.holding)
        // A later live step: no dip or stop acts, its audio waits too.
        let later = actions.step(live([.dip(true), .stop], [.audio(f(2))]), verdict: .pending, utterance: 1)
        #expect(later.actions.isEmpty && later.outputs.isEmpty)
        let final = actions.decided([.accepted], utterances: [1])
        #expect(final.adopt && audio(final.outputs) == [1, 2] && !final.actions.contains(.stop))
        #expect(!final.outputs.contains(.speechStarted(sentToModel: false)))
        #expect(actions.takeLogs() == ["bargeInEarly 1 early=unknown stop=dropped"])
    }

    @Test("T-013l F-04b §17 amendment item 2: early rejected, whole rejected: the words are not sent")
    func rejectedThenRejected() {
        var actions = SpeakerActionHold()
        _ = actions.step(live([.dip(true), .stop], [.speechStarted(sentToModel: true), .audio(f(1))], adopt: true),
                         verdict: .pending, utterance: 1)
        _ = actions.early(.rejected, utterance: 1)
        let final = actions.decided([.rejected], utterances: [1])
        #expect(!final.adopt && audio(final.outputs).isEmpty && !final.actions.contains(.stop))
        #expect(final.outputs.contains(.speechStarted(sentToModel: false)))
    }

    @Test("T-013l F-04b §17 amendment item 1: no threshold1s: the early check is scored against the whole-sentence threshold")
    func fallbackThreshold() {
        let meta = SpeakerCohortMeta(source: "s", license: "l", model: "m", modelSha256: "x", speakers: 1, dimension: 1,
                                     topN: 1, threshold: .nan, eer: 0.1, trials: 1)
        #expect(meta.earlyThreshold == nil)
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5, early: 0.5)
        #expect(hold.earlyThreshold == 0.5)
    }
}
