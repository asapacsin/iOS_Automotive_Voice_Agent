import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

/// Deterministic PCM: seeded noise and a tone. Stands in for the Android corpus until it arrives.
enum PCM {
    struct LCG { var state: UInt64; mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(Int64(bitPattern: state >> 11) % 2001) / 1000.0 - 1.0 } }

    /// Uniform noise with the given RMS (uniform on [-a, a] has RMS a/√3).
    static func noise(rms: Double, frames: Int, seed: UInt64 = 7) -> [PCMFrame16k] {
        var rng = LCG(state: seed)
        let amplitude = rms * 3.0.squareRoot()
        return (0..<frames).map { _ in
            PCMFrame16k(samples: (0..<160).map { _ in Int16(clamping: Int(rng.next() * amplitude)) })!
        }
    }

    static func tone(peak: Double, frames: Int) -> [PCMFrame16k] {
        (0..<frames).map { f in
            PCMFrame16k(samples: (0..<160).map { i in
                let t = Double(f * 160 + i) / 16_000
                return Int16((peak * sin(2 * .pi * 300 * t)).rounded())
            })!
        }
    }
}

private func sin(_ x: Double) -> Double {
    // Taylor series after range reduction: keeps NovaCore tests free of libm differences.
    var x = x.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    var term = x, sum = x
    for n in stride(from: 3, through: 21, by: 2) {
        term *= -x * x / Double((n - 1) * n)
        sum += term
    }
    return sum
}

@Suite("T-013 F-03 framing and gain")
struct FramingTests {
    @Test("F-03 frames are exactly 10 ms at 16 kHz whatever the chunk size")
    func framer() {
        var framer = AudioFramer10ms()
        var frames: [PCMFrame16k] = []
        var next: Int16 = 0
        for chunk in [1, 159, 37, 480, 7, 316] {
            frames += framer.append((0..<chunk).map { _ in defer { next &+= 1 }; return next })
        }
        #expect(frames.count == 1000 / 160)
        #expect(frames.allSatisfy { $0.samples.count == 160 && $0.samples.count * 2 == PCMFrame16k.byteCount })
        #expect(framer.bufferedSamples == 1000 % 160)
        // Order and continuity preserved.
        #expect(frames.flatMap(\.samples) == (0..<960).map { Int16($0) })
        #expect(PCMFrame16k.byteCount == 320 && PCMFrame16k.sampleRate / PCMFrame16k.samplesPerFrame == 100)
    }

    @Test("F-03 gain rises at most ×1.15 per frame, falls at once and never exceeds ×3")
    func gain() {
        var gain = MicInputGain()
        for frame in PCM.tone(peak: 2000, frames: 20) { _ = gain.process(frame) }
        #expect(abs(gain.gain - 3.0) < 1e-9)
        let loud = gain.process(PCM.tone(peak: 10_000, frames: 1)[0])
        #expect(abs(gain.gain - 1.2) < 1e-9)
        #expect(loud.samples.map { abs(Int($0)) }.max()! <= 12_000)
        var rising = MicInputGain()
        _ = rising.process(PCM.tone(peak: 4000, frames: 1)[0])
        #expect(abs(rising.gain - 1.15) < 1e-9)
    }

    @Test("F-03 gain ignores frames under the noise floor and hard-limits")
    func gainFloorAndLimit() {
        var gain = MicInputGain()
        _ = gain.process(PCM.tone(peak: 200, frames: 1)[0])
        #expect(gain.gain == 1.0)
        // At full gain a full-scale frame falls at once to the target peak; nothing wraps around.
        var g = MicInputGain()
        for frame in PCM.tone(peak: 2000, frames: 20) { _ = g.process(frame) }
        let clipped = PCMFrame16k(samples: [Int16.max, Int16.min] + Array(repeating: 0, count: 158))!
        let out = g.process(clipped)
        #expect(out.samples[0] > 0 && out.samples[1] < 0)
        #expect(out.samples.map { abs(Int($0)) }.max()! <= 12_000)
    }
}

