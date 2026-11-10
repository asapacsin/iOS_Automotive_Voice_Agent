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
    /// F-08 §15 item 5: the empty activity that tells Gemini the reply ended; its `interrupted` after `ms`, or none in 1 s.
    case stopSyncSent
    case stopSyncInterrupted(ms: Int)
    case stopSyncNoInterrupt
    /// F-08 §15 item 3: the no-answer clock of the stop phrase's utterance did not run.
    case reaskSuppressed
    /// F-08 §15 item 4: a new sent utterance cleared the transcript stop's `abandonNextTurn`.
    case abandonCleared
    /// F-08 §16 item 3: Gemini opened a turn after a stop with no utterance sent since; it is not spoken.
    case postStopTurnDropped
    /// F-08 §17 item 11 (T-022e): confirmed new words ended her reply (setting on).
    case bargeInStopped
    /// F-18 §15 item 8: `google_search` came as an ordinary function call; it is refused, not executed.
    case webSearchAsFunction
    /// F-18 §21 item 7 (T-046i): a destination note went to the model. No name (I-8).
    case destinationNote
    /// F-05a §13 item 5 (T-016i): conversation text failed the screen check and was not shown. No words (I-8).
    case screenHidden(kind: ScreenTextKind)
    /// F-01 §14 item 12 (T-060a): the wake listener heard 你好小诺. No words, no audio (I-8).
    case wakeDetected
    /// F-24 §15 item 8 (T-016j): the 60 s retry window ended and the session closed. Numbers and a code only.
    case sessionGaveUp(ms: Int, attempts: Int, code: RetryableErrorCode)
    /// F-24 §15 item 8: the first setup after a give-up; whether a kept handle was sent (never the handle, I-7).
    case sessionResume(handle: Bool, result: SessionResumeResult)
    /// F-07 §15 item 8 (T-020b): a disproven claim cut Gemini audio already playing; `playedMs` of it was heard.
    case claimCut(turn: Int, playedMs: Int)
    /// F-05a §15 item 7 (T-016m): `lang-check turn= verdict= lang= p= held_ms=`; `percent` is p × 100.
    case langCheck(turn: Int, verdict: LangCheckVerdict, lang: LanguageTag?, percent: Int, heldMs: Int)
    /// F-05a §15 item 7: `correction WRONG_LANGUAGE heard=<sensevoice|none>`.
    case wrongLanguage(heard: Bool)
    /// F-05a §15 item 7: `fallback-line turn= reason=`.
    case fallbackLine(turn: Int, reason: FallbackLineReason)
    /// F-18 §27 item 4 (T-020c): a background tool's result was not sent because the socket was replaced.
    case asyncToolDropped(tool: AsyncTool)
}

/// F-18 §27 item 1 (T-020c): the functions declared to Gemini Live as `NON_BLOCKING`; every other one blocks.
public enum AsyncTool: String, Sendable, Hashable, CaseIterable {
    case webSearch = "web_search"
    case queryLiveInfo = "query_live_info"

    public init?(name: String) { self.init(rawValue: name) }
    /// The `scheduling` their response carries (F-18 §27 item 3).
    public static let scheduling = "WHEN_IDLE"
}

