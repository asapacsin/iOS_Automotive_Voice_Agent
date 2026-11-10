import NovaKit
import NovaPorts

/// F-07 §14 items 2, 5 (T-020a): where her voice comes from. F-07 §15 item 1 (T-020b): Gemini Live's own voice
/// (the live session's `Aoede`), first and the default.
public enum VoiceSourceKind: String, Sendable, Hashable, CaseIterable {
    case gemini
    case qwen
}

/// F-07 §14 item 2: the API Host field accepts a bare host name only (no scheme, path or spaces).
public enum VoiceHostCheck {
    public static let invalidMessage = "API Host 格式不对"

    public static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, host.contains("."),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy { s in
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "-" || s == "."
        }
    }
}

/// F-07 §14 item 5, §15 item 3: the session-start decision. Pure.
public enum VoiceSourceDecision: Sendable, Hashable {
    /// Gemini Live's own audio through the judged path: no revoicer, no TTS warm-up, no Qwen connection.
    case gemini
    case qwen(key: String, host: String)
    case blocked(String)

    /// F-07 §15 item 3: replies are revoiced only by Qwen.
    public var revoicing: Bool { self != .gemini }
}

public enum VoiceSource {
    /// F-07 §15 item 4: the message names only what is missing.
    public static let qwenKeyMissingMessage = "请先在设置里保存千问 key"
    public static let qwenHostMissingMessage = "请先在设置里保存千问 API Host"

    /// F-07 §15 item 2: remembered once this build has moved the saved choice.
    public static let migrationKey = "voice_source_gemini_default_done"

    /// The source the picker shows and the session uses: a saved choice is kept; no saved choice, or one that no
    /// longer parses (a removed source, F-07 §17 item 2), is Gemini 原声.
    public static func effectiveChoice(_ choice: VoiceSourceKind?) -> VoiceSourceKind { choice ?? .gemini }

    /// F-07 §15 item 2, run once on the first launch of this build: no saved choice, or 千问 saved by 1f05a54,
    /// becomes Gemini 原声 (F-07 §17 item 2: so does any other saved value). Returns the choice to save, or nil when the migration already ran
    /// (anything saved after that launch is kept).
    public static func migrated(saved: String?, done: Bool) -> VoiceSourceKind? {
        guard !done else { return nil }
        return .gemini
    }

    /// The Qwen message for what is missing, or nil when both are there.
    public static func qwenMissing(key: String?, host: String?) -> String? {
        if key?.isEmpty != false { return qwenKeyMissingMessage }
        if !VoiceHostCheck.isValid(host ?? "") { return qwenHostMissingMessage }
        return nil
    }

    public static func resolve(choice: VoiceSourceKind?, qwenKey: String?, qwenHost: String?) -> VoiceSourceDecision {
        switch effectiveChoice(choice) {
        case .gemini:
            // Always ready: the session cannot start without the Gemini key.
            return .gemini
        case .qwen:
            if let message = qwenMissing(key: qwenKey, host: qwenHost) { return .blocked(message) }
            return .qwen(key: qwenKey ?? "", host: qwenHost ?? "")
        }
    }
}

/// F-07 §15 item 5: `voice source=gemini turn= held_ms= first_ms=` for each turn whose audio is played; numbers only (I-8).
public struct GeminiVoiceLine: Sendable, Hashable {
    public var turn: Int
    /// First audio received → first audio played (the claim gate's hold).
    public var heldMs: Int
    /// Utterance sent → first audio played; nil when no utterance was sent before (a reply to a text turn).
    public var firstMs: Int?

    public init(turn: Int, heldMs: Int, firstMs: Int?) {
        self.turn = turn
        self.heldMs = heldMs
        self.firstMs = firstMs
    }

    public var fields: String {
        "source=gemini turn=\(turn) held_ms=\(heldMs) first_ms=\(firstMs.map(String.init) ?? "none")"
    }
    public var logLine: String { "voice \(fields)" }
}

/// F-07 §15 item 5: the times behind `GeminiVoiceLine`. Pure; the app feeds it the clock.
public struct GeminiVoiceTiming: Sendable {
    private var utteranceSent: NovaInstant?
    private var firstReceived: [Int: NovaInstant] = [:]
    private var played: Set<Int> = []

    public init() {}

    /// The uplink closed an utterance that went to Gemini (`activityEnd`).
    public mutating func utteranceSent(at now: NovaInstant) { utteranceSent = now }

