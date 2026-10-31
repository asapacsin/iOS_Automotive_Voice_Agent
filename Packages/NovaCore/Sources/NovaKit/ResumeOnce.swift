import Synchronization

/// F-05 §14 item 1: a checked continuation that an Apple or vendor callback may answer more than once. The first
/// answer resumes it; every later one is dropped (returns false) instead of crashing. Thread-safe from any queue.
public final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    public init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    @discardableResult
    public func resume(returning value: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: value)
        return true
    }

    @discardableResult
    public func resume(throwing error: any Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: error)
        return true
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        continuation.withLock { c in
            defer { c = nil }
            return c
        }
    }
}

extension ResumeOnce where T == Void {
    @discardableResult
    public func resume() -> Bool { resume(returning: ()) }

    /// A completion handler's `Error?`: nil is success.
    @discardableResult
    public func resume(with error: (any Error)?) -> Bool {
        if let error { resume(throwing: error) } else { resume() }
    }
}

/// Where a duplicate callback was dropped: the `site=` of the `duplicateCallback` log line (F-05 §14 items 2–3).
public enum CallbackSite: String, Sendable, Hashable {
    case ping, guidanceVoice, phoneDial

    public var logLine: String { "duplicateCallback site=\(rawValue)" }
}