@Suite("T-013 F-04 uplink gate")
struct UplinkGateTests {
    /// Warm-up (1500 ms) at a quiet bed so later frames are judged.
    func warmed(_ gate: inout SpeechUplinkGate, rms: Double = 60) {
        for frame in PCM.noise(rms: rms, frames: 150, seed: 1) { #expect(gate.process(frame).isEmpty) }
    }

    func run(_ gate: inout SpeechUplinkGate, _ frames: [PCMFrame16k]) -> [UplinkGateOutput] {
        frames.flatMap { gate.process($0) }
    }

    @Test("F-04 3 s of steady noise at the noise bed keeps the gate closed")
    func steadyNoise() {
        for bed in [60.0, 150, 400, 1200] {
            var gate = SpeechUplinkGate()
            let out = run(&gate, PCM.noise(rms: bed, frames: 150 + 300, seed: 3))
            #expect(out.isEmpty, "bed \(bed)")
            #expect(gate.phase == .closed)
        }
    }

    @Test("F-04 the gate cannot open during the 1500 ms warm-up")
    func warmUp() {
        var gate = SpeechUplinkGate()
        #expect(run(&gate, PCM.tone(peak: 8000, frames: 149)).isEmpty)
    }

    @Test("F-04 speech after silence: the first uploaded frames are 300 ms of pre-roll")
    func preRoll() {
        var gate = SpeechUplinkGate()
        warmed(&gate)
        let silence = PCM.noise(rms: 60, frames: 50, seed: 9)
        _ = run(&gate, silence)
        let speech = PCM.tone(peak: 6000, frames: 40)
        var out: [UplinkGateOutput] = []
        var opened = -1
        for (i, frame) in speech.enumerated() {
            let step = gate.process(frame)
            if step.first == .speechStarted(sentToModel: true) { opened = i }
            out += step
        }
        // Onset 200 ms = 20 voiced frames; the gate opens on the 20th.
        #expect(opened == 19)
        #expect(out.first == .speechStarted(sentToModel: true))
        let audio = out.dropFirst().prefix(30).compactMap { if case .audio(let f) = $0 { f } else { nil } }
        #expect(audio.count == 30)
        // 300 ms pre-roll = 10 frames of the silence before speech + the 20 onset frames.
        #expect(Array(audio) == Array(silence.suffix(10)) + Array(speech.prefix(20)))
    }

    @Test("F-04 speech end: audioStreamEnd after 1200 ms hangover and 1500 ms silence")
    func closing() {
        var gate = SpeechUplinkGate()
        warmed(&gate)
        _ = run(&gate, PCM.tone(peak: 6000, frames: 100))
        #expect(gate.phase == .open)
        let tail = PCM.noise(rms: 60, frames: 200, seed: 5)
        var outputs: [(Int, UplinkGateOutput)] = []
        for (i, frame) in tail.enumerated() { outputs += gate.process(frame).map { (i, $0) } }
        guard let stop = outputs.firstIndex(where: { if case .speechStopped = $0.1 { true } else { false } })
        else { Issue.record("never closed"); return }
        // Hangover: 120 unvoiced frames uploaded, closing on the 120th.
        #expect(outputs[stop].0 == 119)
        #expect(outputs[stop].1 == .speechStopped(.normal))
        // F-04 §14 item 7: the utterance's log record follows its end.
        guard case .utterance(let record) = outputs[stop + 1].1 else { Issue.record("no record"); return }
        #expect(record.endReason == .silence && record.sentToModel && record.muteReason == .none)
        let after = outputs[(stop + 2)...].map(\.1)
        #expect(after.count == 151)
        #expect(after.prefix(150).allSatisfy { $0 == .audio(.silence) })
        #expect(after.last == .streamEnd)
        #expect(outputs.prefix(stop).count == 120)
    }

    @Test("F-04 a short sparse segment is flagged, a slightly longer one held")
    func suspicious() {
        /// 20 onset frames, then `pattern` (true = voiced), then silence until the gate closes.
        func verdict(_ pattern: [Bool]) -> SegmentVerdict? {
            var gate = SpeechUplinkGate()
            warmed(&gate)
            var out = run(&gate, PCM.tone(peak: 6000, frames: 20))
            let quiet = PCM.noise(rms: 60, frames: 1, seed: 2)[0]
            let loud = PCM.tone(peak: 6000, frames: 1)[0]
            for voiced in pattern { out += gate.process(voiced ? loud : quiet) }
            out += run(&gate, PCM.noise(rms: 60, frames: 130, seed: 4))
            return out.compactMap { if case .speechStopped(let v) = $0 { v } else { nil } }.first
        }
        // 760 ms, 21 of 76 voiced (28%): flagged.
        #expect(verdict(Array(repeating: false, count: 55) + [true]) == .flagged)
        // 1000 ms, 47 of 100 voiced (47%): held.
        #expect(verdict((0..<80).map { $0 % 3 == 2 }) == .held)
        // 1000 ms all voiced: normal.
        #expect(verdict(Array(repeating: true, count: 80)) == .normal)
    }

    @Test("F-04 the arbiter can force the uplink closed")
    func forcedClosed() {
        var gate = SpeechUplinkGate()
        warmed(&gate)
        _ = run(&gate, PCM.tone(peak: 6000, frames: 30))
        let out = gate.setForcedClosed(true)
        #expect(out.first == .speechStopped(.normal) && out.last == .streamEnd)
        #expect(run(&gate, PCM.tone(peak: 6000, frames: 50)).isEmpty)
        _ = gate.setForcedClosed(false)
        #expect(run(&gate, PCM.tone(peak: 6000, frames: 1)).first == .speechStarted(sentToModel: true))
    }

    @Test("F-04 a steady noise rise after warm-up does not hold the gate open")
    func noiseRise() {
        var gate = SpeechUplinkGate()
        warmed(&gate, rms: 60)
        let out = run(&gate, PCM.noise(rms: 600, frames: 6000, seed: 13))
        let stops = out.filter { if case .speechStopped = $0 { true } else { false } }.count
        let starts = out.filter { $0 == .speechStarted(sentToModel: true) }.count
        #expect(gate.phase == .closed)
        #expect(starts == 1 && stops == 1)
        #expect(gate.noiseRMS > 500)
        // Speech above the new bed still opens it.
        #expect(run(&gate, PCM.tone(peak: 12_000, frames: 20)).first == .speechStarted(sentToModel: true))
    }

    @Test("F-04 speech with pauses is not mistaken for steady noise")
    func longSpeechKeepsGate() {
        var gate = SpeechUplinkGate()
        warmed(&gate)
        var out: [UplinkGateOutput] = []
        // 8 s of syllables: 250 ms voiced, 50 ms dip.
        for _ in 0..<27 {
            out += run(&gate, PCM.tone(peak: 6000, frames: 25))
            out += run(&gate, PCM.noise(rms: 60, frames: 5, seed: 17))
        }
        #expect(gate.phase == .open)
        #expect(!out.contains { if case .speechStopped = $0 { true } else { false } })
    }

    @Test("F-04 the noise bed adapts upwards while closed")
    func adapts() {
        var gate = SpeechUplinkGate()
        warmed(&gate, rms: 60)
        let before = gate.threshold
        _ = run(&gate, PCM.noise(rms: 110, frames: 500, seed: 11))
        #expect(gate.threshold > before)
        #expect(gate.phase == .closed)
    }
}

@Suite("T-004i F-04 §14 one send decision while she talks")
struct ListenWhileSheTalksTests {
    static func feed(_ gate: inout SpeechUplinkGate, _ frames: [PCMFrame16k]) -> [UplinkGateOutput] {
        frames.flatMap { gate.process($0) }
    }
    func warm() -> SpeechUplinkGate {
        var gate = SpeechUplinkGate()
        _ = Self.feed(&gate, PCM.noise(rms: 40, frames: 160))
        return gate
    }
    func starts(_ out: [UplinkGateOutput]) -> [Bool] {
        out.compactMap { if case .speechStarted(let sent) = $0 { sent } else { nil } }
    }
    func records(_ out: [UplinkGateOutput]) -> [UtteranceRecord] {
        out.compactMap { if case .utterance(let r) = $0 { r } else { nil } }
    }
    let quiet = PCM.noise(rms: 40, frames: 200, seed: 3)

