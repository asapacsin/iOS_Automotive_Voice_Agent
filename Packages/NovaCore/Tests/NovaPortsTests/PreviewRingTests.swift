import Foundation
import Testing
@testable import NovaPorts

/// Interleaved frames whose left sample is `base + i` and right `-(base + i)`.
private func frames(_ count: Int, from base: Int = 0, scale: Float = 1) -> [Float] {
    (0..<count).flatMap { i -> [Float] in let v = Float(base + i + 1) * scale; return [v, -v] }
}

@Suite("T-032f F-13 §18 preview buffer and media lane (pure)")
struct PreviewRingTests {
    @Test("T-032f row 15: PreviewRing gives frames in order, zeros after, drained once only after finish and the last frame")
    func order() {
        let ring = PreviewRing(seconds: 2, sampleRate: 1_000)
        ring.reset(generation: 1)
        ring.activate(generation: 1)
        #expect(ring.write(generation: 1, interleaved: frames(1_500)) == .written)
        var got: [Float] = []
        var drainedCount = 0
        for _ in 0..<3 {  // 1,536 frames asked, 1,500 there
            let (samples, result) = ring.read(frames: 512)
            got += samples
            if result.drainedNow { drainedCount += 1 }
        }
        #expect(Array(got.prefix(3_000)) == frames(1_500))
        #expect(got.suffix(72).allSatisfy { $0 == 0 })
        #expect(drainedCount == 0 && !ring.isDrained(generation: 1))  // the download still runs: a stall
        ring.finish(generation: 1)
        let (zeros, last) = ring.read(frames: 512)
        #expect(zeros.allSatisfy { $0 == 0 } && last.frames == 0 && last.drainedNow && ring.isDrained(generation: 1))
        #expect(!ring.read(frames: 512).result.drainedNow)  // once

        // Finished with frames left: drained only with the read that takes the last frame.
        ring.reset(generation: 2)
        ring.activate(generation: 2)
        _ = ring.write(generation: 2, interleaved: frames(600))
        ring.finish(generation: 2)
        #expect(!ring.read(frames: 512).result.drainedNow && !ring.isDrained(generation: 2))
        let tail = ring.read(frames: 512).result
        #expect(tail.frames == 88 && tail.drainedNow && ring.isDrained(generation: 2))
        // A write after finish is ignored.
        #expect(ring.write(generation: 2, interleaved: frames(10)) == .stale)
    }

    @Test("T-032f row 15: nothing is read while the preview is not active")
    func inactive() {
        let ring = PreviewRing(seconds: 1, sampleRate: 1_000)
        ring.reset(generation: 1)
        _ = ring.write(generation: 1, interleaved: frames(100))
        #expect(ring.read(frames: 50).result.frames == 0)
        ring.activate(generation: 1)
        #expect(ring.read(frames: 50).samples == frames(50))
        ring.deactivate()
        #expect(ring.read(frames: 50).samples.allSatisfy { $0 == 0 })
    }

    @Test("T-032f row 16: after a reset, the old generation's writes are ignored and the new one plays")
    func reset() {
        let ring = PreviewRing(seconds: 2, sampleRate: 1_000)
        ring.reset(generation: 1)
        ring.activate(generation: 1)
        _ = ring.write(generation: 1, interleaved: frames(500))
        _ = ring.read(frames: 100)
        ring.reset(generation: 2)
        #expect(ring.write(generation: 1, interleaved: frames(500, scale: 7)) == .stale)
        ring.finish(generation: 1)
        #expect(ring.read(frames: 100).samples.allSatisfy { $0 == 0 })
        ring.activate(generation: 2)
        #expect(ring.read(frames: 100).samples.allSatisfy { $0 == 0 })
        #expect(ring.write(generation: 2, interleaved: frames(200, from: 1_000)) == .written)
        #expect(ring.write(generation: 1, interleaved: frames(200, scale: 7)) == .stale)
        let (samples, result) = ring.read(frames: 300)
        #expect(Array(samples.prefix(400)) == frames(200, from: 1_000) && result.frames == 200)
        #expect(!ring.isDrained(generation: 2))
    }

    @Test("T-032f row 17: 41 s written keeps 40 s; the overflow is reported once")
    func overflow() {
        let ring = PreviewRing(seconds: 40, sampleRate: 1_000)
        ring.reset(generation: 1)
        var results: [PreviewRing.WriteResult] = []
        for second in 0..<41 { results.append(ring.write(generation: 1, interleaved: frames(1_000, from: second * 1_000))) }
        #expect(results.prefix(40).allSatisfy { $0 == .written })
        #expect(results[40] == .overflow)
        #expect(ring.write(generation: 1, interleaved: frames(10)) == .full)
        #expect(ring.writtenFrames == 40_000)
        ring.activate(generation: 1)
        let (samples, _) = ring.read(frames: 40_001)
        #expect(Array(samples.prefix(80_000)) == frames(40_000) && samples.suffix(2) == [0, 0])
        // A new generation reports its own overflow again.
        ring.reset(generation: 2)
        #expect(ring.write(generation: 2, interleaved: frames(40_001)) == .overflow)
    }

