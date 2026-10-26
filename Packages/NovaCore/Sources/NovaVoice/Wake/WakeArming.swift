import NovaKit
import NovaPorts

/// Where captured frames go (ios-architecture §5.2 `MicRoute`): one capture, one consumer (ADR-006).
public enum MicRoute: Sendable, Hashable {
    /// Idle: the wake detector listens.
    case wake
    /// A session runs: the uplink gate gets every frame.
    case uplink
    /// Neither (wake unavailable and no session, or the app is backgrounded without a session).
    case none
}

public enum WakeDecision: Sendable, Hashable {
    /// SLEEP → ACTIVE on the same connection.
    case resume
    /// DEEP_IDLE → ACTIVE with a new session.
    case startSession
    case ignore
}

/// F-01 wake arming and the mic router (T-061, `A/wake/WakeArming.kt:13-19`). Pure.
/// A wake counts only while armed (SLEEP or DEEP_IDLE, nothing starting); the first one disarms until
/// the lifecycle is idle again, so a late or duplicate callback never starts a second session.
public struct WakeArming: Sendable {
    public private(set) var listening: ListeningState = .deepIdle
    public private(set) var wakeAvailable = true
    /// A wake was accepted and the session has not reached ACTIVE yet.
    public private(set) var starting = false

    public init() {}

    public var armed: Bool { wakeAvailable && !starting && (listening == .sleep || listening == .deepIdle) }

    public var route: MicRoute {
        if listening == .sleep || listening == .deepIdle { return starting ? .uplink : (wakeAvailable ? .wake : .none) }
        return .uplink
    }

    public mutating func lifecycle(_ state: ListeningState) {
        listening = state
        if state == .active || state == .silentWait { starting = false }
    }

    /// The session start failed (e.g. config error): wake may be tried again.
    public mutating func startFailed() { starting = false }

    public mutating func detector(_ event: WakeEvent) -> WakeDecision {
        switch event {
        case .wake:
            guard armed else { return .ignore }
            starting = true
            return listening == .sleep ? .resume : .startSession
        case .unavailable:
            wakeAvailable = false
            return .ignore
        case .ready:
            wakeAvailable = true
            return .ignore
        case .failed:
            return .ignore
        }
    }

    /// The assistant button: the same path as a wake, so it works even when wake is unavailable.
    public mutating func tap() -> WakeDecision {
        guard !starting, listening == .sleep || listening == .deepIdle else { return .ignore }
        starting = true
        return listening == .sleep ? .resume : .startSession
    }
}

/// F-01 §8 bounded retry for engine init and capture failures: 1.5 s doubling to 30 s, 6 attempts.
public struct BoundedRetry: Sendable, Hashable {
    public let tuning: WakeRetryTuning
    public private(set) var failures = 0

    public init(tuning: WakeRetryTuning = WakeRetryTuning()) { self.tuning = tuning }

    /// Records a failure; returns the delay before the next attempt, or nil when attempts are spent
    /// (wake is unavailable; the button still works).
    public mutating func failed() -> NovaDuration? {
        failures += 1
        guard failures < tuning.attempts else { return nil }
        var delay = tuning.base
        for _ in 1..<failures { delay = min(delay * 2, tuning.max) }
        return delay
    }

    public mutating func succeeded() { failures = 0 }
}
