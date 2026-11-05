/// When the idle app listens for 你好小诺 (T-060/T-061, F-01): foreground only (in-app wake, OQ-IOS-1),
/// no session running (one capture only, ADR-006: the session owns the mic), the engine available, the 「唤醒词」
/// setting on, the microphone already granted (wake never asks; the first tap does, F-23), and not after the bounded
/// retry gave up until something changes. F-01 §14 item 4 (T-060a): saved iFlytek values matter only when the
/// selected engine is iFlytek; the bundled sherpa engine is available when its KWS model is there.
public struct WakeListenPolicy: Sendable, Hashable {
    public var foreground = true
    public var sessionRunning = false
    public var engine = WakeEngineKind.selected
    /// sherpa: the bundled KWS model is present; iFlytek: the SDK is linked.
    public var engineAvailable = false
    /// The three 讯飞 values are saved (read only for iFlytek).
    public var keysSaved = false
    /// §14 item 6: 「唤醒词」, on by default.
    public var enabled = true
    public var micGranted = false
    public var gaveUp = false

    public init() {}

    public var shouldListen: Bool {
        foreground && !sessionRunning && engineAvailable && (keysSaved || !engine.needsKeys) && enabled && micGranted
            && !gaveUp
    }
}