    @Test("T-032f row 18: one writer and one reader thread, 10,000 rounds with resets: only current or zero frames")
    func threads() {
        let ring = PreviewRing(seconds: 2, sampleRate: 1_000)
        ring.reset(generation: 1)
        ring.activate(generation: 1)
        let rounds = 10_000
        let current = AtomicBox(1)  // the generation the writer last reset to (set after the reset)
        let bad = AtomicBox()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            var rng = SystemRandomNumberGenerator()
            var generation = 1
            for _ in 0..<rounds {
                if Int.random(in: 0..<50, using: &rng) == 0 {
                    // A writer of the old generation keeps writing after the reset.
                    _ = ring.write(generation: generation, interleaved: [Float](repeating: Float(generation), count: 64))
                    generation += 1
                    ring.reset(generation: generation)
                    ring.activate(generation: generation)
                    current.set(generation)
                    _ = ring.write(generation: generation - 1, interleaved: [Float](repeating: Float(generation - 1), count: 64))
                }
                let n = Int.random(in: 1...64, using: &rng)
                if ring.write(generation: generation, interleaved: [Float](repeating: Float(generation), count: 2 * n)) != .written {
                    // Full: start over in a new generation.
                    generation += 1
                    ring.reset(generation: generation)
                    ring.activate(generation: generation)
                    current.set(generation)
                }
            }
        }
        DispatchQueue.global().async(group: group) {
            var rng = SystemRandomNumberGenerator()
            var l = [Float](repeating: 0, count: 512), r = l
            for _ in 0..<rounds {
                let n = Int.random(in: 1...512, using: &rng)
                let before = current.get()
                let result = l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in ring.read(left: lp.baseAddress!, right: rp.baseAddress!, frames: n) }
                }
                let after = current.get()
                for i in 0..<n {
                    let v = l[i]
                    // Each frame is zero, or from a generation that was current during this read.
                    if v != 0, (v != r[i]) || Int(v) < before || Int(v) > after { bad.set(1) }
                }
                if result.frames > n { bad.set(1) }
            }
        }
        #expect(group.wait(timeout: .now() + 60) == .success)
        #expect(bad.get() == 0)
    }

    @Test("T-032f row 19: MediaLaneMachine: begin over a playing preview, stop while loading, bundled over a preview")
    func lane() {
        var m = MediaLaneMachine()
        let (first, e0) = m.begin()
        #expect(first == 1 && e0 == [.resetBuffer(generation: 1)])
        #expect(m.start(first) == [.activate(generation: 1), .mediaPlaying(true), .startTimer])
        // A new preview while one plays: false, then loading.
        let (second, e1) = m.begin()
        #expect(e1 == [.deactivate, .resetBuffer(generation: 2), .cancelTimer, .mediaPlaying(false), .resetBuffer(generation: 3)])
        #expect(second == 3 && m.state == .previewLoading(generation: 3))
        #expect(m.start(first).isEmpty)
        // Stop while loading: no event, and the late start gives no mediaPlaying(true).
        #expect(m.stop() == [.deactivate, .resetBuffer(generation: 4), .cancelTimer])
        #expect(m.start(second).isEmpty && m.state == .idle)
        // Bundled while a preview plays: the preview stops, then the bundled node plays.
        let (third, _) = m.begin()
        _ = m.start(third)
        #expect(m.playBundled() == [.deactivate, .resetBuffer(generation: 6), .cancelTimer, .mediaPlaying(false), .playBundledNode])
        #expect(m.bundledStarted(playing: true) == [.mediaPlaying(true)] && m.state == .bundled)
        #expect(m.playBundled() == [.mediaPlaying(false), .mediaPlaying(true)])
        #expect(m.restart() == [.replayBundledNode])
        #expect(m.stop() == [.stopBundledNode, .mediaPlaying(false)])
        #expect(m.stop().isEmpty)
    }

    @Test("T-032f row 19: drained while downloading is nothing; after finish it ends once; restart keeps playing")
    func drained() {
        var m = MediaLaneMachine()
        let (token, _) = m.begin()
        _ = m.start(token)
        #expect(m.drained(token).isEmpty && m.previewPlaying)
        #expect(m.restart().isEmpty && m.previewPlaying)
        m.finish(token)
        #expect(m.drained(token) == [.deactivate, .resetBuffer(generation: 2), .cancelTimer, .mediaPlaying(false), .ended(generation: 1)])
        #expect(m.drained(token).isEmpty && m.state == .idle)
        // A stopped preview's finish never ends the next one.
        let (next, _) = m.begin()
        _ = m.start(next)
        m.finish(token)
        #expect(m.drained(next).isEmpty)
    }

    @Test("T-032f §18 item 7: the slow-command line, over 200 ms only")
    func slowLine() {
        #expect(MediaLaneLine.slow(.stop, waitMs: 200, runMs: 12) == nil)
        #expect(MediaLaneLine.slow(.stop, waitMs: 1_204, runMs: 3) == "music lane slow cmd=stop wait_ms=1204 run_ms=3")
        #expect(MediaLaneLine.slow(.bundledPlay, waitMs: 0, runMs: 201) == "music lane slow cmd=bundled_play wait_ms=0 run_ms=201")
        #expect(MediaLaneLine.Command.allCases.map(\.rawValue) == ["begin", "start", "stop", "end", "bundled_play", "bundled_stop", "restart"])
        #expect(PreviewFailure.tooLong.code == "too_long")
        #expect(PreviewLine.cut(.tooLong, playedMs: 40_012) == "music preview cut stage=too_long played_ms=40012")
    }
}

/// A small thread-safe Int for the threads test.
private final class AtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ v: Int = 0) { value = v }
    func set(_ v: Int) { lock.withLock { value = v } }
    func get() -> Int { lock.withLock { value } }
}
