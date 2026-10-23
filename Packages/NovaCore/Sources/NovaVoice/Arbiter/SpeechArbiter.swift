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

/// Minimal arbiter for M1 (F-08, T-022): barge-in qualification, flush-then-notify order, R4/R5 and
/// R1 (guidance) for the reply decision. R0, R6 and R6a come with navigation (T-052). Single owner (I-10).
public struct SpeechArbiter: Sendable {
    public private(set) var epoch: Epoch
    public private(set) var focus = AudioFocus.held
    public private(set) var replyPlaying = false
    public private(set) var guidanceSpeaking = false

    public init(epoch: Epoch = .initial) { self.epoch = epoch }

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

    /// A new reply may claim focus again after a permanent loss (the driver spoke to her).
    public mutating func regainFocus() { focus = .held }
}
