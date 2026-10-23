/// Marker for the phantom tag of a `MonotonicID`.
public protocol MonotonicIDTag {}

/// A counter that only moves forward. Each tag makes a distinct type, so an `Epoch` cannot be
/// passed where a `Generation` is expected (specs/ios-architecture.md §5.4).
public struct MonotonicID<Tag: MonotonicIDTag>: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static var initial: MonotonicID { MonotonicID(0) }

    public func next() -> MonotonicID { MonotonicID(value + 1) }

    public static func < (lhs: MonotonicID, rhs: MonotonicID) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

public enum EpochTag: MonotonicIDTag {}
public enum GenerationTag: MonotonicIDTag {}
public enum TurnTag: MonotonicIDTag {}
public enum GuidanceTag: MonotonicIDTag {}

/// Playback epoch: raised by barge-in, cancel, 闭嘴 or a voided reply; older audio is discarded.
public typealias Epoch = MonotonicID<EpochTag>
/// Navigation generation: raised by every request or cancel; older SDK callbacks are dropped.
public typealias Generation = MonotonicID<GenerationTag>
/// One provider turn; a late tool call from an abandoned turn is dropped (W3).
public typealias TurnID = MonotonicID<TurnTag>
/// One guidance sentence from the navigation engine.
public typealias GuidanceID = MonotonicID<GuidanceTag>

/// Tool call id from the provider: 1...128 characters of `[A-Za-z0-9_-]` (F-09 §4).
public struct CallID: Sendable, Hashable, CustomStringConvertible {
    public static let maxLength = 128

    public let rawValue: String

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= CallID.maxLength,
              rawValue.utf8.allSatisfy(CallID.isAllowed) else { return nil }
        self.rawValue = rawValue
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    public var description: String { rawValue }
}

/// Key of a scheduled timer. A timer fire is valid only for the epoch it was scheduled under.
public struct TimerID: Sendable, Hashable {
    public let key: String
    public let epoch: Epoch

    public init(_ key: String, epoch: Epoch) {
        self.key = key
        self.epoch = epoch
    }
}
