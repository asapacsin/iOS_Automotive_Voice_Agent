import NovaAgent
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
}
