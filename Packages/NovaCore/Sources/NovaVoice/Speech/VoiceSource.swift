import NovaKit
import NovaPorts

/// F-07 §14 items 2, 5 (T-020a): where her voice comes from.
public enum VoiceSourceKind: String, Sendable, Hashable, CaseIterable {
    case qwen
    case azure
}

/// F-07 §14 item 2: the voices that work on the owner's Singapore host, in picker order.
public struct QwenVoiceOption: Sendable, Hashable {
    public let id: String
    public let label: String

    public static let all: [QwenVoiceOption] = [
        QwenVoiceOption(id: "longanhuan_v3.1", label: "龙安欢"),
        QwenVoiceOption(id: "longanlingxin_v3.1", label: "龙安灵心"),
        QwenVoiceOption(id: "longanfengyue_v3.1", label: "龙安风悦"),
    ]
    public static let defaultID = "longanhuan_v3.1"
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

/// F-07 §14 item 5: the session-start decision. Pure.
public enum VoiceSourceDecision: Sendable, Hashable {
    case qwen(key: String, host: String)
    /// Today's Azure check and region probe run in the app.
    case azure
    case blocked(String)
}

public enum VoiceSource {
    public static let qwenMissingMessage = "请先在设置里保存千问 key 和 API Host"

    /// The source the picker shows: a saved choice is kept; new installs, and installs with a saved Qwen key and
    /// no saved choice, start on 千问. An install with only an Azure key and no saved choice stays on Azure.
    public static func effectiveChoice(_ choice: VoiceSourceKind?, hasQwenKey: Bool, hasAzureKey: Bool) -> VoiceSourceKind {
        if let choice { return choice }
        return hasQwenKey || !hasAzureKey ? .qwen : .azure
    }

    public static func resolve(choice: VoiceSourceKind?, qwenKey: String?, qwenHost: String?,
                               azureKey: String?) -> VoiceSourceDecision {
        let key = qwenKey.flatMap { $0.isEmpty ? nil : $0 }
        let host = qwenHost.flatMap { VoiceHostCheck.isValid($0) ? $0 : nil }
        switch effectiveChoice(choice, hasQwenKey: key != nil, hasAzureKey: azureKey?.isEmpty == false) {
        case .qwen:
            guard let key, let host else { return .blocked(qwenMissingMessage) }
            return .qwen(key: key, host: host)
        case .azure:
            return .azure
        }
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
        if code == "QWEN_TTS_RATE" || code == "AZURE_TTS_THROTTLED" { return true }
        for prefix in ["QWEN_TTS_HTTP_", "AZURE_TTS_HTTP_"] where code.hasPrefix(prefix) {
            if let status = Int(code.dropFirst(prefix.count)), (500..<600).contains(status) { return true }
        }
        return false
    }

    public func synthesize(_ text: String, style: SpeakingStyle, deadline: NovaDuration) async throws -> PCMBuffer {
        var attempt = 1
        while true {
            let start = clock.now
            do {
                let (pcm, firstMs) = try await once(text, style: style, deadline: deadline)
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

    private func once(_ text: String, style: SpeakingStyle, deadline: NovaDuration) async throws -> (PCMBuffer, Int?) {
        if let timed = inner as? any FirstAudioTimedSynthesizer {
            let r = try await timed.synthesizeTimed(text, style: style, deadline: deadline)
            return (r.pcm, r.firstMs)
        }
        return (try await inner.synthesize(text, style: style, deadline: deadline), nil)
    }
}
