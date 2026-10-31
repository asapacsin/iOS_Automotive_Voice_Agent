/// F-24 §14 item 1: the watcher's debounce, pure so it is testable without `NWPathMonitor`. A path that is
/// unsatisfied for less than `delay` (a Wi-Fi to cellular switch) is not reported; a return is reported at once.
public struct NetworkPathDebouncer: Sendable {
    public private(set) var available = true
    private var lossDeadline: NovaInstant?
    private let delay: NovaDuration

    public init(delay: NovaDuration = .milliseconds(500)) { self.delay = delay }

    /// The path changed. Returns the event to report now (false: lost, true: restored), and when to call `tick`.
    public mutating func path(satisfied: Bool, at now: NovaInstant) -> (report: Bool?, tickAt: NovaInstant?) {
        if satisfied {
            lossDeadline = nil
            guard !available else { return (nil, nil) }
            available = true
            return (true, nil)
        }
        guard available, lossDeadline == nil else { return (nil, nil) }
        let deadline = now + delay
        lossDeadline = deadline
        return (nil, deadline)
    }

    /// The tick asked for by `path`; reports the loss if the path stayed unsatisfied until then.
    public mutating func tick(at now: NovaInstant) -> Bool? {
        guard let deadline = lossDeadline, now >= deadline else { return nil }
        lossDeadline = nil
        available = false
        return false
    }
}
