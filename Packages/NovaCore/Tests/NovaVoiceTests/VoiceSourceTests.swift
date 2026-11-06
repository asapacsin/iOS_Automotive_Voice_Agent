import Foundation
import NovaKit
import NovaPorts
import NovaVoice
import Synchronization
import Testing

/// Answers each call from a script of results; records the deadlines it was given.
final class ScriptedSynth: SpeechSynthesizer {
    private let script: Mutex<[Result<PCMBuffer, SpeechSynthesisError>]>
    let calls = Mutex(0)

    init(_ script: [Result<PCMBuffer, SpeechSynthesisError>]) { self.script = Mutex(script) }

    func synthesize(_ text: String, style: SpeakingStyle, deadline: NovaDuration) async throws -> PCMBuffer {
        calls.withLock { $0 += 1 }
        let next = script.withLock { $0.isEmpty ? .failure(SpeechSynthesisError("SCRIPT_EMPTY")) : $0.removeFirst() }
        return try next.get()
    }

    func warmUp() async {}
}

final class RecordingPlayback: PlaybackPort {
    let played = Mutex<[Int]>([])
    func flush(to epoch: Epoch) {}
    func enqueueReply(_ pcm: PCMBuffer, epoch: Epoch, sequence: Int) { played.withLock { $0.append(sequence) } }
    func completeReply(epoch: Epoch) {}
    func playGuidance(_ pcm: PCMBuffer, id: GuidanceID) {}
    func playMedia(_ track: BundledTrack) {}
    func stopMedia() {}
    var events: AsyncStream<PlaybackEvent> { AsyncStream { $0.finish() } }
    var guidanceSounding: Bool { false }
}

@Suite("T-020a F-07 §14 voice source, retry and lines")
struct VoiceSourceTests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])

    func run(_ script: [Result<PCMBuffer, SpeechSynthesisError>]) async -> (played: [Int], failures: [String], lines: [VoiceClauseLine], calls: Int) {
        let synth = ScriptedSynth(script)
        let lines = Mutex<[VoiceClauseLine]>([])
        let failures = Mutex<[String]>([])
        let playback = RecordingPlayback()
        let retrying = RetryingSpeechSynthesizer(synth, source: .qwen, onClause: { l in lines.withLock { $0.append(l) } })
        let revoicer = Revoicer(synthesizer: retrying, playback: playback,
                                onFailure: { code in failures.withLock { $0.append(code) } })
        await revoicer.speak("现在是下午五点。")
        for _ in 0..<2000 where await revoicer.pendingClauses > 0 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        return (playback.played.withLock { $0 }, failures.withLock { $0 }, lines.withLock { $0 }, synth.calls.withLock { $0 })
    }

    @Test("T-020a row 6: a timeout then success plays once with attempt=2; two failures and an auth failure silence the reply")
    func retry() async {
        let timeout = SpeechSynthesisError("QWEN_TTS_TIMEOUT")
        let ok = await run([.failure(timeout), .success(pcm)])
        #expect(ok.played == [0] && ok.failures.isEmpty && ok.calls == 2)
        #expect(ok.lines.count == 1 && ok.lines[0].attempt == 2 && ok.lines[0].source == .qwen && ok.lines[0].chars == 8)

        let both = await run([.failure(timeout), .failure(timeout), .success(pcm)])
        #expect(both.played.isEmpty && both.failures == ["QWEN_TTS_TIMEOUT"] && both.calls == 2 && both.lines.isEmpty)

        let auth = await run([.failure(SpeechSynthesisError("QWEN_TTS_AUTH")), .success(pcm)])
        #expect(auth.played.isEmpty && auth.failures == ["QWEN_TTS_AUTH"] && auth.calls == 1)

        for code in ["QWEN_TTS_NETWORK", "QWEN_TTS_RATE", "QWEN_TTS_HTTP_500", "QWEN_TTS_HTTP_503", "AZURE_TTS_TIMEOUT",
                     "AZURE_TTS_NETWORK", "AZURE_TTS_THROTTLED", "AZURE_TTS_HTTP_502"] {
            #expect(RetryingSpeechSynthesizer.isRetryable(code), "\(code)")
        }
        for code in ["QWEN_TTS_AUTH", "QWEN_TTS_VOICE", "QWEN_TTS_EMPTY", "QWEN_TTS_BAD_STREAM", "QWEN_TTS_HTTP_404",
                     "AZURE_TTS_AUTH", "AZURE_TTS_EMPTY", "AZURE_TTS_BAD_REQUEST"] {
            #expect(!RetryingSpeechSynthesizer.isRetryable(code), "\(code)")
        }
    }

    @Test("T-020a row 7: VoiceSource.resolve and the API Host check")
    func resolve() {
        let host = "ws-x.ap-southeast-1.maas.aliyuncs.com"
        #expect(VoiceSource.resolve(choice: .qwen, qwenKey: "k", qwenHost: host, azureKey: nil) == .qwen(key: "k", host: host))
        #expect(VoiceSource.resolve(choice: .qwen, qwenKey: "k", qwenHost: nil, azureKey: nil) == .blocked("请先在设置里保存千问 key 和 API Host"))
        #expect(VoiceSource.resolve(choice: .qwen, qwenKey: nil, qwenHost: host, azureKey: "a") == .blocked(VoiceSource.qwenMissingMessage))
        #expect(VoiceSource.resolve(choice: .azure, qwenKey: "k", qwenHost: host, azureKey: "a") == .azure)
        #expect(VoiceSource.resolve(choice: nil, qwenKey: "k", qwenHost: host, azureKey: "a") == .qwen(key: "k", host: host))
        #expect(VoiceSource.effectiveChoice(nil, hasQwenKey: false, hasAzureKey: false) == .qwen)
        #expect(VoiceHostCheck.isValid(host))
        #expect(!VoiceHostCheck.isValid("https://ws-x.ap-southeast-1.maas.aliyuncs.com/"))
        #expect(!VoiceHostCheck.isValid("a b"))
        #expect(VoiceHostCheck.invalidMessage == "API Host 格式不对")
    }
}
