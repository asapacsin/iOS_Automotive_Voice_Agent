import Foundation
import NovaKit
import NovaPorts
import NovaVoice
import Testing

/// F-07 §15 item 5 timing line (kept by F-07 §18 item 5) and the F-24 §16 audio chunker.
@Suite("T-020b F-07 §15 voice timing line and audio chunker")
struct VoiceTimingTests {
    @Test("T-020b row 13: voice source=gemini turn= held_ms= first_ms=, once per played turn")
    func geminiTimingLine() {
        var timing = GeminiVoiceTiming()
        timing.utteranceSent(at: NovaInstant(milliseconds: 1_000))
        timing.audioReceived(turn: 3, at: NovaInstant(milliseconds: 1_600))
        timing.audioReceived(turn: 3, at: NovaInstant(milliseconds: 1_700))
        let line = timing.audioPlayed(turn: 3, at: NovaInstant(milliseconds: 2_400))
        #expect(line == GeminiVoiceLine(turn: 3, heldMs: 800, firstMs: 1_400))
        #expect(line?.logLine == "voice source=gemini turn=3 held_ms=800 first_ms=1400")
        #expect(timing.audioPlayed(turn: 3, at: NovaInstant(milliseconds: 2_500)) == nil)
    }

    @Test("T-020e F-07 row 28: with Qwen the timing line reads source=qwen-realtime")
    func qwenTimingLine() {
        var timing = GeminiVoiceTiming(source: GeminiVoiceLine.qwenSource)
        timing.audioReceived(turn: 1, at: NovaInstant(milliseconds: 500))
        let line = timing.audioPlayed(turn: 1, at: NovaInstant(milliseconds: 500))
        #expect(line?.logLine == "voice source=qwen-realtime turn=1 held_ms=0 first_ms=none")
    }

    @Test("T-020b F-24 row 1: 95 frames then the gate closes -> 9 messages of 100 ms, then 1 of 50 ms, bytes unchanged")
    func chunker() {
        var chunker = AudioChunker()
        let frames = (0..<95).map { i in PCMFrame16k(samples: (0..<160).map { Int16(truncatingIfNeeded: i * 160 + $0) })! }
        var messages: [[PCMFrame16k]] = []
        for f in frames { if let m = chunker.add(f) { messages.append(m) } }
        if let rest = chunker.flush() { messages.append(rest) }
        #expect(messages.count == 10)
        #expect(messages.prefix(9).allSatisfy { $0.count == 10 })
        #expect(messages.last?.count == 5)
        #expect(messages.flatMap { $0 } == frames)
        #expect(chunker.flush() == nil)
    }
}
