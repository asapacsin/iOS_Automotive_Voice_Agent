import NovaKit
import NovaPorts

/// `I/ReconnectPolicy.kt` (contracts/voice-agent.md §8): 5 attempts, 200 ms doubling to an 8 s cap,
/// retryable codes only. The count resets once a connection is set up again.
public struct ReconnectPolicy: Sendable, Hashable {
    public enum Decision: Sendable, Hashable {
        case retry(attempt: Int, after: NovaDuration)
        case giveUp
    }

    public private(set) var attempts = 0
    private let tuning: ReconnectTuning

    public init(tuning: ReconnectTuning = ReconnectTuning()) {
        self.tuning = tuning
    }

    public mutating func next(after error: RealtimeErrorCode) -> Decision {
        guard error.isRetryable, attempts < tuning.maxAttempts else { return .giveUp }
        attempts += 1
        return .retry(attempt: attempts, after: tuning.delay(beforeAttempt: attempts))
    }

    public mutating func reset() { attempts = 0 }
}
