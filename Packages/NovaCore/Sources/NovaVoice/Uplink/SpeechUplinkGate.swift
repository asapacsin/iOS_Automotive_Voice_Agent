import NovaKit
import NovaPorts

/// How a finished speech segment looked (contracts/voice-agent.md §3, `A/voice/SpeechUplinkGate.kt:299-377`).
public enum SegmentVerdict: String, Sendable, Hashable {
    case normal
    /// Shorter than 800 ms with a voiced ratio under 35%: likely a click or echo; logged.
    case flagged
    /// Shorter than 1200 ms with a voiced ratio under 60%: the turn is held for confirmation.
    case held
}

public enum UplinkGateOutput: Sendable, Hashable {
    case speechStarted
    /// A frame to upload. Pre-roll frames come first after `speechStarted`.
    case audio(PCMFrame16k)
    case speechStopped(SegmentVerdict)
    /// After the closing silence: send `audioStreamEnd`.
    case streamEnd
}

/// Local VAD on cleaned 10 ms frames (F-04). closed → onset 200 ms → open → hangover 1200 ms → closed,
/// then 1500 ms of digital silence and `streamEnd`. Pure and synchronous: runs on the capture queue.
///
/// A frame is voiced when its RMS exceeds max(RMS floor 120, noise bed × 2.2). The noise bed starts at
/// 80, is learnt from every frame during the 1500 ms warm-up (the gate cannot open then) and afterwards
/// from unvoiced frames while closed. While open, the quietest frame of the last 3 s is tracked: speech
/// always dips between syllables, so if even that frame is voiced the "speech" is a noise rise (fan,
/// window), the bed jumps to that level and the segment ends through the normal hangover. The Android noise-bed corpus is not ported yet (STATUS.md), so
/// the adaptation rate is an iOS choice to re-tune against it.
public struct SpeechUplinkGate: Sendable {
    public enum Phase: Sendable, Hashable { case closed, open }

    public private(set) var phase: Phase = .closed
    public private(set) var noiseRMS: Double
    /// The arbiter's guidance hold (F-08): no frame is uploaded while set.
    public private(set) var forcedClosed = false
    private let tuning: UplinkGateTuning
    private var elapsed = NovaDuration.zero
    private var onset = NovaDuration.zero
    private var hangover = NovaDuration.zero
    private var preRoll: [PCMFrame16k] = []
    /// The open segment up to its last voiced frame (hangover excluded), and how much of it was voiced.
    private var segmentLength = NovaDuration.zero
    private var segmentVoiced = NovaDuration.zero
    private var trailingUnvoiced = NovaDuration.zero
    /// Voiced flags of the last `evidenceWindow` of frames, whatever the phase (`recent`).
    private var recent: [Bool] = []
    /// RMS of the frames of the open segment, last `steadyWindowFrames` only.
    private var openRMS: [Double] = []

    private static let frameDuration = NovaDuration.milliseconds(10)
    /// Weight of one unvoiced frame in the noise bed after warm-up (≈ 1 s time constant).
    private static let noiseAdaptation = 0.01
    /// 3 s without a single unvoiced frame means steady noise, not speech.
    private static let steadyWindowFrames = 300

    public init(tuning: UplinkGateTuning = UplinkGateTuning()) {
        self.tuning = tuning
        noiseRMS = tuning.initialNoiseRMS
    }

    /// `hasRecentSpeech` (Astra P4): somebody is speaking now — at least the onset (200 ms) of voiced
    /// frames within the last 600 ms evidence window. This, not the open gate, qualifies a barge-in.
    public var hasRecentSpeech: Bool {
        recent.filter { $0 }.count >= Int(tuning.onset.milliseconds / Self.frameDuration.milliseconds)
    }

    public var threshold: Double { max(tuning.rmsFloor, noiseRMS * tuning.noiseFactor) }

