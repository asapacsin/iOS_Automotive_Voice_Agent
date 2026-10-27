import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

/// F-04a with a scripted classifier: a result every 125 ms (12.5 frames), as SoundAnalysis delivers them.
@Suite("T-013a F-04a speech confirmation")
struct SpeechConfirmationTests {
    let speech = SpeechClassification(speechProbability: 0.9, topNonSpeech: nil)
    let horn = SpeechClassification(speechProbability: 0.05, topNonSpeech: "car_horn")

    /// Warm-up on quiet noise with the classifier saying `quiet` (it is attached and running).
    func warmGate(_ quiet: SpeechClassification) -> SpeechUplinkGate {
        var gate = SpeechUplinkGate()
        for (i, frame) in PCM.noise(rms: 60, frames: 200).enumerated() {
            if i % 12 == 0 { gate.classified(quiet) }
            _ = gate.process(frame)
        }
        return gate
    }

    /// Feeds `frames`, handing the gate `result` every 12 frames; returns all outputs and when speech began.
    func feed(_ gate: inout SpeechUplinkGate, _ frames: [PCMFrame16k],
              _ result: SpeechClassification) -> (outputs: [UplinkGateOutput], startedAt: Int?) {
        var outputs: [UplinkGateOutput] = []
        var startedAt: Int?
        for (i, frame) in frames.enumerated() {
            if i % 12 == 0 { gate.classified(result) }
            let out = gate.process(frame)
            if startedAt == nil, out.contains(.speechStarted) { startedAt = i }
            outputs += out
        }
        return (outputs, startedAt)
    }

    @Test("row 1: a loud non-speech sound never opens the uplink and is logged with its label")
    func hornRejected() {
        var gate = warmGate(horn)
        let (outputs, started) = feed(&gate, PCM.tone(peak: 4_000, frames: 150), horn)
        #expect(started == nil)
        #expect(!outputs.contains { if case .audio = $0 { true } else { false } })
        #expect(gate.lastRejection == "car_horn" && gate.rejections >= 1)
        #expect(!gate.hasRecentSpeech)
    }

    @Test("row 2: speech opens within the latency budget and keeps the 300 ms pre-roll before it")
    func speechOpens() {
        var gate = warmGate(horn)
        _ = feed(&gate, PCM.noise(rms: 60, frames: 40), horn)
        let (outputs, started) = feed(&gate, PCM.tone(peak: 4_000, frames: 100), speech)
        let startedAt = try? #require(started)
        // Onset 200 ms + confirmation (two speech results ≤ 250 ms): ≤ 45 frames after the first voiced one.
        #expect((startedAt ?? 999) <= 45)
        let audio = outputs.prefix { if case .speechStopped = $0 { false } else { true } }
            .filter { if case .audio = $0 { true } else { false } }
        // The first upload burst holds the pre-roll (30 frames) plus every frame since speech began.
        #expect(audio.count >= 30 + (startedAt ?? 0))
        #expect(gate.hasRecentSpeech)
    }

    @Test("row 3: a horn while she speaks is not a barge-in; the driver's voice is")
    func bargeIn() {
        var gate = warmGate(horn)
        _ = feed(&gate, PCM.tone(peak: 4_000, frames: 30), horn)
        #expect(!gate.hasRecentSpeech)
        _ = feed(&gate, PCM.tone(peak: 4_000, frames: 30), speech)
        #expect(gate.hasRecentSpeech)
    }

    @Test("row 5: a silent classifier (failed or late) falls back to F-04 after the wait, speech is kept")
    func classifierSilentFallsBack() {
        var gate = warmGate(horn)
        var started: Int?
        // No results for 1 s: the last ones go stale, so the onset opens at maxWait.
        for (i, frame) in PCM.tone(peak: 4_000, frames: 100).enumerated() where started == nil {
            if gate.process(frame).contains(.speechStarted) { started = i }
        }
        #expect(started != nil)
    }

    @Test("row 6: 抗噪 off, or no classifier attached, is F-04 exactly (opens at the 200 ms onset)")
    func offIsF04() {
        var off = warmGate(horn)
        off.suppressionEnabled = false
        let (_, offStarted) = feed(&off, PCM.tone(peak: 4_000, frames: 40), horn)
        var plain = SpeechUplinkGate()
        for frame in PCM.noise(rms: 60, frames: 200) { _ = plain.process(frame) }
        var plainStarted: Int?
        for (i, frame) in PCM.tone(peak: 4_000, frames: 40).enumerated() where plainStarted == nil {
            if plain.process(frame).contains(.speechStarted) { plainStarted = i }
        }
        #expect(offStarted == 19 && plainStarted == 19)
    }
}
