import AVFAudio
import Foundation
import NovaPorts
import NovaVoice

/// One silent trial: the driver says nothing while a loud 24 kHz reply plays through the same engine.
public struct EchoTrial: Sendable, Hashable {
    /// True when the uplink gate heard the reply as speech (self barge-in).
    public let gateOpened: Bool
    /// Loudest 10 ms frame RMS (PCM16 units) captured while the reply played.
    public let peakRMS: Double
}

public struct EchoSpikeReport: Sendable, Hashable {
    public let voiceProcessing: Bool
    public let trials: [EchoTrial]
    public let inputLatencyMs: Double
    public let outputLatencyMs: Double
    public let ioBufferMs: Double
    public let captureSampleRate: Double

    public var closedCount: Int { trials.filter { !$0.gateOpened }.count }
    /// T-001 pass criteria: at least 9 of 10 trials keep the gate closed.
    public var passed: Bool { closedCount >= 9 && trials.count >= 10 }

    public var summary: String {
        let peaks = trials.map { String(Int($0.peakRMS)) }.joined(separator: ",")
        return """
        T-001 echo spike (OQ-IOS-3, OQ-IOS-14)
        voice processing: \(voiceProcessing ? "on" : "off")
        gate closed: \(closedCount)/\(trials.count) → \(passed ? "PASS" : "FAIL")
        peak RMS per trial: \(peaks)
        input latency: \(String(format: "%.1f", inputLatencyMs)) ms
        output latency: \(String(format: "%.1f", outputLatencyMs)) ms
        IO buffer: \(String(format: "%.1f", ioBufferMs)) ms
        capture rate: \(Int(captureSampleRate)) Hz
        """
    }
}

/// T-001 device spike: plays a speech-like 24 kHz signal through `AVAudioEngine` with Apple voice
/// processing on the I/O node and runs the real `SpeechUplinkGate` on the captured 16 kHz frames.
public final class EchoSpike: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = SpeechUplinkGate()
    private var framer = AudioFramer10ms()
    private var listening = false
    private var opened = false
    private var peak = 0.0

    public init() {}

    public func run(trials: Int = 10, voiceProcessing: Bool = true) async throws -> EchoSpikeReport {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

        let engine = AVAudioEngine()
        try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
        let player = AVAudioPlayerNode()
        let replyFormat = AVAudioFormat(standardFormatWithSampleRate: Double(PCMBuffer.replySampleRate), channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: replyFormat)

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMFrame16k.sampleRate),
                                      channels: 1, interleaved: true)!
        engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: nil) { [self] buffer, _ in
            capture(buffer, outFormat)
        }
        try engine.start()
        player.play()
        // Turning on voice processing reconfigures the I/O unit right after start, and iOS stops the engine
        // when that happens; restart it, or no reply plays and nothing is captured.
        nonisolated(unsafe) let liveEngine = engine
        nonisolated(unsafe) let livePlayer = player
        let restart = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                             object: engine, queue: nil) { _ in
            try? liveEngine.start()
            livePlayer.play()
        }
        defer {
            NotificationCenter.default.removeObserver(restart)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        nonisolated(unsafe) let reply = Self.speechLikeReply(format: replyFormat, seconds: 3)
        var results: [EchoTrial] = []
        for _ in 0..<trials {
            lock.withLock { gate = SpeechUplinkGate(); framer.reset(); opened = false; peak = 0; listening = true }
            // The gate learns the noise bed for 1500 ms and cannot open before that.
            try await Task.sleep(for: .milliseconds(1700))
            // Not awaited: a stopped engine never reports playback, which would hang the spike.
            Self.schedule(reply, on: livePlayer)
            try await Task.sleep(for: .milliseconds(3500))
            results.append(lock.withLock {
                listening = false
                return EchoTrial(gateOpened: opened, peakRMS: peak)
            })
            try await Task.sleep(for: .milliseconds(800))
        }
        return EchoSpikeReport(voiceProcessing: voiceProcessing, trials: results,
                               inputLatencyMs: session.inputLatency * 1000, outputLatencyMs: session.outputLatency * 1000,
                               ioBufferMs: session.ioBufferDuration * 1000,
                               captureSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate)
    }

    /// Built from the first captured buffer's format; rebuilt if a reconfiguration changes it.
    private var converter: AVAudioConverter?

    private func capture(_ buffer: AVAudioPCMBuffer, _ outFormat: AVAudioFormat) {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.channelMap = [0]
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
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
        lock.withLock {
            guard listening else { return }
            for frame in framer.append(samples) {
                let rms = (frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.samples.count)).squareRoot()
                peak = max(peak, rms)
                if gate.process(frame).contains(.speechStarted(sentToModel: true)) { opened = true }
            }
        }
    }

    /// Fire and forget: nothing waits for playback, which a stopped engine never reports.
    private static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Voiced harmonics on a gliding 120–220 Hz pitch, gated at a 4 Hz syllable rate, near full scale.
    static func speechLikeReply(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let out = buffer.floatChannelData![0]
        var phase = 0.0
        for i in 0..<Int(count) {
            let t = Double(i) / rate
            let f0 = 170 + 50 * sin(2 * .pi * 0.7 * t)
            phase += 2 * .pi * f0 / rate
            var voiced = 0.0
            for h in 1...8 { voiced += sin(Double(h) * phase) / Double(h) }
            let syllable = max(0, sin(2 * .pi * 4 * t))
            out[i] = Float(0.45 * voiced * syllable)
        }
        return buffer
    }
}
