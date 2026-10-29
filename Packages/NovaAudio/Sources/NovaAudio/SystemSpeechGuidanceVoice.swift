import AVFAudio
import Foundation
import NovaKit
import NovaPorts

public struct GuidanceVoiceUnavailable: Error, Sendable {}

/// F-14 fallback voice (T-050, ios-architecture §9.5): `AVSpeechSynthesizer` zh-CN rendered to PCM, so
/// the guidance lane plays it inside the echo reference and the arbiter sees it. Offline.
/// OQ-IOS-10 stays open until a device run compares it with Amap's internal TTS.
public final class SystemSpeechGuidanceVoice: FallbackGuidanceVoice, @unchecked Sendable {
    private let lock = NSLock()
    /// Synthesizers alive until their write finishes (`write` does not retain itself).
    private var active: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

    public init() {}

    public func render(_ text: String) async throws -> PCMBuffer {
        let synthesizer = AVSpeechSynthesizer()
        let key = ObjectIdentifier(synthesizer)
        lock.withLock { active[key] = synthesizer }
        defer { lock.withLock { _ = active.removeValue(forKey: key) } }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        let collector = SampleCollector()
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // The last callback is an empty buffer: the utterance is complete.
                guard pcm.frameLength > 0 else {
                    switch collector.finish() {
                    case .none: break
                    case .some(.some(let result)): continuation.resume(returning: result)
                    case .some(.none): continuation.resume(throwing: GuidanceVoiceUnavailable())
                    }
                    return
                }
                collector.append(pcm)
            }
        }
    }
}

/// Mono PCM16 from the synthesizer's buffers (float or int16, whatever rate it renders at).
private final class SampleCollector: @unchecked Sendable {
    private var samples: [Int16] = []
    private var rate = 0
    private var finished = false

    func append(_ buffer: AVAudioPCMBuffer) {
        rate = Int(buffer.format.sampleRate)
        let count = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData?[0] {
            for i in 0..<count { samples.append(Int16(max(-1, min(1, floats[i])) * 32_767)) }
        } else if let ints = buffer.int16ChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: ints, count: count))
        }
    }

    /// Outer nil after the first call (the continuation resumes once); inner nil when nothing was
    /// rendered (no zh-CN voice installed).
    func finish() -> PCMBuffer?? {
        guard !finished else { return .none }
        finished = true
        guard !samples.isEmpty, rate > 0 else { return .some(nil) }
        return .some(PCMBuffer(sampleRate: rate, samples: samples))
    }
}
