import NovaKit
import NovaPorts

/// Reply decision (contracts/voice-agent.md §5, `A/voice/SpeechArbiter.kt`).
public enum ReplyDecision: String, Sendable, Hashable { case play, hold, drop }

/// Audio focus as iOS reports it (ios-architecture §6.6): an interruption or a lost route
/// (`oldDeviceUnavailable`) is a transient loss (R5, hold and re-evaluate); reset media services or an
/// interruption that may not resume is permanent (R4).
public enum AudioFocus: Sendable, Hashable { case held, transientLoss, permanentLoss }

public enum ArbiterInput: Sendable, Hashable {
    /// Local VAD onset. `recentSpeech` is `SpeechUplinkGate.hasRecentSpeech` at that moment.
    case speechStarted(recentSpeech: Bool)
    case replyPlaying(Bool)
    case guidanceSpeaking(Bool)
    case audioSession(AudioSessionEvent)
}

public enum ArbiterEffect: Sendable, Hashable {
    /// Stop the reply lane and raise the epoch. Always before `cancelRevoicing` and `notifyProvider`.
    case flushPlayback(Epoch)
    case cancelRevoicing(Epoch)
    /// Tell the session (VoiceSession `.bargeIn`). Gemini has no client cancel; its server sends `interrupted`.
    case bargeIn(qualified: Bool)
}

/// Arbiter (F-08): barge-in qualification, flush-then-notify order, R4/R5 and R1 (T-022), and with
/// navigation R6, R6a and the uplink rules R0 / tail / 20 s cap (T-052). Single owner (I-10).
public struct SpeechArbiter: Sendable {
    public let tuning: ArbiterTuning
    public private(set) var epoch: Epoch
    public private(set) var focus = AudioFocus.held
    public private(set) var replyPlaying = false
    public private(set) var guidanceSpeaking = false
    public private(set) var navigating = false
    /// R6: while navigating she speaks only inside this window after the driver spoke.
    public private(set) var permittedUntil: NovaInstant?
    /// The current reply has had a clause released: R6 and R6a judge only an unstarted reply.
    public private(set) var replyStarted = false
    /// R6 judged the current reply when it was first ready and let it through; a later hold does not
    /// make it unprompted.
    private var replyAdmitted = false
    /// R6a: distance to the next manoeuvre, and the hold in progress.
    public private(set) var manoeuvreDistance: Int?
    private var workloadHold: (since: NovaInstant, distance: Int)?
    /// Uplink: when guidance began and ended, whether the driver was mid-utterance then (R0).
    private var driverSpeaking = false
    private var guidanceSince: NovaInstant?
    private var guidanceEndedAt: NovaInstant?
    private var midUtteranceAtGuidance = false
    private var uplinkClosedSince: NovaInstant?

    public init(epoch: Epoch = .initial, tuning: ArbiterTuning = ArbiterTuning()) {
        self.epoch = epoch
        self.tuning = tuning
    }

    /// R4 permanent focus loss → DROP; R1 guidance speaking → HOLD; R5 transient loss → HOLD; else PLAY.
    public var reply: ReplyDecision {
        if focus == .permanentLoss { return .drop }
        if guidanceSpeaking { return .hold }
        if focus == .transientLoss { return .hold }
        return .play
    }

    public mutating func handle(_ input: ArbiterInput) -> [ArbiterEffect] {
        switch input {
        case .speechStarted(let recentSpeech):
            guard replyPlaying else { return [] }
            // `playoutBargeInQualified(recentSpeech)`: only time-scoped evidence that somebody speaks now.
            // The diagnostic is the session's (VoiceSession logs `.bargeIn`), so it is not emitted here.
            guard recentSpeech else { return [.bargeIn(qualified: false)] }
            epoch = epoch.next()
            replyPlaying = false
            // Contract ordering rule 3: flush playback first, then notify.
            return [.flushPlayback(epoch), .cancelRevoicing(epoch), .bargeIn(qualified: true)]
        case .replyPlaying(let playing):
            replyPlaying = playing
            return []
        case .guidanceSpeaking(let speaking):
            guidanceSpeaking = speaking
            if !speaking { guidanceSince = nil }
            return []
        case .audioSession(let event):
            switch event {
            case .interruptionBegan: focus = .transientLoss
            case .interruptionEnded(let shouldResume): focus = shouldResume ? .held : .permanentLoss
            case .routeLost: focus = .transientLoss
            // Re-evaluate on the new route (§6.6): a hold from a lost route ends; R4 stays until regained.
            case .routeAvailable: if focus == .transientLoss { focus = .held }
            case .mediaServicesReset: focus = .permanentLoss
            }
            // A lost focus stops the reply in progress; the reply decision covers what comes next.
            guard focus == .permanentLoss, replyPlaying else { return [] }
            epoch = epoch.next()
            replyPlaying = false
            return [.flushPlayback(epoch), .cancelRevoicing(epoch)]
        }
    }

