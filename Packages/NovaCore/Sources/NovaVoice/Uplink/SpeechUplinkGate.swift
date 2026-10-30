import Foundation
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

/// F-04 §14: why an utterance was not sent to the model.
public enum MuteReason: String, Sendable, Hashable {
    case reply, guidance, echoTail, none
}

/// F-04 §14 item 7: how an utterance ended.
public enum UtteranceEnd: String, Sendable, Hashable {
    case silence, cutAtUnmute, stopPhrase, streamEnd
}

/// F-04 §14 item 7: one line per utterance, numbers and enums only (no audio, no words; I-8).
public struct UtteranceRecord: Sendable, Hashable {
    public var id: Int
    public var startMs: Int64
    public var endMs: Int64
    public var endReason: UtteranceEnd
    public var sentToModel: Bool
    public var muteReason: MuteReason
    public var peakDb: Int
    public var noiseFloorDb: Int
    public var classifierMax: Double

    /// `utterance 3 start=1200 end=2950 endReason=silence sentToModel=true muteReason=none peakDb=71 ...`
    public var logLine: String {
        "utterance \(id) start=\(startMs) end=\(endMs) endReason=\(endReason.rawValue) sentToModel=\(sentToModel) "
            + "muteReason=\(muteReason.rawValue) peakDb=\(peakDb) noiseFloorDb=\(noiseFloorDb) "
            + "classifierMax=\((classifierMax * 100).rounded() / 100)"
    }
}

public enum UplinkGateOutput: Sendable, Hashable {
    /// F-04 §14 item 1: the one decision whether this utterance goes to the model. Everything of a not-sent
    /// utterance (audio, activity marks, the driver turn, the reply clock) is dropped by whoever follows it.
    case speechStarted(sentToModel: Bool)
    /// A frame to upload. Pre-roll frames come first after `speechStarted`.
    case audio(PCMFrame16k)
    case speechStopped(SegmentVerdict)
    /// After the closing silence: send `audioStreamEnd`.
    case streamEnd
    /// F-04 §14 item 7: the utterance that just ended, for the log.
    case utterance(UtteranceRecord)
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
    /// F-04 §14: her reply / guidance is playing (written by the shell when playback starts and stops, under the
    /// same lock as `process`), and how much echo tail is left after it.
    public private(set) var replyPlaying = false
    public private(set) var guidancePlaying = false
    /// The echo tail follows her reply (not only guidance): the stop-phrase window stays open through it.
    private var tailAfterReply = false
    private var echoTailLeft = NovaDuration.zero
    /// The open utterance: sent to the model or not, why, and its numbers for the log line.
    private var sending = true
    private var utteranceMute = MuteReason.none
    private var utteranceID = 0
    private var utteranceStart = NovaDuration.zero
    private var utterancePeak = 0.0
    private var utteranceClassifierMax = 0.0
    /// The last `preRoll` of frames while open, so a cut at unmute starts with its pre-roll.
    private var openTail: [PCMFrame16k] = []
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

    /// F-04 §14 item 2: muted while she talks and for the echo tail; never before any audio of hers.
    public var muteReason: MuteReason {
        if replyPlaying { return .reply }
        if guidancePlaying { return .guidance }
        return echoTailLeft > .zero ? .echoTail : .none
    }

    /// F-08 §14 item 3 (T-022a): the keyword spotter is fed only while her reply plays and through its echo tail;
    /// guidance alone never opens it (别说了 does not stop guidance).
    public var stopPhraseWindow: Bool { replyPlaying || (echoTailLeft > .zero && tailAfterReply) }

    /// F-04 §14 item 3: playback state, set when her reply or guidance starts or stops sounding.
    public mutating func setPlaying(reply: Bool? = nil, guidance: Bool? = nil) {
        let wasAudible = replyPlaying || guidancePlaying
        let wasReply = replyPlaying
        if let reply { replyPlaying = reply }
        if let guidance { guidancePlaying = guidance }
        if wasAudible, !replyPlaying, !guidancePlaying {
            echoTailLeft = tuning.echoTail
            tailAfterReply = wasReply
        }
        if replyPlaying || guidancePlaying { echoTailLeft = .zero }
    }

    public mutating func process(_ frame: PCMFrame16k) -> [UplinkGateOutput] {
        let rms = Self.rms(frame)
        let warmingUp = elapsed < tuning.warmUp
        elapsed = elapsed + Self.frameDuration
        if !replyPlaying, !guidancePlaying, echoTailLeft > .zero {
            echoTailLeft = max(.zero, echoTailLeft - Self.frameDuration)
        }
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
            utterancePeak = max(utterancePeak, rms)
            if let p = lastSpeechProbability { utteranceClassifierMax = max(utteranceClassifierMax, p) }
            // F-04 §14 item 2: she stopped while a muted utterance is open; cut it here and start a sent one.
            if !sending, muteReason == .none { return cutAtUnmute(frame) }
            openTail.append(frame)
            let keep = Int(tuning.preRoll.milliseconds / Self.frameDuration.milliseconds)
            if openTail.count > keep { openTail.removeFirst(openTail.count - keep) }
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
        return close(.streamEnd)
    }

    /// F-04 §14 item 2: the muted part ends unsent; a fresh utterance starts at this frame with its pre-roll.
    private mutating func cutAtUnmute(_ frame: PCMFrame16k) -> [UplinkGateOutput] {
        let ended: [UplinkGateOutput] = [.speechStopped(verdict()), .utterance(record(.cutAtUnmute))]
        let preRoll = openTail
        openTail.removeAll(keepingCapacity: true)
        openRMS.removeAll(keepingCapacity: true)
        segmentLength = Self.frameDuration
        segmentVoiced = Self.frameDuration
        trailingUnvoiced = .zero
        hangover = .zero
        beginUtterance()
        return ended + [.speechStarted(sentToModel: sending)] + preRoll.map(UplinkGateOutput.audio) + [.audio(frame)]
    }

    private mutating func beginUtterance() {
        utteranceID += 1
        utteranceMute = muteReason
        sending = utteranceMute == .none
        utteranceStart = elapsed
        utterancePeak = 0
        utteranceClassifierMax = lastSpeechProbability ?? 0
    }

    private func record(_ end: UtteranceEnd) -> UtteranceRecord {
        UtteranceRecord(id: utteranceID, startMs: utteranceStart.milliseconds, endMs: elapsed.milliseconds,
                        endReason: end, sentToModel: sending, muteReason: utteranceMute,
                        peakDb: Self.decibels(utterancePeak), noiseFloorDb: Self.decibels(noiseRMS),
                        classifierMax: utteranceClassifierMax)
    }

    /// dB relative to full scale, offset so that full scale is 96 (as 音频测试 shows it).
    static func decibels(_ rms: Double) -> Int { Int((20 * log10(max(rms, 1) / 32_768) + 96).rounded()) }

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
        openTail = Array(preRoll.suffix(Int(tuning.preRoll.milliseconds / Self.frameDuration.milliseconds)))
        preRoll.removeAll(keepingCapacity: true)
        clearConfirming()
        beginUtterance()
        return [.speechStarted(sentToModel: sending)] + frames
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
        return hangover >= tuning.hangover ? out + close(.silence) : out
    }

    private mutating func close(_ end: UtteranceEnd) -> [UplinkGateOutput] {
        phase = .closed
        let verdict = verdict()
        let silenceFrames = Int(tuning.closingSilence.milliseconds / Self.frameDuration.milliseconds)
        onset = .zero
        hangover = .zero
        openTail.removeAll(keepingCapacity: true)
        return [.speechStopped(verdict), .utterance(record(end))]
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
