import NovaKit

/// F-25 bubble timing (iOS values, owner decision 2026-10-26: no Android parity). The bubble shows the
/// latest exchange; it stays while the session is speaking or the text is still changing, then holds
/// for a time that grows with its length and fades. A new exchange replaces it at once.
public struct BubbleFadeTuning: Sendable, Hashable {
    public var baseHold = NovaDuration.seconds(4)
    public var perCharacter = NovaDuration.milliseconds(120)
    public var maxHold = NovaDuration.seconds(10)
    public var fade = NovaDuration.milliseconds(500)
    public init() {}
}

public struct BubbleFade: Sendable, Hashable {
    public enum Phase: Sendable, Hashable { case hidden, shown, fading }

    public let tuning: BubbleFadeTuning
    private(set) var text = ""
    private(set) var changedAt = NovaInstant.zero
    private(set) var pinned = false

    public init(tuning: BubbleFadeTuning = BubbleFadeTuning()) { self.tuning = tuning }

    /// The bubble text changed (driver line or reply subtitle) at `now`; empty clears at once.
    public mutating func update(_ text: String, at now: NovaInstant) {
        self.text = text
        changedAt = now
    }

    /// While pinned (小诺 speaking) the bubble never fades; the hold starts again
    /// when that ends.
    public mutating func pin(_ pinned: Bool, at now: NovaInstant) {
        if self.pinned && !pinned { changedAt = now }
        self.pinned = pinned
    }

    public func hold(for text: String) -> NovaDuration {
        let grown = tuning.baseHold.milliseconds + tuning.perCharacter.milliseconds * Int64(text.count)
        return .milliseconds(min(grown, tuning.maxHold.milliseconds))
    }

    /// When the fade starts; nil while pinned or empty.
    public var fadeStartsAt: NovaInstant? {
        guard !text.isEmpty, !pinned else { return nil }
        return changedAt + hold(for: text)
    }

    public func phase(at now: NovaInstant) -> Phase {
        guard !text.isEmpty else { return .hidden }
        guard let start = fadeStartsAt, now >= start else { return .shown }
        return now < start + tuning.fade ? .fading : .hidden
    }
}
