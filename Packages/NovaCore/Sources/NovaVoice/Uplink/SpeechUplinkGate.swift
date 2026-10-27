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
    /// F-04a: classifier results stamped with gate time, newest last (`window` kept).
    private var classifications: [(at: NovaDuration, result: SpeechClassification)] = []
    /// F-04a: when the current onset started waiting for confirmation, and when its first voiced frame came.
    private var confirmingSince: NovaDuration?
    private var onsetBegan: NovaDuration?
    /// Voiced time since `onsetBegan` (the onset counter restarts on every unvoiced frame).
    private var onsetVoiced = NovaDuration.zero
    /// F-04a diagnostics (音频测试): the last onset rejected as non-speech and why.
    public private(set) var lastRejection: String?
    public private(set) var rejections = 0
    public var lastSpeechProbability: Double? { classifications.last?.result.speechProbability }
    /// 抗噪 switch (F-04a §2): off = F-04 behaviour exactly.
    public var suppressionEnabled = true
    /// Gate time of the newest classifier result.
    private var lastClassifiedAt: NovaDuration?
    /// A classifier has spoken within `activeTimeout`; when it falls silent the gate is F-04 again at once.
    private var classifierActive: Bool {
        guard let at = lastClassifiedAt else { return false }
        return elapsed - at <= (tuning.speechConfirm ?? SpeechConfirmTuning()).activeTimeout
    }
    /// 音频测试: the newest result is within `freshness`, so the shown probability is live.
    public var classifierFresh: Bool {
        guard let at = lastClassifiedAt else { return false }
        return elapsed - at <= (tuning.speechConfirm ?? SpeechConfirmTuning()).freshness
    }

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
        let voiced = recent.filter { $0 }.count >= Int(tuning.onset.milliseconds / Self.frameDuration.milliseconds)
        // F-04a: a barge-in also needs the classifier to hear a voice, so a horn or music never interrupts her.
        guard voiced, let t = confirmTuning else { return voiced }
        return speechConfirmed(t) ?? true
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
            if voiced, onset == .zero, confirmingSince == nil {
                onsetBegan = elapsed - Self.frameDuration
                onsetVoiced = .zero
            }
            if voiced, onsetBegan != nil { onsetVoiced = onsetVoiced + Self.frameDuration }
            onset = voiced ? onset + Self.frameDuration : .zero
            if confirmingSince != nil { return forcedClosed ? [] : confirm() }
            guard onset >= tuning.onset, !forcedClosed else { return [] }
            guard confirmTuning != nil else { return open() }
            confirmingSince = elapsed
            return confirm()
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
        // An onset waiting for confirmation is abandoned when the hold starts, and frames buffered around
        // the hold are never uploaded as pre-roll (F-04: a voice still going on at release opens at once).
        if closed { clearConfirming() }
        preRoll.removeAll(keepingCapacity: true)
        // Like `onCaptureInterrupted`: frames from the hold must not qualify a barge-in afterwards.
        if !closed { recent.removeAll(keepingCapacity: true) }
        guard closed, phase == .open else { return [] }
        return close()
    }

    // MARK: F-04a speech confirmation

    /// Only once a classifier has spoken: without one (not attached, failed to start) the gate is F-04 exactly.
    private var confirmTuning: SpeechConfirmTuning? {
        suppressionEnabled && classifierActive ? tuning.speechConfirm : nil
    }

    /// Lifecycle change (F-04a §6): forget classifier results and any onset waiting for confirmation.
    public mutating func resetClassifier() {
        classifications.removeAll(keepingCapacity: true)
        // Stay armed: a live classifier keeps confirming across the reset (an onset waits for fresh results);
        // a dead one still expires after `activeTimeout`.
        if lastClassifiedAt != nil { lastClassifiedAt = elapsed }
        clearConfirming()
    }

    private mutating func clearConfirming() {
        confirmingSince = nil
        onsetBegan = nil
        onsetVoiced = .zero
        onset = .zero
    }

    /// A classifier result; the caller serialises it with `process` (same lock).
    public mutating func classified(_ result: SpeechClassification) {
        lastClassifiedAt = elapsed
        classifications.append((elapsed, result))
        let keep = max(1, confirmTuning?.window ?? 3)
        if classifications.count > keep { classifications.removeFirst(classifications.count - keep) }
    }

    /// From fresh results only; nil when the classifier has said nothing lately (then F-04 rules decide).
    private func speechConfirmed(_ t: SpeechConfirmTuning) -> Bool? {
        let fresh = classifications.filter { elapsed - $0.at <= t.freshness }.suffix(t.window)
        guard !fresh.isEmpty else { return nil }
        let speech = fresh.filter { $0.result.speechProbability >= t.threshold }.count
        return speech >= min(t.required, t.window)
    }

    private mutating func confirm() -> [UplinkGateOutput] {
        guard let t = confirmTuning, let since = confirmingSince else { return open() }
        let waited = elapsed - since >= t.maxWait
        switch speechConfirmed(t) {
        case true?:
            return open()
        case false? where waited:
            lastRejection = classifications.last?.result.topNonSpeech ?? "非语音"
            rejections += 1
            clearConfirming()
            return []
        case nil where waited:
            return open()  // §8: a silent or late classifier never costs real speech
        default:
            return []
        }
    }

    private mutating func open() -> [UplinkGateOutput] {
        phase = .open
        openRMS.removeAll(keepingCapacity: true)
        // The segment starts at the first voiced frame of the onset; confirming may have made it longer
        // than the onset, with unvoiced frames in it.
        if let began = onsetBegan {
            segmentLength = elapsed - began
            segmentVoiced = min(onsetVoiced, segmentLength)
        } else {
            segmentLength = onset
            segmentVoiced = onset
        }
        trailingUnvoiced = .zero
        hangover = .zero
        // While confirming, the buffer grew past the pre-roll: keep only the pre-roll before the first voiced frame.
        if let began = onsetBegan {
            let keep = Int(((elapsed - began) + tuning.preRoll).milliseconds / Self.frameDuration.milliseconds)
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        }
        let frames = preRoll.map(UplinkGateOutput.audio)
        preRoll.removeAll(keepingCapacity: true)
        clearConfirming()
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
        // F-04a: while an onset waits for confirmation every frame since it began is kept.
        let extra = confirmTuning.map { tuning.onset + $0.maxWait } ?? .zero
        let keep = Int((tuning.preRoll + extra).milliseconds / Self.frameDuration.milliseconds)
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
    }

    static func rms(_ frame: PCMFrame16k) -> Double {
        let sum = frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(frame.samples.count)).squareRoot()
    }
}
