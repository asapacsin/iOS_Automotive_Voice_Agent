/// Typed diagnostic event (I-7, I-8). Payloads are codes, counts, durations and enums only, never a
/// `String`, so a transcript, address, coordinate or key cannot be logged by construction. A unit
/// test checks that no case carries a `String`.
public enum DiagnosticEvent: Sendable, Hashable {
    case sessionState(SessionUIState)
    case listeningState(ListeningState)
    case navigationPhase(NavigationPhase)
    case reconnectAttempt(attempt: Int, delay: NovaDuration)
    case providerEventsDropped(count: Int)
    case setupTimeout
    case toolRefused(code: ToolErrorCode)
    case toolFailed(code: ToolErrorCode)
    case lateToolResultDropped(turn: TurnID)
    /// `nav_flow_late_result_dropped`
    case navLateResultDropped(stale: Generation, current: Generation)
    case staleAudioDropped(stale: Epoch, current: Epoch)
    case bargeIn(qualified: Bool)
    case claimHeld(events: Int)
    case correctionSent
    case emptyResponseReask
    /// F-04 §14 item 7: a sent driver turn got no model response; logged before the re-ask. `turn` counts the
    /// driver's sent utterances.
    case turnUnanswered(turn: Int)
    case timerFired(stale: Bool)
    case sessionError(SessionErrorCode)
    /// F-08 §14 item 7: a stop phrase stopped her. `phrase` indexes `StopPhrases.all` (-1: a transcript-only phrase);
    /// `selfStop`: no driver speech open or ended within 1 s (a false stop).
    case stopPhrase(source: StopPhraseSource, phrase: Int, msFromSpeechStart: Int, score: Int, selfStop: Bool)
    /// F-08 §14 item 7: a reply ended with an utterance during it and no stop phrase.
    case stopPhraseMiss(utterance: Int)
    /// F-24 §14 item 6: the network path went away / came back (debounced by the watcher).
    case networkLost
    case networkRestored
    /// F-24 §14 item 2: the immediate attempt when the network returns (the backoff ones are `reconnectAttempt`).
    case offlineRestoreAttempt
    /// F-24 §14 item 6: a reconnect was set up again, with or without the resumption handle.
    case resumed(handle: Bool)
    /// F-24 §14 item 4: the network stayed gone for `offlineWaitCap`; the session ended.
    case offlineCapReached
}

public enum StopPhraseSource: String, Sendable, Hashable {
    case kws, transcript
}

extension DiagnosticEvent {
    /// One tag per case, named exactly like the case. The switch is exhaustive, so a new case does not
    /// compile until it has a tag; the diagnostics test then fails until that tag has a sample.
    public enum Kind: String, Sendable, CaseIterable {
        case sessionState
        case listeningState
        case navigationPhase
        case reconnectAttempt
        case providerEventsDropped
        case setupTimeout
        case toolRefused
        case toolFailed
        case lateToolResultDropped
        case navLateResultDropped
        case staleAudioDropped
        case bargeIn
        case claimHeld
        case correctionSent
        case emptyResponseReask
        case turnUnanswered
        case timerFired
        case sessionError
        case stopPhrase
        case stopPhraseMiss
        case networkLost
        case networkRestored
        case offlineRestoreAttempt
        case resumed
        case offlineCapReached
    }

    public var kind: Kind {
        switch self {
        case .sessionState: .sessionState
        case .listeningState: .listeningState
        case .navigationPhase: .navigationPhase
        case .reconnectAttempt: .reconnectAttempt
        case .providerEventsDropped: .providerEventsDropped
        case .setupTimeout: .setupTimeout
        case .toolRefused: .toolRefused
        case .toolFailed: .toolFailed
        case .lateToolResultDropped: .lateToolResultDropped
        case .navLateResultDropped: .navLateResultDropped
        case .staleAudioDropped: .staleAudioDropped
        case .bargeIn: .bargeIn
        case .claimHeld: .claimHeld
        case .correctionSent: .correctionSent
        case .emptyResponseReask: .emptyResponseReask
        case .turnUnanswered: .turnUnanswered
        case .timerFired: .timerFired
        case .sessionError: .sessionError
        case .stopPhrase: .stopPhrase
        case .stopPhraseMiss: .stopPhraseMiss
        case .networkLost: .networkLost
        case .networkRestored: .networkRestored
        case .offlineRestoreAttempt: .offlineRestoreAttempt
        case .resumed: .resumed
        case .offlineCapReached: .offlineCapReached
        }
    }
}

extension DiagnosticEvent {
    /// The phone-log line: F-08 §14 item 7 formats for the stop-phrase lines, the case's description otherwise.
    public var logLine: String {
        switch self {
        case .stopPhrase(let source, let phrase, let ms, let score, let selfStop):
            "stopPhrase source=\(source.rawValue) phrase=\(phrase) msFromSpeechStart=\(ms) score=\(score) selfStop=\(selfStop)"
        case .stopPhraseMiss(let utterance): "stopPhraseMiss utterance=\(utterance)"
        case .reconnectAttempt(let n, let delay): "reconnectAttempt \(n) reason=backoff delay=\(delay)"
        case .offlineRestoreAttempt: "reconnectAttempt 1 reason=offlineRestore"
        case .resumed(let handle): "resumed handle=\(handle ? "yes" : "no")"
        case .networkLost: "networkLost"
        case .networkRestored: "networkRestored"
        case .offlineCapReached: "offlineCapReached"
        default: "diagnostic \(self)"
        }
    }
}

/// Destination for diagnostic events (os.Logger in production, recording sink in tests).
public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticEvent)
}
