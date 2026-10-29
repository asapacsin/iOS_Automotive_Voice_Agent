import NovaKit
import Synchronization

/// F-16a (T-042a): the platform-free state machine behind the device location provider: first-fix wait,
/// freshness, permission changes and background pause/resume. The CoreLocation adapter only forwards
/// delegate events here and performs the returned manager actions, so the logic runs under Linux tests.
public final class LocationFixState: Sendable {
    /// What the adapter must do to the location manager after an event.
    public enum ManagerAction: Sendable, Hashable {
        /// Ask When In Use (only if not determined yet) and start updates.
        case requestAndStart
        case startUpdates
        case stopUpdates
    }

    private struct State {
        var latest: LocationFix?
        var permission: LocationAuthorization
        var started = false
        var paused = false
        /// F-16b: open `updates()` streams, by subscription number.
        var subscribers: [Int: AsyncStream<LocationFix>.Continuation] = [:]
        var nextSubscriber = 0
    }

    private let clock: any NovaClock
    private let firstFixWait: NovaDuration
    private let freshness: NovaDuration
    private let pollInterval: NovaDuration
    private let state: Mutex<State>

    public init(clock: any NovaClock, permission: LocationAuthorization,
                firstFixWait: NovaDuration = TuningDefaults.firstFixWait,
                freshness: NovaDuration = AmapWebTuning().locationFresh,
                pollInterval: NovaDuration = .milliseconds(100)) {
        self.clock = clock
        self.firstFixWait = firstFixWait
        self.freshness = freshness
        self.pollInterval = pollInterval
        state = Mutex(State(permission: permission))
    }

    public var permission: LocationAuthorization { state.withLock { $0.permission } }
    public var isPaused: Bool { state.withLock { $0.paused } }
    public var latest: LocationFix? { state.withLock { $0.latest } }

    /// First need: returns `.requestAndStart` once. While paused (session began in the background) the need
    /// is recorded but nothing starts; `resume()` then asks permission and starts.
    public func start() -> ManagerAction? {
        state.withLock { s -> ManagerAction? in
            defer { s.started = true }
            return !s.started && !s.paused ? .requestAndStart : nil
        }
    }

    /// F-16a §5: background → stop updates if they were running.
    public func pause() -> ManagerAction? {
        state.withLock { s -> ManagerAction? in
            defer { s.paused = true }
            return s.started && !s.paused ? .stopUpdates : nil
        }
    }

    /// F-16a §5: foreground → restart if started and permission allows.
    public func resume() -> ManagerAction? {
        state.withLock { s -> ManagerAction? in
            defer { s.paused = false }
            // `.requestAndStart` asks When In Use only if still not determined (background start never asked).
            return s.started && s.paused && s.permission != .denied ? .requestAndStart : nil
        }
    }

    /// F-16a §7: granted → (re)start if something needed location and not paused; denied → stop and drop the last fix.
    public func authorizationChanged(_ permission: LocationAuthorization) -> ManagerAction? {
        state.withLock { s -> ManagerAction? in
            s.permission = permission
            switch permission {
            case .authorized: return s.started && !s.paused ? .startUpdates : nil
            case .denied:
                // The map drops its marker by permission; streams just get no further fix.
                s.latest = nil
                return .stopUpdates
            case .notDetermined: return nil
            }
        }
    }

    /// Re-check just before a start action reaches the manager: false once a later `pause()` won the race.
    public func mayStartUpdates() -> Bool {
        state.withLock { $0.started && !$0.paused && $0.permission != .denied }
    }

    public func receive(_ fix: LocationFix) {
        let subscribers = state.withLock { s in
            s.latest = fix
            return Array(s.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(fix) }
    }

    /// F-16b (T-044b): every fix from now on, starting with the latest one if there is one, so a screen that
    /// subscribes late still draws the position at once. Ends when the consumer stops listening.
    public func updates() -> AsyncStream<LocationFix> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self, bufferingPolicy: .bufferingNewest(1))
        // The latest fix is yielded under the lock, so a `receive` racing with this call cannot be overtaken
        // by the older fix in the one-slot buffer.
        let id = state.withLock { s in
            let id = s.nextSubscriber
            s.nextSubscriber += 1
            s.subscribers[id] = continuation
            if let latest = s.latest { continuation.yield(latest) }
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// The fix if it is within `freshness` of now.
    public func freshFix() -> LocationFix? {
        let now = clock.now
        return state.withLock { s -> LocationFix? in
            guard let latest = s.latest, now - latest.timestamp <= freshness else { return nil }
            return latest
        }
    }

    /// F-16a §4: a fresh fix at once; otherwise (permitted, not paused) wait up to `firstFixWait` for one.
    /// On timeout or cancellation the old fix (or nil) is returned and NovaNav judges it; denial returns nil.
    public func awaitFix() async -> LocationFix? {
        if let fix = freshFix() { return fix }
        let blocked = state.withLock { $0.permission == .denied || $0.paused }
        if blocked { return latest }
        let deadline = clock.now + firstFixWait
        while clock.now < deadline {
            do {
                try await clock.sleep(until: min(clock.now + pollInterval, deadline))
            } catch {
                break
            }
            if let fix = freshFix() { return fix }
            // Denied ends the wait at once; so does a pause (background), with whatever fix there is.
            let (denied, paused) = state.withLock { ($0.permission == .denied, $0.paused) }
            if denied { return nil }
            if paused { return latest }
        }
        return latest
    }
}
