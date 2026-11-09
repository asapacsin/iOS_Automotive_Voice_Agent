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
    /// F-13 §18 (T-032f): the media lane. Every command runs on `mediaQueue`, one at a time, through `machine`.
    /// The preview is a source node reading `ring`: a stop empties the buffer and never stops a node.
    private let mediaQueue = DispatchQueue(label: "com.asapacsin.novadrive.media-lane", qos: .userInitiated)
    private let onMediaQueue = DispatchSpecificKey<Bool>()
    private var machine = MediaLaneMachine()  // mediaQueue only
    private var previewEnd: (generation: Int, run: @Sendable () -> Void)?  // mediaQueue only
    private var drainTimer: DispatchSourceTimer?  // mediaQueue only
    private var slowLine: (@Sendable (String) -> Void)?
    /// Mirrors of the machine for readers off the queue (`lock`).
    private var lanePlaying = false
    private var lanePreview = false
    private var laneHasPreview = false
    private var laneGeneration = 0
    nonisolated(unsafe) private static let previewFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var previewFormat: AVAudioFormat { Self.previewFormat }
    /// §18 item 2: 40 s of stereo frames, allocated once.
    private let ring: PreviewRing
    /// §18 item 1: copies frames from `ring`, zeros otherwise. Atomics and a copy only.
    private let preview: AVAudioSourceNode
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
        let ring = PreviewRing(seconds: 40, sampleRate: 44_100)
        self.ring = ring
        // §18 item 1: the render block never blocks, allocates, frees, logs or calls Swift concurrency.
        preview = AVAudioSourceNode(format: Self.previewFormat) { silence, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            if ring.read(left: left, right: right, frames: frames).frames == 0 { silence.pointee = true }
            return noErr
        }
        mediaQueue.setSpecific(key: onMediaQueue, value: true)
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
            // §18 item 6: on mediaQueue, never waited for here; the preview keeps its buffer and generation.
            self.laneAsync(.restart) {
                try? self.engine.start()
                self.reply.play()
                self.guidance.play()
                self.cue.play()
                self.apply(self.machine.restart())
                self.lock.withLock { self.restarted }?()
            }
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

    // MARK: Media lane (F-13 §18, T-032f)

    /// §18 item 7: told each slow `mediaQueue` command's line (`RuntimeLog` and the record).
    public func onSlowCommand(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { slowLine = handler } }

    private static func ms(_ from: UInt64, _ to: UInt64) -> Int { Int((to &- from) / 1_000_000) }

    /// Runs `body` on `mediaQueue` and waits for it (§18 item 3). Inline when already on the queue. `body` never waits
    /// for the render block.
    private func lane<T>(_ command: MediaLaneLine.Command, _ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: onMediaQueue) == true { return body() }
        let asked = DispatchTime.now().uptimeNanoseconds
        return mediaQueue.sync {
            let began = DispatchTime.now().uptimeNanoseconds
            defer { slow(command, asked: asked, began: began) }
            return body()
        }
    }

    private func laneAsync(_ command: MediaLaneLine.Command, _ body: @escaping @Sendable () -> Void) {
        let asked = DispatchTime.now().uptimeNanoseconds
        mediaQueue.async { [self] in
            let began = DispatchTime.now().uptimeNanoseconds
            body()
            slow(command, asked: asked, began: began)
        }
    }

    private func slow(_ command: MediaLaneLine.Command, asked: UInt64, began: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let line = MediaLaneLine.slow(command, waitMs: Self.ms(asked, began), runMs: Self.ms(began, now)) else { return }
        lock.withLock { slowLine }?(line)
    }

    /// On `mediaQueue`: carries out the machine's effects in order, then mirrors its state for readers off the queue.
    private func apply(_ effects: [MediaLaneMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .mediaPlaying(let on): continuation.yield(.mediaPlaying(on))
            case .resetBuffer(let generation): ring.reset(generation: generation)
            case .activate(let generation): ring.activate(generation: generation)
            case .deactivate: ring.deactivate()
            case .stopBundledNode: media.stop()
            case .playBundledNode: break  // `playMedia` schedules the loop and reads the node back
            case .replayBundledNode: if engine.isRunning { media.play() }
            case .startTimer: startDrainTimer()
            case .cancelTimer:
                drainTimer?.cancel()
                drainTimer = nil
            case .ended(let generation):
                if let end = previewEnd, end.generation == generation {
                    previewEnd = nil
                    end.run()
                }
            }
        }
        if !machine.hasPreview { previewEnd = nil }
        let (playing, isPreview, hasPreview) = (machine.playing, machine.previewPlaying, machine.hasPreview)
        lock.withLock {
            lanePlaying = playing
            lanePreview = isPreview
            laneHasPreview = hasPreview
        }
    }

    /// §18 item 4: the end of a preview is seen here, on `mediaQueue`, every 250 ms; never from the render thread.
    private func startDrainTimer() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: mediaQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, case .previewPlaying(let generation) = self.machine.state,
                  self.ring.isDrained(generation: generation) else { return }
            let asked = DispatchTime.now().uptimeNanoseconds
            self.apply(self.machine.drained(generation))
            self.slow(.end, asked: asked, began: asked)
        }
        drainTimer = timer
        timer.resume()
    }

    /// F-13 bundled track on the media lane, looped. A bundled file named `track.resourceName` is used
    /// when present; otherwise a generated loop, so play works offline without shipping audio.
    public func playMedia(_ track: BundledTrack) {
        // music.md lane contract: a new play request reports false, then true once it is playing, so a
        // repeated 放首歌 over the running loop is fresh evidence. A preview on the lane is stopped first (§18 item 5).
        lane(.bundledPlay) {
            let effects = machine.playBundled()
            apply(effects)
            guard effects.contains(.playBundledNode) else { return }
            // An engine stopped by an interruption cannot play (AVAudioPlayerNode raises): report not playing.
            guard lock.withLock({ running }), engine.isRunning else { return }
            let buffer = Self.bundledBuffer(track, format: replyFormat) ?? BundledLoop.buffer(format: replyFormat)
            guard let buffer else { return }
            // The loop buffer has no completion handler (§18 item 5).
            media.scheduleBuffer(buffer, at: nil, options: .loops)
            media.play()
            // Read back from the node, not assumed.
            apply(machine.bundledStarted(playing: media.isPlaying))
        }
    }

    public func stopMedia() {
        let command: MediaLaneLine.Command = lock.withLock { laneHasPreview } ? .stop : .bundledStop
        lane(command) { apply(machine.stop()) }
    }

    public var mediaPlaying: Bool {
        let (on, isPreview) = lock.withLock { (lanePlaying, lanePreview) }
        return on && (isPreview ? engine.isRunning : media.isPlaying)
    }

    /// F-13 §18 item 4 (T-032f): begins a preview on the media lane, replacing the bundled loop or an earlier preview,
    /// with an empty buffer. Returns the token (the buffer's generation), or nil when the engine cannot play now.
    public func beginPreviewStream() -> Int? {
        lane(.begin) {
            guard lock.withLock({ running }), engine.isRunning else {
                apply(machine.stop())
                return nil
            }
            let (token, effects) = machine.begin()
            apply(effects)
            lock.withLock { laneGeneration = token }
            return token
        }
    }

    /// The download task's write (not a lane command: it never waits for the queue). `.stale` once stopped.
    public func writePreview(_ buffer: AVAudioPCMBuffer, token: Int) -> PreviewRing.WriteResult {
        guard buffer.format == previewFormat, let planes = buffer.floatChannelData else { return .stale }
        return ring.write(generation: token, left: planes[0], right: planes[1], count: Int(buffer.frameLength))
    }

    /// Frames in the preview buffer now.
    public var previewFramesWritten: Int { ring.writtenFrames }

    /// Starts playing the buffer (PreviewStartRule decides when). False when stopped, replaced or the engine is down.
    public func startPreviewStream(token: Int, stillWanted: @escaping @Sendable () -> Bool) -> Bool {
        lane(.start) {
            guard lock.withLock({ running }), engine.isRunning, stillWanted() else { return false }
            let effects = machine.start(token)
            apply(effects)
            return !effects.isEmpty
        }
    }

    /// The download ended: once the render block has read the last frame, the timer ends the preview and runs
    /// `onEnd` (§14 item 6).
    public func finishPreviewStream(token: Int, onEnd: @escaping @Sendable () -> Void) {
        lane(.end) {
            guard machine.hasPreview, lock.withLock({ laneGeneration == token }) else { return }
            machine.finish(token)
            previewEnd = (token, onEnd)
            ring.finish(generation: token)
        }
    }

    /// Stops the media lane only if a preview is on it (the bundled loop keeps playing).
    /// Always queued, so it also stops a preview whose begin was queued before it.
    public func stopPreview() {
        lane(.stop) { apply(machine.stopPreview()) }
    }

    /// Stops the preview of `token` only; a newer preview or the bundled loop keeps playing.
    public func stopPreview(token: Int) {
        lane(.stop) {
            guard machine.state == .previewLoading(generation: token) || machine.state == .previewPlaying(generation: token) else { return }
            apply(machine.stopPreview())
        }
    }

    /// True only while a preview is on the lane, started, and the engine runs.
    public var previewPlaying: Bool { lock.withLock { lanePreview } && engine.isRunning }

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
