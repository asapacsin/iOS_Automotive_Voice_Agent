/// F-24 §17 (T-016o): the connection message, separate from the camera, microphone and key notice.
/// Pure: the session's events and a clock in, nil or a chip text out. A retryable drop shows 「重新连接中…」 only
/// after `showAfter`; the next `setupComplete` clears it and, if it was shown, 「已重新连接」 shows for `backFor`.
/// A non-retryable failure keeps 「连接失败，点按重试」 until a start. No error code is ever part of a text (item 5).
public struct ConnectionNotice: Sendable {
    public enum Event: Sendable, Hashable {
        /// A provider failure; `retryable` is `RealtimeErrorCode.isRetryable`. The code itself stays in the log.
        case failed(retryable: Bool)
        case setupComplete
        /// §15 give-up or the §14 item 4 offline cap: `SessionEndedChip` owns the text from here.
        case gaveUp
        /// A start or stop: everything is cleared.
        case stopped
        /// §14 item 3: 「等待网络…」 wins while waiting.
        case network(waiting: Bool)
    }

    public enum Show: String, Sendable, Hashable {
        case reconnecting, back, failed, none
    }

    public static let showAfter = NovaDuration.seconds(1)
    public static let backFor = NovaDuration.seconds(3)
    public static let reconnectingText = "重新连接中…"
    public static let backText = "已重新连接"
    public static let failedText = "连接失败，点按重试"

    private enum Phase: Sendable { case idle, reconnecting, failed }

    private var phase = Phase.idle
    private var waiting = false
    private var failedAt: NovaInstant?
    private var backUntil: NovaInstant?
    private var reconnectingSeen = false
    private var lastAt: NovaInstant?
    /// The last show reported by `handle` or `tick`; a change is logged once.
    public private(set) var reported = Show.none

    public init() {}

    /// What the screen shows at `now`. `.none` while waiting for the network (the 「等待网络…」 chip shows).
    public func show(at now: NovaInstant) -> Show {
        switch phase {
        case .failed: return .failed
        case .reconnecting:
            guard !waiting, let failedAt, now >= failedAt + Self.showAfter else { return .none }
            return .reconnecting
        case .idle:
            if let backUntil, now < backUntil { return .back }
            return .none
        }
    }

    /// The chip text at `now` (reconnecting or back); the failed text goes under the chip (`line`).
    public func chipText(at now: NovaInstant) -> String? {
        switch show(at: now) {
        case .reconnecting: Self.reconnectingText
        case .back: Self.backText
        case .failed, .none: nil
        }
    }

    /// Item 1: the line under the chip. The other notice (camera, microphone, key) is kept as is.
    public func line(notice: String?, at now: NovaInstant) -> String? {
        notice ?? (show(at: now) == .failed ? Self.failedText : nil)
    }

    /// When the show changes next with no new event (call `tick` then), or nil.
    public func nextChange(at now: NovaInstant) -> NovaInstant? {
        switch phase {
        case .reconnecting:
            guard !waiting, let failedAt else { return nil }
            let at = failedAt + Self.showAfter
            return at > now ? at : nil
        case .idle:
            guard let backUntil, backUntil > now else { return nil }
            return backUntil
        case .failed: return nil
        }
    }

    /// Applies an event. Returns the item 6 log line when the show changed.
    public mutating func handle(_ event: Event, at now: NovaInstant) -> String? {
        note(at: now)
        switch event {
        case .failed(let retryable):
            if retryable {
                guard phase != .failed else { break }
                if phase != .reconnecting {
                    phase = .reconnecting
                    failedAt = now
                    reconnectingSeen = false
                }
                backUntil = nil
            } else {
                phase = .failed
                failedAt = now
                backUntil = nil
            }
        case .setupComplete:
            guard phase == .reconnecting else { break }
            phase = .idle
            backUntil = reconnectingSeen ? now + Self.backFor : nil
        case .gaveUp, .stopped:
            phase = .idle
            backUntil = nil
            reconnectingSeen = false
            if event == .stopped { waiting = false }
        case .network(let w):
            waiting = w
        }
        return report(at: now)
    }

    /// The time asked for by `nextChange` passed. Returns the item 6 log line when the show changed.
    public mutating func tick(at now: NovaInstant) -> String? {
        note(at: now)
        return report(at: now)
    }

    /// Records whether 「重新连接中…」 was on screen for some time since the last call (state is constant in
    /// between, so it was on from max(last call, failure + `showAfter`) to `now`).
    private mutating func note(at now: NovaInstant) {
        if phase == .reconnecting, !waiting, let failedAt {
            let from = max(lastAt ?? failedAt, failedAt + Self.showAfter)
            if now > from { reconnectingSeen = true }
        }
        lastAt = now
    }

    private mutating func report(at now: NovaInstant) -> String? {
        let current = show(at: now)
        guard current != reported else { return nil }
        reported = current
        let ms = failedAt.map { (now - $0).milliseconds } ?? 0
        return "connNotice show=\(current.rawValue) ms=\(ms)"
    }
}
