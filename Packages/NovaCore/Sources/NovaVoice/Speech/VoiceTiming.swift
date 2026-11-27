import NovaKit
import NovaPorts

/// F-07 §15 item 5: `voice source=gemini turn= held_ms= first_ms=` for each turn whose audio is played; numbers only
/// (I-8). F-07 §18 item 5 (T-020e): kept as the timing line for both voice models; with Qwen it reads
/// `source=qwen-realtime`.
public struct GeminiVoiceLine: Sendable, Hashable {
    public static let geminiSource = "gemini"
    public static let qwenSource = "qwen-realtime"

    public var source: String
    public var turn: Int
    /// First audio received → first audio played (the claim gate's hold).
    public var heldMs: Int
    /// Utterance sent → first audio played; nil when no utterance was sent before (a reply to a text turn).
    public var firstMs: Int?

    public init(source: String = GeminiVoiceLine.geminiSource, turn: Int, heldMs: Int, firstMs: Int?) {
        self.source = source
        self.turn = turn
        self.heldMs = heldMs
        self.firstMs = firstMs
    }

    public var fields: String {
        "source=\(source) turn=\(turn) held_ms=\(heldMs) first_ms=\(firstMs.map(String.init) ?? "none")"
    }
    public var logLine: String { "voice \(fields)" }
}

/// F-07 §15 item 5: the times behind `GeminiVoiceLine`. Pure; the app feeds it the clock.
public struct GeminiVoiceTiming: Sendable {
    private let source: String
    private var utteranceSent: NovaInstant?
    private var firstReceived: [Int: NovaInstant] = [:]
    private var played: Set<Int> = []

    /// `source`: the line's `source=` (F-07 §18 item 5).
    public init(source: String = GeminiVoiceLine.geminiSource) { self.source = source }

    /// The uplink closed an utterance that went to the voice model (`activityEnd`).
    public mutating func utteranceSent(at now: NovaInstant) { utteranceSent = now }

    /// Audio of `turn` arrived (before the claim gate).
    public mutating func audioReceived(turn: Int, at now: NovaInstant) {
        if firstReceived[turn] == nil { firstReceived[turn] = now }
    }

    /// Judged audio of `turn` went to the reply lane; the line once per turn.
    public mutating func audioPlayed(turn: Int, at now: NovaInstant) -> GeminiVoiceLine? {
        guard !played.contains(turn) else { return nil }
        played.insert(turn)
        let received = firstReceived.removeValue(forKey: turn) ?? now
        return GeminiVoiceLine(source: source, turn: turn, heldMs: max(0, Int((now - received).milliseconds)),
                               firstMs: utteranceSent.map { max(0, Int((now - $0).milliseconds)) })
    }
}
