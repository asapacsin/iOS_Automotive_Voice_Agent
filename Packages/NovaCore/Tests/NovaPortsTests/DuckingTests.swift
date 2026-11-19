import Testing
import NovaKit
@testable import NovaPorts

private func at(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }

/// Runs a ramp to its end and returns the media node gain after each 25 ms step.
private func gains(_ ramp: inout DuckRamp, media: Double) -> [Double] {
    var out: [Double] = []
    while let factor = ramp.tick() { out.append(DuckRamp.gain(media: media, factor: factor)) }
    return out
}

@Suite("T-032h F-13a §5 the song ducks under her voice (pure)")
struct DuckingTests {
    @Test("F-13a row 6: media at 8; her reply starts, then finishes: 0.8 → 0.24 → 0.8, duck on and off lines")
    func replyDucks() {
        let media = VolumeLevels(media: 8).mediaGain
        var machine = DuckMachine()
        var ramp = DuckRamp()
        let epoch = Epoch(3)
        #expect(machine.handle(.replyBegan, at: at(1_000)) == nil)
        let on = machine.handle(.replyAudio(epoch), at: at(1_300))
        #expect(on == DuckMachine.Change(ducked: true, line: "duck on ms=300"))
        ramp.target(ducked: true)
        let down = gains(&ramp, media: media)
        #expect(down.count == DuckRamp.downMs / DuckRamp.stepMs)
        #expect(abs(down.last! - 0.24) < 1e-9 && zip(down, down.dropFirst()).allSatisfy { $0 > $1 })
        // Between clauses `replyFinished` sends nothing here; the next clause's buffer changes nothing.
        #expect(machine.handle(.replyAudio(epoch), at: at(2_000)) == nil)
        let off = machine.handle(.replyIdle(epoch), at: at(4_000))
        #expect(off == DuckMachine.Change(ducked: false, line: "duck off ms=3000"))
        ramp.target(ducked: false)
        let up = gains(&ramp, media: media)
        #expect(up.count == DuckRamp.upMs / DuckRamp.stepMs)
        #expect(up.last == 0.8 && zip(up, up.dropFirst()).allSatisfy { $0 < $1 })
        #expect(!ramp.running && ramp.tick() == nil)
    }

    @Test("F-13a row 7: media level 0 during a reply stays 0 at every step")
    func zeroStaysZero() {
        var ramp = DuckRamp()
        ramp.target(ducked: true)
        let down = gains(&ramp, media: VolumeLevels(media: 0).mediaGain)
        ramp.target(ducked: false)
        let up = gains(&ramp, media: 0)
        #expect(!down.isEmpty && !up.isEmpty && (down + up).allSatisfy { $0 == 0 })
    }

    @Test("F-13a §5 item 3: 25 ms steps, 150 ms down and 400 ms up; a turn back mid-ramp starts from where it is")
    func schedule() {
        var ramp = DuckRamp()
        ramp.target(ducked: true)
        #expect(ramp.tick() == 1 + (DuckRamp.factor - 1) / 6)
        _ = ramp.tick()
        let mid = ramp.current
        ramp.target(ducked: false)
        var steps: [Double] = []
        while let f = ramp.tick() { steps.append(f) }
        #expect(steps.count == 16 && steps.first! > mid && steps.last == 1)
        // Already there: nothing to run.
        ramp.target(ducked: false)
        #expect(!ramp.running)
        // The duck is relative: level 5 ducks to 0.15.
        #expect(abs(DuckRamp.gain(media: VolumeLevels(media: 5).mediaGain, factor: DuckRamp.factor) - 0.15) < 1e-9)
    }

    @Test("F-13a §5 items 1, 5: guidance ducks too; the duck lasts while either sounds; a flush ends it; stale ends ignored")
    func causes() {
        var machine = DuckMachine()
        let g = GuidanceID(7)
        #expect(machine.handle(.guidanceStarted(g), at: at(5_000)) == DuckMachine.Change(ducked: true, line: "duck on ms=0"))
        #expect(machine.handle(.replyAudio(Epoch(1)), at: at(5_500)) == nil)
        #expect(machine.handle(.guidanceEnded(g), at: at(6_000)) == nil)  // her reply still sounds
        #expect(machine.handle(.replyIdle(Epoch(0)), at: at(6_100)) == nil)  // an older reply's end
        #expect(machine.handle(.flushed, at: at(7_000)) == DuckMachine.Change(ducked: false, line: "duck off ms=2000"))
        #expect(!machine.ducked)
        #expect(machine.handle(.guidanceEnded(g), at: at(7_100)) == nil)
        // A guidance sentence on its own: on, then off when it ends.
        #expect(machine.handle(.guidanceStarted(GuidanceID(8)), at: at(8_000))?.ducked == true)
        #expect(machine.handle(.guidanceEnded(GuidanceID(8)), at: at(9_500)) == DuckMachine.Change(ducked: false, line: "duck off ms=1500"))
        // A reply with no ResponseStarted seen is timed from its first buffer.
        #expect(machine.handle(.replyAudio(Epoch(2)), at: at(10_000))?.line == "duck on ms=0")
    }
}
