import NovaKit

/// F-24 §15 items 4-5 (T-016j): what the next session starts with after a give-up or the offline cap.
/// `handle` is nil when none was kept or it expired; the record then says `handle=no result=none`.
public struct SessionResume: Sendable, Hashable {
    public let handle: String?
    public init(handle: String?) { self.handle = handle }
}

/// F-24 §15 item 4: the resumption handle kept after giving up, in memory only (I-7): never written to disk,
/// never logged. Dropped when the driver stops, when it is taken by the next start, and 2 hours after saving.
public struct KeptResumption: Sendable {
    private var handle: String?
    private var savedAt: NovaInstant?
    private let lifetime: NovaDuration

    public init(tuning: ReconnectTuning = ReconnectTuning()) { lifetime = tuning.keptHandleLifetime }

    /// The session ended by giving up or at the offline cap (with or without a handle).
    public mutating func keep(_ handle: String?, at now: NovaInstant) {
        self.handle = handle
        savedAt = now
    }

    /// The driver stopped the session: nothing is sent next time.
    public mutating func drop() {
        handle = nil
        savedAt = nil
    }

    /// The next start: nil when nothing ended by giving up; the handle once, then it is forgotten.
    public mutating func take(at now: NovaInstant) -> SessionResume? {
        guard let savedAt else { return nil }
        let fresh = now < savedAt + lifetime ? handle : nil
        drop()
        return SessionResume(handle: fresh)
    }

    public var isKept: Bool { savedAt != nil }
}

/// F-24 §15 item 6: the chip after giving up or the offline cap, until the next start.
public enum SessionEndedChip {
    public static let wakeText = "连接断开，说“你好小诺”重连"
    public static let tapText = "连接断开，点按重连"
    /// `wakeArmed`: the wake listener is armed (setting on and listening).
    public static func text(wakeArmed: Bool) -> String { wakeArmed ? wakeText : tapText }
}
