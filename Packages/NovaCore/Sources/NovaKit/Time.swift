import Foundation
import Synchronization

/// Monotonic time in milliseconds. Android constants are milliseconds, so ported values stay readable.
public struct NovaInstant: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let milliseconds: Int64

    public init(milliseconds: Int64) { self.milliseconds = milliseconds }

    public static let zero = NovaInstant(milliseconds: 0)

    public static func < (lhs: NovaInstant, rhs: NovaInstant) -> Bool { lhs.milliseconds < rhs.milliseconds }
    public static func + (lhs: NovaInstant, rhs: NovaDuration) -> NovaInstant {
        NovaInstant(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }
    public static func - (lhs: NovaInstant, rhs: NovaDuration) -> NovaInstant {
        NovaInstant(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }
    public static func - (lhs: NovaInstant, rhs: NovaInstant) -> NovaDuration {
        NovaDuration(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }

    public var description: String { "t+\(milliseconds)ms" }
}

/// A span of time in milliseconds.
public struct NovaDuration: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let milliseconds: Int64

    public init(milliseconds: Int64) { self.milliseconds = milliseconds }

    public static let zero = NovaDuration(milliseconds: 0)
    public static func milliseconds(_ value: Int64) -> NovaDuration { NovaDuration(milliseconds: value) }
    public static func seconds(_ value: Int64) -> NovaDuration { NovaDuration(milliseconds: value * 1_000) }
    public static func minutes(_ value: Int64) -> NovaDuration { NovaDuration(milliseconds: value * 60_000) }

    public static func < (lhs: NovaDuration, rhs: NovaDuration) -> Bool { lhs.milliseconds < rhs.milliseconds }
    public static func + (lhs: NovaDuration, rhs: NovaDuration) -> NovaDuration {
        NovaDuration(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }
    public static func - (lhs: NovaDuration, rhs: NovaDuration) -> NovaDuration {
        NovaDuration(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }
    public static func * (lhs: NovaDuration, rhs: Int64) -> NovaDuration {
        NovaDuration(milliseconds: lhs.milliseconds * rhs)
    }

    public var description: String { "\(milliseconds)ms" }
}

/// Injected time source. Production uses `SystemClock`; tests use `ManualClock`.
public protocol NovaClock: Sendable {
    var now: NovaInstant { get }
    /// Suspends until `deadline`. Throws `CancellationError` if the task is cancelled first.
    func sleep(until deadline: NovaInstant) async throws
}

/// Monotonic clock backed by `ContinuousClock`; `now` counts from the clock's creation.
public struct SystemClock: NovaClock {
    private let origin: ContinuousClock.Instant

    public init() { origin = ContinuousClock.now }

    public var now: NovaInstant {
        let elapsed = ContinuousClock.now - origin
        let parts = elapsed.components
        return NovaInstant(milliseconds: parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    public func sleep(until deadline: NovaInstant) async throws {
        let remaining = deadline - now
        if remaining > .zero {
            try await Task.sleep(for: .milliseconds(remaining.milliseconds))
        }
    }
}

/// Test clock. Time moves only when `advance(by:)` or `advance(to:)` is called.
public final class ManualClock: NovaClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: NovaInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: NovaInstant
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Ids allocated whose continuation is not registered yet; both sets empty out as sleeps end.
        var unregistered: Set<UInt64> = []
        var cancelledBeforeRegistration: Set<UInt64> = []
    }

    private let state: Mutex<State>

    public init(start: NovaInstant = .zero) {
        state = Mutex(State(now: start))
    }

    public var now: NovaInstant { state.withLock { $0.now } }

    /// Number of tasks currently suspended in `sleep(until:)`.
    public var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    /// Bookkeeping entries still held; 0 once every sleep has finished (tests guard against leaks).
    public var retainedBookkeeping: Int {
        state.withLock { $0.unregistered.count + $0.cancelledBeforeRegistration.count }
    }

    public func sleep(until deadline: NovaInstant) async throws {
        let id = state.withLock { s -> UInt64 in
            s.nextID += 1
            s.unregistered.insert(s.nextID)
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case resume, cancel, wait }
                let outcome = state.withLock { s -> Outcome in
                    s.unregistered.remove(id)
                    if s.cancelledBeforeRegistration.remove(id) != nil { return .cancel }
                    if s.now >= deadline { return .resume }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let index = s.sleepers.firstIndex(where: { $0.id == id }) {
                    return s.sleepers.remove(at: index).continuation
                }
                // Already resumed or failed: nothing to cancel, nothing to remember.
                if s.unregistered.contains(id) { s.cancelledBeforeRegistration.insert(id) }
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: NovaDuration) {
        advance(to: now + duration)
    }

    /// Moves time forward and resumes every sleeper whose deadline has passed, earliest first.
    public func advance(to instant: NovaInstant) {
        let due = state.withLock { s -> [Sleeper] in
            if instant > s.now { s.now = instant }
            let now = s.now
            let ready = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