    /// A voided reply (F-06): nothing of it may still play, so the epoch moves on as for a barge-in.
    public mutating func void() -> [ArbiterEffect] {
        epoch = epoch.next()
        replyPlaying = false
        return [.flushPlayback(epoch), .cancelRevoicing(epoch)]
    }

    /// A new reply may claim focus again after a permanent loss (the driver spoke to her).
    public mutating func regainFocus() { focus = .held }

    // MARK: Navigation rules (T-052)

    public mutating func setNavigating(_ value: Bool) {
        navigating = value
        if !value {
            manoeuvreDistance = nil
            workloadHold = nil
        }
    }

    /// The driver finished an utterance: R6 permits her to answer for the next 10 s.
    public mutating func driverSpoke(at now: NovaInstant) {
        permittedUntil = now + tuning.navigatingPermittedWindow
    }

    /// A new model reply opened; R6 and R6a judge it afresh.
    public mutating func newReply() {
        replyStarted = false
        replyAdmitted = false
        workloadHold = nil
    }

    /// A clause of the current reply went to the revoicer.
    public mutating func markReplyStarted() { replyStarted = true }

    public mutating func setManoeuvreDistance(_ meters: Int?) { manoeuvreDistance = meters }

    /// The full reply decision at `now`, highest rule first (contracts/voice-agent.md §5).
    /// `exempt` is a guidance reading (F-14): the relay itself decided she may speak, so R6 and R6a do not
    /// apply to it. Returns the decision and, for a timed hold, when to ask again.
    public mutating func decide(at now: NovaInstant, exempt: Bool = false) -> (ReplyDecision, wake: NovaInstant?) {
        if focus == .permanentLoss { return (.drop, nil) }
        if navigating, !exempt, !replyStarted, !replyAdmitted {
            if permittedUntil.map({ now > $0 }) ?? true { return (.drop, nil) }
            replyAdmitted = true
        }
        if guidanceSpeaking { return (.hold, nil) }
        // R1 lasts until the 500 ms tail after guidance has passed.
        if let ended = guidanceEndedAt, now < ended + tuning.guidanceTail { return (.hold, ended + tuning.guidanceTail) }
        if focus == .transientLoss { return (.hold, nil) }
        if navigating, !exempt, !replyStarted, let distance = manoeuvreDistance {
            if let hold = workloadHold {
                // Released by time, or by the distance jumping (the manoeuvre is behind us).
                let expires = hold.since + tuning.workloadHoldMax
                if now >= expires || distance > hold.distance + tuning.workloadDistanceJumpMeters {
                    workloadHold = nil
                    replyStarted = true
                    return (.play, nil)
                }
                // The jump is measured from the closest point seen: approaching does not count.
                workloadHold = (hold.since, min(hold.distance, distance))
                return (.hold, expires)
            }
            if distance <= tuning.workloadHoldRadiusMeters {
                workloadHold = (now, distance)
                return (.hold, now + tuning.workloadHoldMax)
            }
        }
        return (.play, nil)
    }

    // MARK: Uplink (R0, tail, cap)

    public mutating func driverSpeech(_ speaking: Bool) { driverSpeaking = speaking }

    /// Guidance started or ended at `now` (fallback voice on the guidance lane).
    public mutating func guidance(_ speaking: Bool, at now: NovaInstant) {
        guidanceSpeaking = speaking
        if speaking {
            if guidanceSince == nil { midUtteranceAtGuidance = driverSpeaking }
            guidanceSince = guidanceSince ?? now
            guidanceEndedAt = nil
        } else {
            guidanceSince = nil
            guidanceEndedAt = now
        }
    }

    /// Whether the uplink may send at `now`, and the next instant the answer can change by itself.
    /// Closed while guidance sounds and for the 500 ms tail after it; R0 keeps an utterance that was
    /// already open when guidance began for up to 8 s; never closed longer than 20 s in one go.
    public mutating func uplink(at now: NovaInstant) -> (open: Bool, wake: NovaInstant?) {
        // `reopen` nil while guidance still sounds (no end known yet).
        let reopen: NovaInstant?
        if let since = guidanceSince {
            let keepOpen = since + tuning.driverMidUtteranceKeepOpen
            if midUtteranceAtGuidance, now < keepOpen { return (true, keepOpen) }
            reopen = nil
        } else if let ended = guidanceEndedAt, now < ended + tuning.guidanceTail {
            reopen = ended + tuning.guidanceTail
        } else {
            uplinkClosedSince = nil
            return (true, nil)
        }
        let closedSince = uplinkClosedSince ?? now
        uplinkClosedSince = closedSince
        let cap = closedSince + tuning.uplinkMaxClosed
        if now >= cap { return (true, nil) }
        return (false, reopen.map { min($0, cap) } ?? cap)
    }
}
