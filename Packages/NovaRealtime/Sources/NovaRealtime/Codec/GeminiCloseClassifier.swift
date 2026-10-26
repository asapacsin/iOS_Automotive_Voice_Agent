import NovaPorts

/// Maps a WebSocket close to a classified error (contracts/api-contracts.md, Gemini close codes;
/// contracts/voice-agent.md §8). Returns nil for a normal close.
public enum GeminiCloseClassifier {
    public static func classify(code: Int, reason: String, resumedSetup: Bool) -> RealtimeErrorCode? {
        let text = reason.lowercased()
        switch code {
        case 1000:
            return nil
        case 1007:
            // On a resumed setup the handle is no longer usable; otherwise the setup itself was rejected
            // (recorded: thinkingLevel MINIMAL → "Thinking level is not supported for this model.").
            return resumedSetup ? .resumeUnavailable : .malformed
        case 1008:
            if text.contains("api key") || text.contains("permission") || text.contains("unauthenticated") {
                return .auth
            }
            if text.contains("quota") { return .quota }
            if text.contains("rate") && text.contains("limit") { return .rateLimited }
            if text.contains("model") && text.contains("not found") { return .invalidModel }
            // Recorded: an unknown handle closes 1008 "BidiGenerateContent session not found".
            if resumedSetup && text.contains("session not found") { return .resumeUnavailable }
            return .connectionClosed
        case 1011, 1013:
            return .unavailable
        default:
            return .disconnect
        }
    }

    /// A refused upgrade (no 101). PROPOSED: 401/403 is a bad key (terminal, like a 1008 auth close),
    /// 429 is rate limiting, 5xx is a retryable outage; anything else is a retryable connection error.
    public static func classify(handshakeStatus status: Int) -> RealtimeErrorCode {
        switch status {
        case 401, 403: return .auth
        case 429: return .rateLimited
        case 500...599: return .unavailable
        default: return .connection
        }
    }
}
