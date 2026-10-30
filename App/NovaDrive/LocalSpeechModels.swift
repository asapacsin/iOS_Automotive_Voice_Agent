import Foundation
import NovaAsrSherpa
import NovaKit
import NovaPorts
import NovaVoice
import os

/// F-05a §12 item 7 / F-08 §14 item 2: the bundled sherpa-onnx recognizer and stop-phrase spotter, loaded once per
/// app run off the main actor from `SherpaModels/asr` and `SherpaModels/kws`, and kept loaded.
final class LocalSpeechModels: @unchecked Sendable {
    static let shared = LocalSpeechModels()

    enum State { case loading, ready, failed }

    private let lock = NSLock()
    private var started = false
    private var asrState = State.loading
    private var recognizer: SherpaTranscriber?
    private var spotterLoaded: StopPhraseSpotterBox?
    /// The current session's subscriber; the recognizer's single event stream is consumed here once.
    private var subscriber: AsyncStream<LocalTranscript>.Continuation?

    /// Idempotent; returns at once. Loading runs on a background task.
    func load() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        Task.detached(priority: .userInitiated) { self.loadNow() }
    }

    private func loadNow() {
        let root = Bundle.main.url(forResource: "SherpaModels", withExtension: nil)
        let start = Date()
        do {
            guard let root else { throw CocoaError(.fileNoSuchFile) }
            let asr = try SherpaTranscriber(directory: root.appendingPathComponent("asr", isDirectory: true))
            // F-05a §12 item 10: one line per utterance, numbers only (I-8).
            asr.onTiming = { timing in RuntimeLog.agent.notice("\(timing.logLine, privacy: .public)") }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            lock.withLock {
                recognizer = asr
                asrState = .ready
            }
            // F-05a §12 item 10: one line at load, no transcript text (I-8).
            RuntimeLog.agent.notice("asrLoaded model=\(asr.modelName, privacy: .public) ms=\(ms, privacy: .public)")
            Task.detached { await self.forward(asr.events) }
        } catch {
            lock.withLock { asrState = .failed }
            RuntimeLog.agent.error("ASR_LOAD_FAILED")
        }
        do {
            guard let root else { throw CocoaError(.fileNoSuchFile) }
            let kws = try SherpaStopPhraseSpotter(directory: root.appendingPathComponent("kws", isDirectory: true))
            lock.withLock { spotterLoaded = StopPhraseSpotterBox(kws) }
        } catch {
            RuntimeLog.agent.error("KWS_LOAD_FAILED")
        }
    }

    private func forward(_ events: AsyncStream<LocalTranscript>) async {
        for await event in events {
            let target = lock.withLock { subscriber }
            target?.yield(event)
        }
    }

    /// A new session's event stream; the previous session's stream ends.
    func subscribe() -> AsyncStream<LocalTranscript> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocalTranscript.self, bufferingPolicy: .bufferingNewest(256))
        let old = lock.withLock { () -> AsyncStream<LocalTranscript>.Continuation? in
            defer { subscriber = continuation }
            return subscriber
        }
        old?.finish()
        return stream
    }

    var loadedRecognizer: SherpaTranscriber? { lock.withLock { recognizer } }
    var spotter: StopPhraseSpotterBox? { lock.withLock { spotterLoaded } }

    var availability: TranscriberAvailability {
        lock.withLock {
            switch asrState {
            case .ready: .ready
            case .loading: .unavailable(reason: "模型加载中")
            case .failed: .unavailable(reason: "模型加载失败")
            }
        }
    }

    /// 音频测试: the 识别 and 打断词 lines (F-05a §12 item 10, F-08 §14 item 8).
    var diagnostics: String {
        lock.withLock {
            let asr: String = switch asrState {
            case .ready: "识别：本机（内置 \(recognizer?.modelName ?? "")）"
            case .loading: "识别：云端（本机不可用：模型加载中）"
            case .failed: "识别：云端（本机不可用：模型加载失败）"
            }
            let kws = spotterLoaded != nil ? "打断词：本机" : "打断词：仅文字"
            return asr + "\n" + kws
        }
    }
}

/// One session's view of the bundled recognizer. Until the model is loaded it is unavailable (§5 S3 applies);
/// an utterance begun before the load finished is never forwarded half-way.
final class BundledTranscriber: LocalTranscriber, @unchecked Sendable {
    private let models: LocalSpeechModels
    private let lock = NSLock()
    private var begun: UtteranceID?
    let events: AsyncStream<LocalTranscript>

    init(models: LocalSpeechModels = .shared) {
        self.models = models
        events = models.subscribe()
    }

    var availability: TranscriberAvailability { get async { models.availability } }

    func begin(utterance: UtteranceID) async {
        guard let inner = models.loadedRecognizer else { return }
        lock.withLock { begun = utterance }
        await inner.begin(utterance: utterance)
    }

    func append(_ frame: PCMFrame16k) async {
        guard lock.withLock({ begun != nil }), let inner = models.loadedRecognizer else { return }
        await inner.append(frame)
    }

    func end(utterance: UtteranceID) async {
        let mine = lock.withLock { () -> Bool in
            defer { if begun == utterance { begun = nil } }
            return begun == utterance
        }
        guard mine, let inner = models.loadedRecognizer else { return }
        await inner.end(utterance: utterance)
    }
}

/// The spotter is not Sendable; it is only ever touched on `StopPhraseFeed`'s serial queue.
final class StopPhraseSpotterBox: @unchecked Sendable {
    let spotter: any StopPhraseSpotter
    init(_ spotter: any StopPhraseSpotter) { self.spotter = spotter }
}

/// F-08 §14 item 3: capture frames go to the spotter only inside the playback + echo-tail window, on a serial
/// queue (in capture order) so `accept` never holds up the capture thread.
final class StopPhraseFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.asapacsin.novadrive.kws", qos: .userInitiated)
    private let models: LocalSpeechModels
    private let onHit: @Sendable (StopPhraseHit) -> Void
    /// Touched only on `queue`.
    private var feeder = StopPhraseFeeder()

    init(models: LocalSpeechModels = .shared, onHit: @escaping @Sendable (StopPhraseHit) -> Void) {
        self.models = models
        self.onHit = onHit
    }

    /// Called on the capture thread after the gate has processed `frame`.
    func frame(_ frame: PCMFrame16k, inWindow: Bool) {
        guard let box = models.spotter else { return }
        queue.async {
            if let hit = self.feeder.frame(frame, inWindow: inWindow, spotter: box.spotter) { self.onHit(hit) }
        }
    }
}
