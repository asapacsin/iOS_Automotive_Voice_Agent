import NovaKit

/// F-24 §15 items 4-5 (T-016j): what the next session starts with after a give-up or the offline cap.
/// `handle` is nil when none was kept or it expired; the record then says `handle=no result=none`.
public struct SessionResume: Sendable, Hashable {
    public let handle: String?
    /// F-21 §16 item 5 (T-034c): the system instruction the handle's resumption chain began with; memory only.
    public let instruction: String?
    public init(handle: String?, instruction: String? = nil) {
        self.handle = handle
        self.instruction = handle == nil ? nil : instruction
    }
}

/// F-24 §15 item 4: the resumption handle kept after giving up, in memory only (I-7): never written to disk,
/// never logged. Dropped when the driver stops, when it is taken by the next start, and 2 hours after saving.
public struct KeptResumption: Sendable {
    private var handle: String?
    /// F-21 §16 item 5: the instruction kept beside the handle (memory only, like the handle).
    private var instruction: String?
    private var savedAt: NovaInstant?
    private let lifetime: NovaDuration
    /// The handle the last start took, with its first save time: if that session gives up again with the same
    /// handle, the 2 hours still count from the first save (item 4).
    private var taken: (handle: String, savedAt: NovaInstant)?

    public init(tuning: ReconnectTuning = ReconnectTuning()) { lifetime = tuning.keptHandleLifetime }

    /// The session ended by giving up or at the offline cap (with or without a handle).
    public mutating func keep(_ handle: String?, instruction: String? = nil, at now: NovaInstant) {
        self.handle = handle
        self.instruction = instruction
        if let handle, let taken, taken.handle == handle { savedAt = taken.savedAt } else { savedAt = now }
        taken = nil
    }

    /// The driver stopped the session: nothing is sent next time.
    public mutating func drop() {
        handle = nil
        instruction = nil
        savedAt = nil
        taken = nil
    }

    /// The next start: nil when nothing ended by giving up; the handle once, then it is forgotten.
    public mutating func take(at now: NovaInstant) -> SessionResume? {
        guard let savedAt else { return nil }
        let fresh = now < savedAt + lifetime ? handle : nil
        let kept = instruction
        drop()
        if let fresh { taken = (fresh, savedAt) }
        return SessionResume(handle: fresh, instruction: kept)
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