    @Test("F-04 §14 row 1: an utterance inside her reply is not sent and is logged muteReason=reply")
    func insideReply() {
        var gate = warm()
        gate.setPlaying(reply: true)
        var out = Self.feed(&gate, PCM.tone(peak: 6000, frames: 60))
        out += Self.feed(&gate, quiet)
        #expect(starts(out) == [false])
        #expect(records(out).map(\.sentToModel) == [false])
        #expect(records(out).first?.muteReason == .reply)
        #expect(records(out).first?.endReason == .silence)
    }

    @Test("F-04 §14 row 2: speech that begins 300 ms before she stops is cut at unmute and sent from there")
    func cutAtUnmute() {
        var gate = warm()
        gate.setPlaying(reply: true)
        var out = Self.feed(&gate, PCM.tone(peak: 6000, frames: 30))  // 300 ms during her reply
        gate.setPlaying(reply: false)
        // 500 ms echo tail, then 1.5 s more of the driver's speech.
        out += Self.feed(&gate, PCM.tone(peak: 6000, frames: 200))
        out += Self.feed(&gate, quiet)
        #expect(starts(out) == [false, true])
        let r = records(out)
        #expect(r.map(\.endReason) == [.cutAtUnmute, .silence])
        #expect(r.map(\.sentToModel) == [false, true])
        #expect(r[0].muteReason == .reply)
        // The sent utterance starts with its pre-roll (30 frames) right after the cut.
        guard let cut = out.firstIndex(of: .speechStarted(sentToModel: true)) else { return }
        #expect(out[(cut + 1)...].prefix(31).allSatisfy { if case .audio = $0 { true } else { false } })
    }

