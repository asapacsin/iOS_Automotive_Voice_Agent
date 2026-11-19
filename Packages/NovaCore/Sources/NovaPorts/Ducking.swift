import NovaKit

/// F-13a §5 items 1, 5 (T-032h): whether the song is lowered. From the first buffer of her reply on the reply node until
/// that reply's playback finished (`replyIdle`, the shell's "nothing of her reply is left") or its flush, and while a
/// guidance sentence plays. Only the media gain changes; the microphone path, echo cancelling and the F-08 dip do not.
/// `LiveAudio` feeds it on `mediaQueue`.
public struct DuckMachine: Sendable, Hashable {
    public enum Event: Sendable, Hashable {
        /// Her reply turn opened (ResponseStarted): §7's `ms` is measured from here.
        case replyBegan
        /// A buffer of her reply of `epoch` started on the reply node (`replyStarted`; again after each clause gap).
        case replyAudio(Epoch)
        /// Nothing of the reply of `epoch` is left to sound.
        case replyIdle(Epoch)
        /// The reply lane was flushed (barge-in, stop phrase, void).
        case flushed
        case guidanceStarted(GuidanceID)
        case guidanceEnded(GuidanceID)
    }

    /// The duck went on or off, with its §7 line.
    public struct Change: Sendable, Hashable {
        public let ducked: Bool
        /// `duck on ms=<n>` / `duck off ms=<n>`: time since the reply (or guidance) started. Numbers only (I-8).
        public let line: String
    }

    private var reply: Epoch?
    private var guidance: Set<GuidanceID> = []
    private var replyBegan: NovaInstant?
    /// When the cause of the current duck started.
    private var since: NovaInstant?
    public private(set) var ducked = false

    public init() {}

    public mutating func handle(_ event: Event, at now: NovaInstant) -> Change? {
        switch event {
        case .replyBegan:
            replyBegan = now
            return nil
        case .replyAudio(let epoch):
            if reply == nil, !ducked { since = replyBegan.map { Swift.min($0, now) } ?? now }
            reply = epoch
        case .replyIdle(let epoch):
            guard reply == epoch else { return nil }
            reply = nil
            replyBegan = nil
        case .flushed:
            reply = nil
            replyBegan = nil
        case .guidanceStarted(let id):
            if !ducked { since = now }
            guidance.insert(id)
        case .guidanceEnded(let id):
            guard guidance.remove(id) != nil else { return nil }
        }
        let want = reply != nil || !guidance.isEmpty
        guard want != ducked else { return nil }
        ducked = want
        let ms = (since.map { now - $0 } ?? .zero).milliseconds
        if !want { since = nil }
        return Change(ducked: want, line: "duck \(want ? "on" : "off") ms=\(ms)")
    }
}

/// F-13a §5 items 2–4: the duck factor ramped in 25 ms steps, 150 ms down and 400 ms up. The node gain is
/// `mediaGain × factor`, so the duck is relative to the driver's media level and media 0 stays 0.
public struct DuckRamp: Sendable, Hashable {
    /// §5 item 2: about −10 dB; a tuning value checked on the device (§8 row 9).
    public static let factor = 0.3
    public static let stepMs = 25
    public static let downMs = 150
    public static let upMs = 400

    /// The factor on the nodes now.
    public private(set) var current = 1.0
    private var pending: [Double] = []

    public init() {}

    /// Steps still to run.
    public var running: Bool { !pending.isEmpty }

    /// Plans the ramp from the factor now to ducked (`factor`) or not (1), in the whole down or up time.
    public mutating func target(ducked: Bool) {
        let goal = ducked ? Self.factor : 1
        let steps = (ducked ? Self.downMs : Self.upMs) / Self.stepMs
        let start = current
        guard goal != start else {
            pending = []
            return
        }
        pending = (1..<steps).map { start + (goal - start) * Double($0) / Double(steps) } + [goal]
    }

    /// One 25 ms step: the next factor, or nil when the ramp is done.
    public mutating func tick() -> Double? {
        guard !pending.isEmpty else { return nil }
        current = pending.removeFirst()
        return current
    }

    /// §5 item 4: the media node gain.
    public static func gain(media: Double, factor: Double) -> Double { media * factor }
}
