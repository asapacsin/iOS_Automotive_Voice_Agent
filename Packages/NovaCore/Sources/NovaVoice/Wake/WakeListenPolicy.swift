/// When the idle app listens for 你好小诺 (T-060/T-061, F-01): foreground only (in-app wake, OQ-IOS-1),
/// no session running (one capture only, ADR-006: the session owns the mic), the engine present and
/// configured, the microphone already granted (wake never asks; the first tap does, F-23), and not after
/// the bounded retry gave up until something changes.
public struct WakeListenPolicy: Sendable, Hashable {
    public var foreground = true
    public var sessionRunning = false
    public var engineLinked = false
    public var configured = false
    public var micGranted = false
    public var gaveUp = false

    public init() {}

    public var shouldListen: Bool {
        foreground && !sessionRunning && engineLinked && configured && micGranted && !gaveUp
    }
}
