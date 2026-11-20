/// F-09b §16 items 2 and 6 (T-031z): the one screen state the App's views report into and the tools read back.
/// A key changes only from a report (item 2); a tool waits here for the key it changed (item 6).
public actor ScreenStateStore {
    private var state = ScreenState()
    private var waiters: [Int: (predicate: @Sendable (ScreenState) -> Bool, resume: CheckedContinuation<Bool, Never>)] = [:]
    private var nextWaiter = 0
    private var listener: (@Sendable (ScreenState) -> Void)?

    public init(_ initial: ScreenState = ScreenState()) { state = initial }

    public var current: ScreenState { state }

    /// Called with every changed state (the App's settle-and-send path, item 4). One listener: a new session's
    /// replaces the last one's.
    public func onChange(_ listener: @escaping @Sendable (ScreenState) -> Void) { self.listener = listener }

    /// F-09b §17 item 7 (T-031zb): called at each view report that changed a key, with the state after it (the record's
    /// `panel` line). One listener, like `onChange`.
    public func onReport(_ listener: @escaping @Sendable (ScreenPanel, Bool, ScreenState) -> Void) { reportListener = listener }
    private var reportListener: (@Sendable (ScreenPanel, Bool, ScreenState) -> Void)?

    public func report(_ panel: ScreenPanel, on: Bool) {
        guard state.report(panel, on: on) else { return }
        reportListener?(panel, on, state)
        changed()
    }
    public func reportMusic(heard: Bool) { change { $0.reportMusic(heard: heard) } }
    public func reportVolume(_ volume: Int) { change { $0.reportVolume(volume) } }

    private func change(_ edit: (inout ScreenState) -> Bool) {
        guard edit(&state) else { return }
        changed()
    }

    private func changed() {
        listener?(state)
        for (id, waiter) in waiters where waiter.predicate(state) {
            waiters[id] = nil
            waiter.resume.resume(returning: true)
        }
    }

    /// Item 6: true as soon as `predicate` holds (at once if it already does), false after `timeout` on `clock`.
    public func wait(until predicate: @escaping @Sendable (ScreenState) -> Bool, timeout: NovaDuration,
                     clock: any NovaClock) async -> Bool {
        if predicate(state) { return true }
        let id = nextWaiter
        nextWaiter += 1
        let timer = Task { [weak self] in
            try? await clock.sleep(until: clock.now + timeout)
            await self?.expire(id)
        }
        let met = await withCheckedContinuation { continuation in
            waiters[id] = (predicate, continuation)
        }
        timer.cancel()
        return met
    }

    private func expire(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume.resume(returning: predicate(waiter.predicate))
    }

    private func predicate(_ p: @Sendable (ScreenState) -> Bool) -> Bool { p(state) }
}