    /// Gemini audio of `turn` arrived (before the claim gate).
    public mutating func audioReceived(turn: Int, at now: NovaInstant) {
        if firstReceived[turn] == nil { firstReceived[turn] = now }
    }

    /// Judged audio of `turn` went to the reply lane; the line once per turn.
    public mutating func audioPlayed(turn: Int, at now: NovaInstant) -> GeminiVoiceLine? {
        guard !played.contains(turn) else { return nil }
        played.insert(turn)
        let received = firstReceived.removeValue(forKey: turn) ?? now
        return GeminiVoiceLine(turn: turn, heldMs: max(0, Int((now - received).milliseconds)),
                               firstMs: utteranceSent.map { max(0, Int((now - $0).milliseconds)) })
    }
}

/// F-07 §14 item 8: `voice source= chars= first_ms= ms= attempt=`; numbers only, never text (I-8).
public struct VoiceClauseLine: Sendable, Hashable {
    public var source: VoiceSourceKind
    public var chars: Int
    public var firstMs: Int
    public var ms: Int
    public var attempt: Int

    public init(source: VoiceSourceKind, chars: Int, firstMs: Int, ms: Int, attempt: Int) {
        self.source = source
        self.chars = chars
        self.firstMs = firstMs
        self.ms = ms
        self.attempt = attempt
    }

    public var fields: String { "source=\(source.rawValue) chars=\(chars) first_ms=\(firstMs) ms=\(ms) attempt=\(attempt)" }
    public var logLine: String { "voice \(fields)" }
}

/// F-07 §14 item 7: `voice-failed turn= source= code=`; a number and codes only.
public struct VoiceFailedLine: Sendable, Hashable {
    public var turn: Int
    public var source: VoiceSourceKind
    public var code: String

    public init(turn: Int, source: VoiceSourceKind, code: String) {
        self.turn = turn
        self.source = source
        self.code = code
    }

    public var fields: String { "turn=\(turn) source=\(source.rawValue) code=\(code)" }
    public var logLine: String { "voice-failed \(fields)" }
}

/// F-07 §14 items 6, 8: one more request, with a fresh deadline, for a timeout, network, rate-limit or 5xx code;
/// never for auth, voice, empty or bad-stream codes. Each finished clause reports its timing line. A cancel
/// (barge-in, void) ends the retry like the first attempt.
public struct RetryingSpeechSynthesizer: SpeechSynthesizer {
    private let inner: any SpeechSynthesizer
    private let source: VoiceSourceKind
    private let clock: any NovaClock
    private let onClause: @Sendable (VoiceClauseLine) -> Void

    public init(_ inner: any SpeechSynthesizer, source: VoiceSourceKind, clock: any NovaClock = SystemClock(),
                onClause: @escaping @Sendable (VoiceClauseLine) -> Void = { _ in }) {
        self.inner = inner
        self.source = source
        self.clock = clock
        self.onClause = onClause
    }

    public static func isRetryable(_ code: String) -> Bool {
        if code.hasSuffix("_TIMEOUT") || code.hasSuffix("_NETWORK") { return true }
        if code == "QWEN_TTS_RATE" { return true }
        let prefix = "QWEN_TTS_HTTP_"
        if code.hasPrefix(prefix), let status = Int(code.dropFirst(prefix.count)), (500..<600).contains(status) { return true }
        return false
    }

    public func synthesize(_ text: String, deadline: NovaDuration) async throws -> PCMBuffer {
        var attempt = 1
        while true {
            let start = clock.now
            do {
                let (pcm, firstMs) = try await once(text, deadline: deadline)
                let ms = Int((clock.now - start).milliseconds)
                onClause(VoiceClauseLine(source: source, chars: text.count, firstMs: firstMs ?? ms, ms: ms, attempt: attempt))
                return pcm
            } catch let error as SpeechSynthesisError where attempt == 1 && Self.isRetryable(error.code) {
                try Task.checkCancellation()
                attempt = 2
            }
        }
    }

    public func warmUp() async { await inner.warmUp() }

    private func once(_ text: String, deadline: NovaDuration) async throws -> (PCMBuffer, Int?) {
        if let timed = inner as? any FirstAudioTimedSynthesizer {
            let r = try await timed.synthesizeTimed(text, deadline: deadline)
            return (r.pcm, r.firstMs)
        }
        return (try await inner.synthesize(text, deadline: deadline), nil)
    }
}
