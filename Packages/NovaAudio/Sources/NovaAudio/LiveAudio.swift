import AVFAudio
import Foundation
import NovaKit
import NovaPorts
import NovaVoice
import os

/// One voice-processing `AVAudioEngine` (ios-architecture §6.4): echo-cancelled 16 kHz capture, a reply
/// lane with epoch flush, and a guidance lane. Apple voice processing is the G0 choice for now
/// (T-001 measured 8/10 at full volume; keep the speaker volume moderate).
public final class LiveAudio: CaptureSource, PlaybackPort, @unchecked Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let reply = AVAudioPlayerNode()
    private let guidance = AVAudioPlayerNode()
    private let media = AVAudioPlayerNode()
    /// F-01 §14 items 9–10 (T-060a): the wake-ready sound. Same engine, so voice processing has it in the echo
    /// reference; no playback events, so it is neither her reply nor guidance to the gate and the core.
    private let cue = AVAudioPlayerNode()
    private var mediaOn = false
    /// F-13 §14 item 4 (T-032b): an iTunes preview on the media lane, through this engine, so voice processing
    /// has it in the echo reference and it is ducked and stopped like the bundled track. 44.1 kHz stereo.
    private let preview = AVAudioPlayerNode()
    private let previewFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    /// Which node the media lane is using while `mediaOn`.
    private var previewOn = false
    /// Raised by every media stop, so a stopped preview's completion is not taken as its end.
    private var mediaGeneration = 0
    private let replyFormat = AVAudioFormat(standardFormatWithSampleRate: Double(PCMBuffer.replySampleRate), channels: 1)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMFrame16k.sampleRate),
                                              channels: 1, interleaved: true)!
    private var framer = AudioFramer10ms()
    private var converter: AVAudioConverter?
    private var onFrame: (@Sendable (PCMFrame16k) -> Void)?
    private var epoch = Epoch.initial
    private var outstanding = 0
    private var guidanceOutstanding = 0
    private var configObserver: NSObjectProtocol?
    private var running = false
    private var restarted: (@Sendable () -> Void)?

    /// F-08 §17 item 3: told each time the engine is restarted after a configuration change.
    public func onEngineRestart(_ handler: @escaping @Sendable () -> Void) { lock.withLock { restarted = handler } }

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        engine.attach(reply)
        engine.attach(guidance)
        engine.attach(media)
        engine.attach(cue)
        engine.attach(preview)
        engine.connect(reply, to: engine.mainMixerNode, format: replyFormat)
        engine.connect(guidance, to: engine.mainMixerNode, format: replyFormat)
        // Music goes through the same voice-processing engine, so it is inside the echo reference.
        engine.connect(media, to: engine.mainMixerNode, format: replyFormat)
        engine.connect(cue, to: engine.mainMixerNode, format: replyFormat)
        engine.connect(preview, to: engine.mainMixerNode, format: previewFormat)
    }

    // MARK: CaptureSource

    public func start(onFrame: @escaping @Sendable (PCMFrame16k) -> Void) throws {
        lock.withLock { self.onFrame = onFrame }
        guard !lock.withLock({ running }) else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // F-04a §4 layer 1: echo cancellation, noise suppression and AGC stay on; her own playback is
            // not ducked into the mic path.
            engine.inputNode.isVoiceProcessingBypassed = false
            engine.inputNode.isVoiceProcessingAGCEnabled = true
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            // §4/§8: capture keeps going without it; the classifier and gate (layers 2-3) still apply.
            Logger(subsystem: "com.asapacsin.novadrive", category: "audio").error("VOICE_PROCESSING_OFF")
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        try engine.start()
        reply.play()
        guidance.play()
        cue.play()
        // Voice processing reconfigures the I/O unit after start and iOS stops the engine; restart it.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            try? self.engine.start()
            self.reply.play()
            self.guidance.play()
            self.cue.play()
            if self.mediaPlaying { (self.lock.withLock { self.previewOn } ? self.preview : self.media).play() }
            self.lock.withLock { self.restarted }?()
        }
        lock.withLock { running = true }
    }

    /// F-07 §16 item 2 (T-020c): the reply's output format and session settings, read after `start`.
    public var playbackFormat: PlaybackFormat {
        let out = engine.outputNode.outputFormat(forBus: 0)
        let mode = AVAudioSession.sharedInstance().mode.rawValue
        let short = mode.hasPrefix("AVAudioSessionMode") ? String(mode.dropFirst("AVAudioSessionMode".count)) : mode
        return PlaybackFormat(rate: Int(out.sampleRate), channels: Int(out.channelCount),
                              mode: short.prefix(1).lowercased() + short.dropFirst(),
                              voiceProcessing: engine.inputNode.isVoiceProcessingEnabled)
    }

    public func stop() {
        guard lock.withLock({ running }) else { return }
        stopMedia()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            running = false
            onFrame = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
            converter?.channelMap = [0]
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * captureFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        let (frames, sink) = lock.withLock { (framer.append(samples), onFrame) }
        guard let sink else { return }
        for frame in frames { sink(frame) }
    }

    // MARK: PlaybackPort

    /// F-08 §17 item 11 (T-022e): her reply lowered by `db` while a possible interruption is checked; it keeps playing.
    public func setReplyDipped(_ dipped: Bool, byDb db: Double) {
        reply.volume = dipped ? Float(pow(10, -db / 20)) : 1
    }

    public func flush(to newEpoch: Epoch) {
        reply.volume = 1  // F-08 §17 item 11: a dip never outlives the reply it lowered
        let finished: Epoch? = lock.withLock {
            let had = outstanding > 0 ? epoch : nil
            epoch = max(newEpoch, epoch)
            outstanding = 0
            return had
        }
        reply.stop()
        reply.play()
        if let finished { continuation.yield(.replyFinished(finished)) }
    }

    public func enqueueReply(_ pcm: PCMBuffer, epoch replyEpoch: Epoch, sequence: Int) {
        guard let buffer = Self.buffer(pcm, format: replyFormat) else { return }
        let first: Bool? = lock.withLock {
            guard replyEpoch == epoch else { return nil }
            outstanding += 1
            return outstanding == 1
        }
        guard let first else { return }
        if first { continuation.yield(.replyStarted(replyEpoch)) }
        reply.scheduleBuffer(buffer) { [weak self] in self?.replyBufferDone(replyEpoch) }
    }

    private func replyBufferDone(_ replyEpoch: Epoch) {
        let done = lock.withLock { () -> Bool in
            guard replyEpoch == epoch, outstanding > 0 else { return false }
            outstanding -= 1
            return outstanding == 0
        }
        if done { continuation.yield(.replyFinished(replyEpoch)) }
    }

    public func completeReply(epoch: Epoch) {}

    public func playGuidance(_ pcm: PCMBuffer, id: GuidanceID) {
        guard let buffer = Self.buffer(pcm, format: replyFormat) else {
            // Nothing to play still ends the sentence, so the relay is never stuck on it (F-14).
            continuation.yield(.guidanceEnded(id))
            return
        }
        lock.withLock { guidanceOutstanding += 1 }
        continuation.yield(.guidanceStarted(id))
        guidance.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.guidanceOutstanding -= 1 }
            self.continuation.yield(.guidanceEnded(id))
        }
    }

    /// F-13 bundled track on the media lane, looped. A bundled file named `track.resourceName` is used
    /// when present; otherwise a generated loop, so play works offline without shipping audio.
    public func playMedia(_ track: BundledTrack) {
        // music.md lane contract: a new play request reports false, then true once it is playing, so a
        // repeated 放首歌 over the running loop is fresh evidence.
        // A preview on the lane is replaced by the bundled loop.
        if lock.withLock({ previewOn }) { stopMedia() }
        if lock.withLock({ mediaOn }), media.isPlaying {
            continuation.yield(.mediaPlaying(false))
            continuation.yield(.mediaPlaying(true))
            return
        }
        // An engine stopped by an interruption cannot play (AVAudioPlayerNode raises): report not playing.
        guard lock.withLock({ running }), engine.isRunning else { return }
        let buffer = Self.bundledBuffer(track, format: replyFormat) ?? BundledLoop.buffer(format: replyFormat)
        guard let buffer else { return }
        media.scheduleBuffer(buffer, at: nil, options: .loops)
        media.play()
        // Read back from the node, not assumed.
        let playing = media.isPlaying
        lock.withLock { mediaOn = playing }
        if playing { continuation.yield(.mediaPlaying(true)) }
    }

    public func stopMedia() {
        let wasPreview = lock.withLock { () -> Bool? in
            guard mediaOn else { return nil }
            mediaGeneration += 1
            defer { mediaOn = false; previewOn = false }
            return previewOn
        }
        guard let wasPreview else { return }
        (wasPreview ? preview : media).stop()
        continuation.yield(.mediaPlaying(false))
    }

    public var mediaPlaying: Bool {
        let (on, isPreview) = lock.withLock { (mediaOn, previewOn) }
        return on && (isPreview ? preview : media).isPlaying
    }

    /// F-13 §14 items 4–6 (T-032b): the decoded preview (`previewFormat`) on the media lane, once, replacing the
    /// bundled loop or an earlier preview. `onEnd` runs when it played to the end (not when stopped). False when
    /// the engine cannot play now.
    @discardableResult
    public func playPreview(_ buffer: AVAudioPCMBuffer, stillWanted: @escaping @Sendable () -> Bool,
                            onEnd: @escaping @Sendable () -> Void) -> Bool {
        stopMedia()
        guard lock.withLock({ running }), engine.isRunning, buffer.format == previewFormat else { return false }
        let generation = lock.withLock { mediaGeneration }
        preview.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            // A completion while the engine is stopped (a route change restart) is not the preview's end.
            guard self.engine.isRunning else { return }
            let ended = self.lock.withLock { () -> Bool in
                guard self.mediaGeneration == generation, self.mediaOn, self.previewOn else { return false }
                self.mediaGeneration += 1
                self.mediaOn = false
                self.previewOn = false
                return true
            }
            guard ended else { return }
            self.continuation.yield(.mediaPlaying(false))
            onEnd()
        }
        preview.play()
        let playing = preview.isPlaying
        lock.withLock {
            mediaOn = playing
            previewOn = playing
        }
        if playing { continuation.yield(.mediaPlaying(true)) }
        // A stop or a newer preview that came while this one was being scheduled wins: stop it again.
        if playing, !stillWanted() {
            stopMedia()
            return false
        }
        return playing
    }

    /// Stops the media lane only if a preview is on it (the bundled loop keeps playing).
    public func stopPreview() {
        if lock.withLock({ previewOn }) { stopMedia() }
    }

    /// True only while a preview is on the lane and its node plays.
    public var previewPlaying: Bool { lock.withLock { previewOn } && mediaPlaying }

    /// The format a preview must be decoded to.
    public var previewPCMFormat: AVAudioFormat { previewFormat }

    static func bundledBuffer(_ track: BundledTrack, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = ["m4a", "mp3", "wav", "caf"].lazy.compactMap {
            Bundle.main.url(forResource: track.resourceName, withExtension: $0)
        }.first
        guard let url, let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        if file.processingFormat == format { return source }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(
                Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 64) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }

    /// F-01 §14 items 9–10: plays `pcm` once on the cue node. It reports nothing, never touches the reply lane or its
    /// epoch, and is dropped when the engine is not running.
    public func playCue(_ pcm: PCMBuffer) {
        guard lock.withLock({ running }), engine.isRunning, let buffer = Self.buffer(pcm, format: replyFormat) else { return }
        cue.scheduleBuffer(buffer, completionHandler: nil)
        if !cue.isPlaying { cue.play() }
    }

    public var guidanceSounding: Bool { lock.withLock { guidanceOutstanding > 0 } }

    /// PCM16 at any rate into the 24 kHz float lane format (resampled when needed).
    static func buffer(_ pcm: PCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !pcm.samples.isEmpty else { return nil }
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.sampleRate), channels: 1,
                                   interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.samples.count)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(pcm.samples.count)
        let out = input.floatChannelData![0]
        for (i, s) in pcm.samples.enumerated() { out[i] = Float(s) / 32_768 }
        if pcm.sampleRate == Int(format.sampleRate) { return input }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(
                Double(pcm.samples.count) * format.sampleRate / Double(pcm.sampleRate)) + 32) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}
