import Foundation
import NovaKit
import NovaPorts
import Synchronization

/// F-01 §14 item 12 (T-060a): what started a session; the record header says `startedBy wake|tap`.
public enum SessionOrigin: Sendable, Hashable {
    /// The talk button (or any UI start).
    case tap
    /// 你好小诺, detected at `at` (the clock the session's `WakeSessionWatch` reads).
    case wake(at: NovaInstant)

    public var startedBy: String {
        if case .wake = self { "wake" } else { "tap" }
    }
}

public enum WakeSessionEffect: Sendable, Hashable {
    /// §14 items 9–10: the short local sound, through the session's own audio output.
    case playCue
    /// §14 item 12: the record line `wake-to-listening ms=<n>`.
    case wakeToListening(ms: Int)
}

/// F-01 §14 items 9–12 (T-060a), one session: the sound plays once when a woken session first reaches listening
/// (never for a tap, never again after a reconnect), the wake-to-listening time is measured, and a woken session that
/// ends with no utterance sent after that point is `wake-unused` (a false wake). Pure.
public struct WakeSessionStart: Sendable, Hashable {
    public let origin: SessionOrigin
    public private(set) var listened = false
    public private(set) var utteranceSent = false
    private var ended = false

    public init(origin: SessionOrigin) { self.origin = origin }

    /// Each session UI state, in order.
    public mutating func sessionState(_ state: SessionUIState, at now: NovaInstant) -> [WakeSessionEffect] {
        guard state == .listening, !listened, !ended else { return [] }
        listened = true
        guard case .wake(let woke) = origin else { return [] }
        return [.wakeToListening(ms: Int(max(0, (now - woke).milliseconds))), .playCue]
    }

    /// The gate's decision at an utterance's start. Speech before the sound is not kept (§14 item 9), so only an
    /// utterance after the first listening counts.
    public mutating func speechStarted(sentToModel: Bool) {
        if sentToModel && listened && !ended { utteranceSent = true }
    }

    /// The session ended: true once, for a woken session that sent no utterance (`wake-unused`).
    public mutating func end() -> Bool {
        guard !ended else { return false }
        ended = true
        guard case .wake = origin else { return false }
        return !utteranceSent
    }
}

/// `WakeSessionStart` shared by the provider, capture and main paths of one session.
public final class WakeSessionWatch: Sendable {
    private let state: Mutex<WakeSessionStart>
    private let clock: any NovaClock
    public let origin: SessionOrigin

    public init(origin: SessionOrigin, clock: any NovaClock) {
        self.origin = origin
        self.clock = clock
        state = Mutex(WakeSessionStart(origin: origin))
    }

    public var startedBy: String { origin.startedBy }

    public func sessionState(_ s: SessionUIState) -> [WakeSessionEffect] {
        let now = clock.now
        return state.withLock { $0.sessionState(s, at: now) }
    }

    public func speechStarted(sentToModel: Bool) { state.withLock { $0.speechStarted(sentToModel: sentToModel) } }

    public func end() -> Bool { state.withLock { $0.end() } }
}

/// F-01 §14 items 9–10: the ready sound. Two short tones with a silent gap, each shorter than the uplink gate's
/// 200 ms onset, so even heard back unfiltered by the microphone it cannot open an utterance; it is not a reply, so
/// it never stops one.
public enum WakeCue {
    /// (frequency Hz, milliseconds); 0 Hz is silence.
    public static let parts: [(hz: Double, ms: Int)] = [(880, 80), (0, 60), (1_320, 100)]
    /// Peak level as a fraction of full scale (moderate: it plays next to the driver).
    public static let level = 0.3
    /// Fade in and out of each tone, against clicks.
    static let fadeMs = 8

    public static func samples(rate: Int) -> [Int16] {
        var out: [Int16] = []
        for part in parts {
            let n = rate * part.ms / 1_000
            guard part.hz > 0 else {
                out += Array(repeating: 0, count: n)
                continue
            }
            let fade = max(1, rate * fadeMs / 1_000)
            for i in 0..<n {
                let edge = min(i, n - 1 - i)
                let gain = edge >= fade ? 1.0 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade))
                let v = sin(2 * Double.pi * part.hz * Double(i) / Double(rate)) * level * gain
                out.append(Int16((v * 32_767).rounded()))
            }
        }
        return out
    }

    /// The sound at the reply lane's 24 kHz.
    public static let pcm = PCMBuffer(sampleRate: PCMBuffer.replySampleRate, samples: samples(rate: PCMBuffer.replySampleRate))
}

/// F-01 §14 item 7: while the listener runs the screen stays on (`isIdleTimerDisabled` true); when it stops, the value
/// from before goes back. Pure; the app applies the values.
public struct IdleTimerHold: Sendable, Hashable {
    private var saved: Bool?

    public init() {}

    public var holding: Bool { saved != nil }

    /// The listener started: the value to set. The value before is kept (only the first time) for `release`.
    public mutating func hold(current: Bool) -> Bool {
        if saved == nil { saved = current }
        return true
    }

    /// The listener stopped: the value to restore, or nil when nothing is held.
    public mutating func release() -> Bool? {
        defer { saved = nil }
        return saved
    }
}
