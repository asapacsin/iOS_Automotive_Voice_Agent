import NovaKit

/// §14 item 8: what the screen says when the lock drops a sentence or a wake word. Text only: no sound, no driver line,
/// no turn. Pure.
public enum SpeakerRejectionNotice {
    public static let speech = "没听出是录入的声音，这句没有发送"
    public static let wake = "没听出是录入的声音，没有唤醒"
    /// Shown for 3 s; a new one restarts it.
    public static let duration = NovaDuration.seconds(3)

    /// The notice for one check line, nil for none. Lines exist only with the lock on, so lock off shows nothing.
    /// Speech: rejected or unknown. Wake: not accepted. Stop phrases: nothing.
    public static func text(for line: SpeakerCheckLine) -> String? {
        switch (line.kind, line.result) {
        case (_, .accepted): nil
        case (.speech, _): speech
        case (.wake, _): wake
        case (.stop, _): nil
        }
    }
}

/// §14 item 8: one notice at a time for 3 s; a new one restarts the 3 s and replaces it (never stacks); while the
/// §6 item 11 chip shows, that chip wins. Time is the caller's clock. Pure.
public struct SpeakerNoticeBoard: Sendable, Hashable {
    public private(set) var current: String?
    private var until = NovaDuration.zero

    public init() {}

    public mutating func show(_ text: String, now: NovaDuration) {
        current = text
        until = now + SpeakerRejectionNotice.duration
    }

    public func visible(now: NovaDuration, chipShowing: Bool) -> String? {
        guard !chipShowing, let current, now < until else { return nil }
        return current
    }
}
