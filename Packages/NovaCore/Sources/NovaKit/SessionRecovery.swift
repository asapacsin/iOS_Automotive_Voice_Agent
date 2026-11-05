/// F-24 §15 item 8 (T-016j): the last retryable code before giving up. Only retryable codes give up this way
/// (terminal ones go to ERROR), so the raw values equal `RealtimeErrorCode`'s retryable ones.
public enum RetryableErrorCode: String, Sendable, Hashable, CaseIterable {
    case disconnect = "DISCONNECT"
    case connection = "CONNECTION"
    case dns = "DNS"
    case timeout = "TIMEOUT"
    case wsFailed = "WS_FAILED"
    case tlsFailed = "TLS_FAILED"
    case unavailable = "UNAVAILABLE"
    case resumeUnavailable = "RESUME_UNAVAILABLE"
    case connectionClosed = "CONNECTION_CLOSED"
}

/// F-24 §15 item 8: how the first session after a give-up (or the offline cap) used the kept handle.
public enum SessionResumeResult: String, Sendable, Hashable, CaseIterable {
    case resumed, rejected, none
}
