import NovaAgent
import NovaPorts
import NovaVoice
import Testing

@Suite("T-020a F-07 §14 items 7-8 record lines")
struct VoiceRecordTests {
    @Test("T-020a row 8: voice-failed and voice timing lines carry numbers and codes, no reply text")
    func lines() {
        var r = ConversationRecorder()
        let failed = VoiceFailedLine(turn: 3, source: .qwen, code: "QWEN_TTS_TIMEOUT")
        let clause = VoiceClauseLine(source: .azure, chars: 12, firstMs: 310, ms: 820, attempt: 2)
        #expect(r.add(.voiceFailed(failed), atMs: 7) == ["7 voice-failed turn=3 source=qwen code=QWEN_TTS_TIMEOUT"])
        #expect(r.add(.voiceClause(clause), atMs: 9) == ["9 voice source=azure chars=12 first_ms=310 ms=820 attempt=2"])
        #expect(failed.logLine == "voice-failed turn=3 source=qwen code=QWEN_TTS_TIMEOUT")
        #expect(clause.logLine == "voice source=azure chars=12 first_ms=310 ms=820 attempt=2")
    }

    @Test("T-020b row 13 / F-24 row 4: the gemini timing line and session closed code= reason= in the record")
    func geminiAndClosed() {
        var r = ConversationRecorder()
        let gemini = GeminiVoiceLine(turn: 4, heldMs: 0, firstMs: 912)
        #expect(r.add(.voiceGemini(gemini), atMs: 5) == ["5 voice source=gemini turn=4 held_ms=0 first_ms=912"])
        let reason = String(repeating: "x", count: 100) + "\nmore"
        let closed = SessionClosedLine(code: 1011, reason: "Internal error encountered.")
        #expect(r.add(.sessionClosed(closed), atMs: 8) == ["8 session closed code=1011 reason=Internal error encountered."])
        #expect(SessionClosedLine(code: 1000, reason: reason).reason.count == 80)
        #expect(r.add(.claimCut(turn: 2, playedMs: 800), atMs: 9) == ["9 claim-cut turn=2 played_ms=800"])
        #expect(!SessionClosedLine(code: 1000, reason: "a\nb").reason.contains("\n"))
    }
}