/// F-05a §13 item 2: which conversation text the screen check hid.
public enum ScreenTextKind: String, Sendable, Hashable, CaseIterable {
    case driver, reply, guidance, camera
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
        case stopSyncSent
        case stopSyncInterrupted
        case stopSyncNoInterrupt
        case reaskSuppressed
        case abandonCleared
        case postStopTurnDropped
        case bargeInStopped
        case webSearchAsFunction
        case destinationNote
        case screenHidden
        case wakeDetected
        case sessionGaveUp
        case sessionResume
        case claimCut
        case asyncToolDropped
        case langCheck
        case wrongLanguage
        case fallbackLine
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
        case .stopSyncSent: .stopSyncSent
        case .stopSyncInterrupted: .stopSyncInterrupted
        case .stopSyncNoInterrupt: .stopSyncNoInterrupt
        case .reaskSuppressed: .reaskSuppressed
        case .abandonCleared: .abandonCleared
        case .postStopTurnDropped: .postStopTurnDropped
        case .bargeInStopped: .bargeInStopped
        case .webSearchAsFunction: .webSearchAsFunction
        case .destinationNote: .destinationNote
        case .screenHidden: .screenHidden
        case .wakeDetected: .wakeDetected
        case .sessionGaveUp: .sessionGaveUp
        case .sessionResume: .sessionResume
        case .claimCut: .claimCut
        case .asyncToolDropped: .asyncToolDropped
        case .langCheck: .langCheck
        case .wrongLanguage: .wrongLanguage
        case .fallbackLine: .fallbackLine
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
        case .stopSyncSent: "stopSync sent"
        case .stopSyncInterrupted(let ms): "stopSync interrupted ms=\(ms)"
        case .stopSyncNoInterrupt: "stopSyncNoInterrupt"
        case .destinationNote: "destinationNote"
        case .screenHidden(let kind): "screenHidden kind=\(kind.rawValue)"
        case .reaskSuppressed: "reaskSuppressed reason=stop"
        case .abandonCleared: "abandonCleared reason=newUtterance"
        case .postStopTurnDropped: "postStopTurnDropped reason=noSentUtterance"
        case .bargeInStopped: "bargeInStopped"
        case .wakeDetected: "wakeDetected"
        case .sessionGaveUp(let ms, let n, let code): "session gave-up ms=\(ms) attempts=\(n) code=\(code.rawValue)"
        case .sessionResume(let handle, let result): "session resume handle=\(handle ? "yes" : "no") result=\(result.rawValue)"
        case .claimCut(let turn, let ms): "claim-cut turn=\(turn) played_ms=\(ms)"
        case .asyncToolDropped(let tool): "tool-result \(tool.rawValue) dropped reason=reconnect"
        case .langCheck(let turn, let verdict, let lang, let percent, let held):
            "lang-check turn=\(turn) verdict=\(verdict.rawValue) lang=\(lang?.code ?? "none") p=\(LanguageTag.probability(percent)) held_ms=\(held)"
        case .wrongLanguage(let heard): "correction WRONG_LANGUAGE heard=\(heard ? "sensevoice" : "none")"
        case .fallbackLine(let turn, let reason): "fallback-line turn=\(turn) reason=\(reason.rawValue)"
        default: "diagnostic \(self)"
        }
    }
}

/// Destination for diagnostic events (os.Logger in production, recording sink in tests).
public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticEvent)
}

/// F-05a §15 item 7: the verdict a `lang-check` line reports (`released`: the 800 ms hold ran out first).
public enum LangCheckVerdict: String, Sendable, Hashable {
    case allowed, blocked, released
}

/// F-05a §15 item 7: why the app said its own fallback line.
public enum FallbackLineReason: String, Sendable, Hashable {
    case blockedAgain = "blocked_again"
    case noReply = "no_reply"
}

/// F-05a §15 item 7: a detector's language code as a code, not a `String` (diagnostics carry no text). Only
/// BCP-47 characters (`a-z`, `A-Z`, `0-9`, `-`), at most 8 of them; anything else is not a code.
public struct LanguageTag: Sendable, Hashable {
    private let packed: UInt64

    public init?(_ code: String) {
        let bytes = Array(code.utf8)
        guard (1...8).contains(bytes.count),
              bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D })
        else { return nil }
        packed = bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    public var code: String {
        var bytes: [UInt8] = []
        var rest = packed
        while rest != 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `p=0.85` from 85.
    public static func probability(_ percent: Int) -> String {
        let p = max(0, min(100, percent))
        return "\(p / 100).\(p % 100 < 10 ? "0" : "")\(p % 100)"
    }
}
