import AVFAudio
import Foundation
import NovaKit
import NovaPorts
import NovaVoice

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

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        engine.attach(reply)
        engine.attach(guidance)
        engine.connect(reply, to: engine.mainMixerNode, format: replyFormat)
        engine.connect(guidance, to: engine.mainMixerNode, format: replyFormat)
    }

    // MARK: CaptureSource

    public func start(onFrame: @escaping @Sendable (PCMFrame16k) -> Void) throws {
        lock.withLock { self.onFrame = onFrame }
        guard !lock.withLock({ running }) else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        try engine.start()
        reply.play()
        guidance.play()
        // Voice processing reconfigures the I/O unit after start and iOS stops the engine; restart it.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            try? self.engine.start()
            self.reply.play()
            self.guidance.play()
        }
        lock.withLock { running = true }
    }

    public func stop() {
        guard lock.withLock({ running }) else { return }
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

    public func flush(to newEpoch: Epoch) {
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

    public func playMedia(_ track: BundledTrack) {}
    public func stopMedia() {}

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
