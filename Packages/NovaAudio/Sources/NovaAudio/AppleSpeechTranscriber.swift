import AVFAudio
import Foundation
import NovaKit
import NovaPorts
import os
import Speech

/// F-05a (T-016b): the phone's own `zh-CN` recognizer over the frames that go up to Gemini, one request per
/// utterance, on device only (no audio leaves the phone). Only texts leave this type; nothing is logged (I-8).
public final class AppleSpeechTranscriber: LocalTranscriber, @unchecked Sendable {
    public let events: AsyncStream<LocalTranscript>
    private let continuation: AsyncStream<LocalTranscript>.Continuation
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let logger = Logger(subsystem: "com.asapacsin.novadrive", category: "audio")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PCMFrame16k.sampleRate),
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    /// The open utterance; guarded by `lock` (frames come from the capture side, results from Speech's queue).
    private var current: (id: UtteranceID, request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask)?
    /// Utterances that already gave a final or a failure: a later callback for them is dropped.
    private var settled: Set<Int> = []

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Asks for 语音识别 once (with the first microphone use, §2); later calls return the stored answer.
    public static func requestPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
            }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public var availability: TranscriberAvailability {
        get async {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .unavailable(reason: "未授权") }
            guard let recognizer, recognizer.supportsOnDeviceRecognition else { return .unavailable(reason: "本机不支持") }
            return recognizer.isAvailable ? .ready : .unavailable(reason: "暂不可用")
        }
    }

    public func begin(utterance id: UtteranceID) async {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(id, result: result, error: error)
        }
        let previous = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            let previous = current?.request
            current = (id, request, task)
            return previous
        }
        previous?.endAudio()
    }

    public func append(_ frame: PCMFrame16k) async {
        guard let request = lock.withLock({ current?.request }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        for (i, sample) in frame.samples.enumerated() { channel[i] = Float(sample) / 32_768 }
        request.append(buffer)
    }

    public func end(utterance id: UtteranceID) async {
        // Finished, not cancelled: the final still arrives (§9).
        let request = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            guard current?.id == id else { return nil }
            defer { current = nil }
            return current?.request
        }
        request?.endAudio()
    }

    private func handle(_ id: UtteranceID, result: SFSpeechRecognitionResult?, error: Error?) {
        let open = lock.withLock { !settled.contains(id.value) }
        guard open else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                settle(id)
                continuation.yield(.final(id, text))
            } else {
                continuation.yield(.partial(id, text))
            }
            return
        }
        if error != nil {
            settle(id)
            logger.notice("local transcript failed")
            continuation.yield(.failed(id, reason: "识别出错"))
        }
    }

    private func settle(_ id: UtteranceID) {
        lock.withLock {
            settled.insert(id.value)
            if settled.count > 64, let oldest = settled.min() { settled.remove(oldest) }
        }
    }
}
