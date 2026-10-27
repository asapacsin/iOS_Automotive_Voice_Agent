import AVFAudio
import CoreMedia
import Foundation
import NovaKit
import NovaPorts
import os
import SoundAnalysis

/// F-04a layer 2 (T-013b): Apple's built-in sound classifier over the cleaned 16 kHz mic frames, 0.5 s
/// windows with 0.75 overlap (a result about every 125 ms), on its own queue so capture never waits.
/// Only labels leave this type; no audio is stored or uploaded (I-8).
public final class SoundAnalysisSpeechClassifier: NSObject, SpeechClassifier, SNResultsObserving, @unchecked Sendable {
    /// Human-voice labels of the version 1 classifier; singing is music, not a command.
    static let speechLabels: Set<String> = ["speech", "conversation", "shout", "yell", "whispering"]

    private let queue = DispatchQueue(label: "nova.speech-classifier")
    private let logger = Logger(subsystem: "com.asapacsin.novadrive", category: "audio")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PCMFrame16k.sampleRate),
                                       channels: 1, interleaved: false)!
    private var analyzer: SNAudioStreamAnalyzer?
    private var onResult: (@Sendable (SpeechClassification) -> Void)?
    private var position: AVAudioFramePosition = 0

    override public init() { super.init() }

    public func start(onResult: @escaping @Sendable (SpeechClassification) -> Void) throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 1, timescale: 2)
        request.overlapFactor = 0.75
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: self)
        queue.sync {
            self.onResult = onResult
            self.analyzer = analyzer
            self.position = 0
        }
    }

    public func feed(_ frame: PCMFrame16k) {
        let samples = frame.samples
        queue.async { [self] in
            guard let analyzer,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            for (i, sample) in samples.enumerated() { channel[i] = Float(sample) / 32_768 }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(samples.count)
        }
    }

    public func stop() {
        queue.async { [self] in
            analyzer?.removeAllRequests()
            analyzer = nil
            onResult = nil
        }
    }

    // MARK: SNResultsObserving

    public func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var speech = 0.0
        var other: (label: String, confidence: Double)?
        for item in result.classifications {
            if Self.speechLabels.contains(item.identifier) {
                speech = max(speech, item.confidence)
            } else if item.confidence > (other?.confidence ?? 0) {
                other = (item.identifier, item.confidence)
            }
        }
        onResult?(SpeechClassification(speechProbability: speech, topNonSpeech: other?.label))
    }

    public func request(_ request: any SNRequest, didFailWithError error: any Error) {
        // §8: the gate notices the silence and falls back to F-04 rules; only a code is logged.
        logger.error("SPEECH_CLASSIFIER_FAILED")
    }
}
