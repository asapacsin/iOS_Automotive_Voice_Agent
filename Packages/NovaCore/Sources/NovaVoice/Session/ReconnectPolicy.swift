import NovaKit
import NovaPorts

/// `I/ReconnectPolicy.kt` (contracts/voice-agent.md §8) as changed by F-24 §15 item 1: retryable codes only,
/// 200 ms doubling to an 8 s cap, no attempt limit, for `retryWindow` (60 s) after the first failure. An attempt
/// is made only if it starts before the window ends. A completed setup (`reset`) clears the window.
public struct ReconnectPolicy: Sendable, Hashable {
    public enum Decision: Sendable, Hashable {
        case retry(attempt: Int, after: NovaDuration)
        case giveUp
    }

    public private(set) var attempts = 0
    /// When the first failure of this window happened; nil while connected.
    public private(set) var firstFailure: NovaInstant?
    private let tuning: ReconnectTuning

    public init(tuning: ReconnectTuning = ReconnectTuning()) {
        self.tuning = tuning
    }

    public mutating func next(after error: RealtimeErrorCode, at now: NovaInstant) -> Decision {
        guard error.isRetryable else { return .giveUp }
        let first = firstFailure ?? now
        firstFailure = first
        let delay = tuning.delay(beforeAttempt: attempts + 1)
        guard now + delay < first + tuning.retryWindow else { return .giveUp }
        attempts += 1
        return .retry(attempt: attempts, after: delay)
    }

    /// Milliseconds since the window's first failure (0 when there is none).
    public func msSinceFirstFailure(at now: NovaInstant) -> Int {
        firstFailure.map { Int(max(0, (now - $0).milliseconds)) } ?? 0
    }

    public mutating func reset() {
        attempts = 0
        firstFailure = nil
    }
}
