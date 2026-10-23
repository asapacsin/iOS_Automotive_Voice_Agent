import Testing
import NovaKit
@testable import NovaPorts

@Suite("T-011 NovaPorts")
struct PortsTests {
    @Test("F-03 frames are exactly 10 ms at 16 kHz (160 samples, 320 bytes)")
    func frameSize() {
        #expect(PCMFrame16k(samples: Array(repeating: 0, count: 160)) != nil)
        #expect(PCMFrame16k(samples: Array(repeating: 0, count: 159)) == nil)
        #expect(PCMFrame16k(samples: Array(repeating: 0, count: 320)) == nil)
        #expect(PCMFrame16k.byteCount == 320)
    }

    @Test("reply buffer duration at 24 kHz")
    func bufferDuration() {
        #expect(PCMBuffer(sampleRate: 24_000, samples: Array(repeating: 0, count: 24_000)).duration == .seconds(1))
    }

    @Test("F-24 retryable vs terminal error classes match contracts/voice-agent.md §8")
    func errorClassification() {
        let retryable: Set<RealtimeErrorCode> = [.disconnect, .connection, .dns, .timeout, .wsFailed, .tlsFailed,
                                                 .unavailable, .resumeUnavailable, .connectionClosed]
        for code in RealtimeErrorCode.allCases {
            #expect(code.isRetryable == retryable.contains(code), "\(code)")
        }
    }

    @Test("F-22 credential list covers every secret named in the spec")
    func credentialKeys() {
        #expect(CredentialKey.allCases.count == 6)
    }

    @Test("session config defaults follow the Gemini contract")
    func sessionDefaults() {
        let config = SessionConfig(systemInstruction: "", tools: [])
        #expect(config.model == "gemini-3.8-live" && config.voiceName == "Leda" && config.languageCode == "zh-CN")
        #expect(config.activityDetection.startSensitivity == .low && config.activityDetection.endSensitivity == .high)
        #expect(SessionConfig.maxInstructionCharacters == 4000)
    }

    @Test("F-22 credentials never print their secret")
    func credentialRedaction() {
        let planted = "test-only-planted-value"
        for credential in [RealtimeCredential.apiKey(planted), .ephemeralToken(planted)] {
            var dumped = ""
            dump(credential, to: &dumped)
            for text in ["\(credential)", String(describing: credential), String(reflecting: credential), dumped] {
                #expect(!text.contains(planted))
            }
        }
    }

    @Test("F-24 reconnect delays double from 200 ms to the 8 s cap")
    func reconnectDelays() {
        let tuning = ReconnectTuning()
        let delays = (1...7).map { tuning.delay(beforeAttempt: $0).milliseconds }
        #expect(delays == [200, 400, 800, 1600, 3200, 6400, 8000])
    }
}