    public mutating func process(_ frame: PCMFrame16k) -> [UplinkGateOutput] {
        let rms = Self.rms(frame)
        let warmingUp = elapsed < tuning.warmUp
        elapsed = elapsed + Self.frameDuration
        if warmingUp {
            let n = Double(elapsed.milliseconds / Self.frameDuration.milliseconds)
            noiseRMS += (rms - noiseRMS) / n  // running mean over the warm-up
            remember(frame)
            return []
        }
        let voiced = rms > threshold
        recent.append(voiced)
        let window = Int(tuning.evidenceWindow.milliseconds / Self.frameDuration.milliseconds)
        if recent.count > max(1, window) { recent.removeFirst(recent.count - max(1, window)) }
        switch phase {
        case .closed:
            if !voiced { noiseRMS += (rms - noiseRMS) * Self.noiseAdaptation }
            remember(frame)
            onset = voiced ? onset + Self.frameDuration : .zero
            guard onset >= tuning.onset, !forcedClosed else { return [] }
            return open()
        case .open:
            openRMS.append(rms)
            if openRMS.count > Self.steadyWindowFrames { openRMS.removeFirst() }
            if openRMS.count == Self.steadyWindowFrames, let floor = openRMS.min(), floor > threshold {
                noiseRMS = floor
                openRMS.removeAll(keepingCapacity: true)
                return continueSegment(frame, voiced: rms > threshold)
            }
            return continueSegment(frame, voiced: voiced)
        }
    }

    /// Arbiter hold while guidance speaks. Closing an open segment ends the turn as if the driver stopped.
    public mutating func setForcedClosed(_ closed: Bool) -> [UplinkGateOutput] {
        forcedClosed = closed
        // Like `onCaptureInterrupted`: frames from the hold must not qualify a barge-in afterwards.
        if !closed { recent.removeAll(keepingCapacity: true) }
        guard closed, phase == .open else { return [] }
        return close()
    }

    private mutating func open() -> [UplinkGateOutput] {
        phase = .open
        openRMS.removeAll(keepingCapacity: true)
        // Onset frames are part of the segment and all voiced.
        segmentLength = onset
        segmentVoiced = onset
        trailingUnvoiced = .zero
        hangover = .zero
        let frames = preRoll.map(UplinkGateOutput.audio)
        preRoll.removeAll(keepingCapacity: true)
        onset = .zero
        return [.speechStarted] + frames
    }

    private mutating func continueSegment(_ frame: PCMFrame16k, voiced: Bool) -> [UplinkGateOutput] {
        if voiced {
            segmentLength = segmentLength + trailingUnvoiced + Self.frameDuration
            segmentVoiced = segmentVoiced + Self.frameDuration
            trailingUnvoiced = .zero
            hangover = .zero
        } else {
            trailingUnvoiced = trailingUnvoiced + Self.frameDuration
            hangover = hangover + Self.frameDuration
        }
        let out: [UplinkGateOutput] = [.audio(frame)]
        return hangover >= tuning.hangover ? out + close() : out
    }

    private mutating func close() -> [UplinkGateOutput] {
        phase = .closed
        let verdict = verdict()
        let silenceFrames = Int(tuning.closingSilence.milliseconds / Self.frameDuration.milliseconds)
        onset = .zero
        hangover = .zero
        return [.speechStopped(verdict)]
            + Array(repeating: .audio(.silence), count: silenceFrames)
            + [.streamEnd]
    }

    private func verdict() -> SegmentVerdict {
        guard segmentLength > .zero else { return .flagged }
        let ratio = Double(segmentVoiced.milliseconds) / Double(segmentLength.milliseconds)
        if segmentLength < tuning.flagMaxLength && ratio < tuning.flagVoicedRatio { return .flagged }
        if segmentLength < tuning.holdMaxLength && ratio < tuning.holdVoicedRatio { return .held }
        return .normal
    }

    /// Keeps the last 300 ms of closed-gate frames for the pre-roll.
    private mutating func remember(_ frame: PCMFrame16k) {
        preRoll.append(frame)
        let keep = Int(tuning.preRoll.milliseconds / Self.frameDuration.milliseconds)
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
    }

    static func rms(_ frame: PCMFrame16k) -> Double {
        let sum = frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(frame.samples.count)).squareRoot()
    }
}
