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
    case timerFired(stale: Bool)
    case sessionError(SessionErrorCode)
}

/// Destination for diagnostic events (os.Logger in production, recording sink in tests).
public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticEvent)
}
