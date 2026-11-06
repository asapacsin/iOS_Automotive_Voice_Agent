import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it, so order and gaps show.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func record(_ id: Int) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: .silence, sentToModel: true, muteReason: .none, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
/// A scripted sent utterance: start, `frames` of audio, stop, record, stream end.
private func utterance(_ id: Int, frames: Int) -> [[UplinkGateOutput]] {
    var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true), .audio(f(1))]]
    for n in 2..<(frames + 1) { steps.append([.audio(f(n))]) }
    steps.append([.speechStopped(.normal), .utterance(record(id)), .streamEnd])
    return steps
}

@Suite("T-013h F-04b §14 item 8: show what the lock did")
struct SpeakerRejectionNoticeTests {
    @Test("F-04b row 42: a notice for rejected and unknown speech and a rejected wake word; none for accepted, stop phrases, lock off")
    func rejectionNotice() {
        func speechLine(frames: Int, score: Double?, locked: Bool = true) -> [SpeakerCheckLine] {
            var hold = SpeakerHold()
            if locked { _ = hold.setLock(threshold: 0.5) }
            var request: SpeakerScoreRequest?
            for step in utterance(1, frames: frames) {
                if let r = hold.frame(step).request { request = r }
                if let r = request, let score { _ = hold.result(.score(score, scoreMs: 5), utterance: r.utterance,
                                                                generation: r.generation); request = nil }
            }
            return hold.takeChecks()
        }
        func phrase(_ kind: SpeakerCheckKind, score: Double, locked: Bool = true) -> SpeakerCheckLine? {
            var check = SpeakerPhraseCheck(kind: kind)
            if locked { check.setLock(threshold: 0.5) }
            guard case .verify(let r) = check.hit(recent: (1...200).map(f)) else { return nil }
            return check.result(.score(score, scoreMs: 5), check: r.utterance, generation: r.generation, waitMs: 5)?.line
        }
        let rejected = speechLine(frames: 150, score: 0.2)
        #expect(rejected.map(\.result) == [.rejected])
        #expect(rejected.compactMap(SpeakerRejectionNotice.text) == ["没听出是录入的声音，这句没有发送"])
        let unknown = speechLine(frames: 30, score: nil)
        #expect(unknown.map(\.result) == [.unknown])
        #expect(unknown.compactMap(SpeakerRejectionNotice.text) == [SpeakerRejectionNotice.speech])
        #expect(speechLine(frames: 150, score: 0.9).compactMap(SpeakerRejectionNotice.text).isEmpty)
        #expect(phrase(.wake, score: 0.2).flatMap(SpeakerRejectionNotice.text) == "没听出是录入的声音，没有唤醒")
        #expect(phrase(.wake, score: 0.9).flatMap(SpeakerRejectionNotice.text) == nil)
        #expect(phrase(.stop, score: 0.2).map(\.result) == .rejected)
        #expect(phrase(.stop, score: 0.2).flatMap(SpeakerRejectionNotice.text) == nil)
        #expect(speechLine(frames: 150, score: 0.2, locked: false).isEmpty)  // lock off: no lines, no notice
        #expect(phrase(.wake, score: 0.2, locked: false) == nil)

        // 3 s, a new one restarts it (never stacks), the §6 item 11 chip wins.
        var board = SpeakerNoticeBoard()
        board.show(SpeakerRejectionNotice.speech, now: .zero)
        #expect(board.visible(now: .milliseconds(2_999), chipShowing: false) == SpeakerRejectionNotice.speech)
        #expect(board.visible(now: .seconds(3), chipShowing: false) == nil)
        board.show(SpeakerRejectionNotice.speech, now: .seconds(2))
        #expect(board.visible(now: .milliseconds(4_500), chipShowing: false) == SpeakerRejectionNotice.speech)
        #expect(board.visible(now: .milliseconds(4_500), chipShowing: true) == nil)
        #expect(board.visible(now: .seconds(5), chipShowing: false) == nil)
    }
}