    @Test("F-04 §14 row 3: after the echo tail an utterance is sent")
    func afterTail() {
        var gate = warm()
        gate.setPlaying(guidance: true)
        _ = Self.feed(&gate, quiet.prefix(10).map { $0 })
        gate.setPlaying(guidance: false)
        #expect(gate.muteReason == .echoTail)
        _ = Self.feed(&gate, quiet.prefix(50).map { $0 })
        #expect(gate.muteReason == .none)
        let out = Self.feed(&gate, PCM.tone(peak: 6000, frames: 30))
        #expect(starts(out) == [true])
    }

    @Test("F-04 §14 row 4: the first utterance of a session, nothing of hers played, is sent")
    func firstUtterance() {
        var gate = warm()
        #expect(gate.muteReason == .none)
        let out = Self.feed(&gate, PCM.tone(peak: 6000, frames: 30))
        #expect(starts(out) == [true])
    }

    @Test("F-04 §14 row 6/7: the log line carries numbers and enums only")
    func logLine() {
        var gate = warm()
        var out = Self.feed(&gate, PCM.tone(peak: 6000, frames: 40))
        out += Self.feed(&gate, quiet)
        guard let line = records(out).first?.logLine else { Issue.record("no record"); return }
        #expect(line.hasPrefix("utterance 1 start="))
        #expect(line.contains("endReason=silence sentToModel=true muteReason=none peakDb="))
    }
}

@Suite("T-022a F-08 §14 stop set and spotter window")
struct StopPhraseWindowTests {
    @Test("F-08 §14 row 1: every phrase is pinyin tokens (initials, tone-marked finals); one keyword line each")
    func tokens() {
        #expect(StopPhrases.all.map(\.text) == ["别说了", "不要说了", "别说啦", "停", "停一下", "闭嘴", "安静"])
        let finalLetters = Set("aeiouüāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜnrg")
        for phrase in StopPhrases.all {
            #expect(phrase.tokens.count >= phrase.text.count, "\(phrase.text)")
            for token in phrase.tokens where !StopPhrases.initials.contains(token) {
                #expect(token.allSatisfy(finalLetters.contains), "\(phrase.text) \(token)")
            }
        }
        let lines = StopPhrases.keywordsFile.split(separator: "\n")
        #expect(lines.count == 7 && lines[0] == "b ié sh uō l e @0")
        #expect(StopPhrases.index(of: "别说了") == 0 && StopPhrases.index(of: "别吵了") == nil)
        #expect(StopPhrases.index(of: "小诺别说了") == 0 && StopPhrases.index(of: "别说了吧") == 0)
        // Item 5: the transcript check knows the whole stop set.
        for phrase in StopPhrases.all { #expect(ListeningIntent.classify(phrase.text) == .shutUp, "\(phrase.text)") }
    }

    final class CountingSpotter: StopPhraseSpotter {
        var fed = 0, resets = 0
        func accept(_ frame: PCMFrame16k) -> StopPhraseHit? { fed += 1; return StopPhraseHit(phrase: 0, score: 90) }
        func reset() { resets += 1 }
    }

    @Test("F-08 §14 row 2: fed only during her reply and its 500 ms tail; never for guidance alone")
    func window() {
        var gate = SpeechUplinkGate()
        let spotter = CountingSpotter()
        var feeder = StopPhraseFeeder()
        let silence = PCMFrame16k(samples: [Int16](repeating: 0, count: PCMFrame16k.samplesPerFrame))!
        var muted = 0
        func run(_ n: Int) -> Int {
            var hits = 0
            for _ in 0..<n {
                _ = gate.process(silence)
                if gate.muteReason != .none { muted += 1 }
                if feeder.frame(silence, inWindow: gate.stopPhraseWindow, spotter: spotter) != nil { hits += 1 }
            }
            return hits
        }
        #expect(run(20) == 0 && spotter.fed == 0)
        gate.setPlaying(guidance: true)
        #expect(run(20) == 0)
        gate.setPlaying(guidance: false)
        #expect(run(40) == 0 && spotter.fed == 0)
        gate.setPlaying(reply: true)
        #expect(run(10) == 10)
        gate.setPlaying(reply: false)
        // The 500 ms echo tail: exactly the mute window of F-04 §14 item 2, then closed.
        muted = 0
        let tail = run(80)
        #expect(tail == muted && tail >= 49 && tail <= 50 && spotter.resets == 1)
    }
}

@Suite("T-022b F-08 §15 item 2 stop ends the echo-tail mute")
struct StopEchoTailTests {
    @Test("F-08 §15 item 2: after a flush, endEchoTail lifts the mute; it never lifts a playing reply's mute")
    func endTail() {
        var gate = SpeechUplinkGate()
        gate.setPlaying(reply: true)
        gate.endEchoTail()
        #expect(gate.muteReason == .reply)
        gate.setPlaying(reply: false)
        #expect(gate.muteReason == .echoTail)
        gate.endEchoTail()
        #expect(gate.muteReason == .none)
    }
}
